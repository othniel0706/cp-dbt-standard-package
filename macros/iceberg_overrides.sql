{#
===============================================================================
MACRO FILE: iceberg_overrides.sql
PURPOSE:    Override Snowflake CREATE TABLE AS to coerce incompatible column
            types before Iceberg v3 DDL is emitted.

PROBLEM:    Snowflake Iceberg v3 (native/built-in catalog) rejects columns
            with incompatible type scales or timezone qualifiers:
              - TIMESTAMP_LTZ(n) where n ≠ 6        → error 091385 or value overflow
              - TIMESTAMP_NTZ(n) where n ≠ 6        → same constraint
              - TIMESTAMP_TZ(n)  → must convert to LTZ (Iceberg has no TZ type)
              - TIME(n) where n ≠ 6                 → only microsecond supported
              - NUMBER (bare, no precision/scale)   → rejected; must have explicit p,s
            Scale 9 (nanosecond) is technically valid but has a narrow value range
            (~1677–2262). Scale 6 (microsecond) supports ~year 294247 and is safe
            for all business data. This macro standardizes on scale 6.
            Note: VARIANT / ARRAY / OBJECT / GEOGRAPHY / GEOMETRY are natively
            supported in Iceberg v3 and do NOT require casting.

APPROACH:   1. Override `snowflake__create_table_as` to intercept BUILT_IN
               Iceberg builds (non-temporary SQL path only).
            2. Create a TEMPORARY VIEW over the model SQL — zero data written,
               pure metadata; Snowflake resolves column types immediately.
            3. DESCRIBE that view to enumerate column types.
            4. Build a wrapper SELECT that CASTs any incompatible timestamp/time
               scale to a safe equivalent before CREATE ICEBERG TABLE … AS (…).
            5. Drop the view and delegate the DDL to the adapter's
               `snowflake__create_table_as` (via `dbt` namespace).

SCOPE:      Only fires for BUILT_IN catalog Iceberg tables.
            All other cases (temp tables, INFO_SCHEMA, ICEBERG_REST, Python)
            are passed straight through to the adapter macro unchanged.

SAFE FOR:   - Full refresh / initial build  (existing_relation is none)
            - Incremental tmp relation creation (temporary=True → passthrough)
            - Non-Iceberg models (INFO_SCHEMA path → passthrough)

DISPATCH:   analytics_git overrides take priority over cp_dbt_standard_package
            and dbt adapter macros per the search_order in dbt_project.yml:
              dispatch:
                - macro_namespace: dbt
                  search_order: ['analytics_git', 'cp_dbt_standard_package', 'dbt']
===============================================================================
#}


{# ============================================================================
   SECTION 1: PRIMARY OVERRIDE — snowflake__create_table_as
   Intercepts the BUILT_IN Iceberg path; delegates everything else.
   ============================================================================ #}

{% macro snowflake__create_table_as(temporary, relation, compiled_code, language='sql') -%}

    {%- set catalog_relation = adapter.build_catalog_relation(config.model) -%}

    {#-- Only apply type-safety for non-temporary, SQL-language BUILT_IN Iceberg tables --#}
    {%- if language == 'sql' and not temporary
          and catalog_relation is not none
          and catalog_relation.catalog_type == 'BUILT_IN' -%}

        {%- set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(compiled_code, relation) -%}
        {{- dbt.snowflake__create_table_as(temporary, relation, safe_sql, language) -}}

    {%- else -%}
        {{- dbt.snowflake__create_table_as(temporary, relation, compiled_code, language) -}}
    {%- endif -%}

{%- endmacro %}


{# ============================================================================
   SECTION 3: TYPE-SAFETY ENGINE — iceberg_type_safe_wrap
   Creates a TEMPORARY VIEW over the model SQL, introspects column types via
   DESCRIBE VIEW, and emits a wrapper SELECT with safe CASTs where needed.

   Iceberg v3 type constraints enforced here (all timestamps → µs scale 6):
     TIMESTAMP_LTZ(n) n≠6     → TIMESTAMP_LTZ(6)    [standardize to µs]
     TIMESTAMP_NTZ(n) n≠6     → TIMESTAMP_NTZ(6)    [standardize to µs]
     TIMESTAMP_TZ(n)  any     → TIMESTAMP_LTZ(6)    [TZ→LTZ + standardize to µs]
     TIMESTAMP (bare)         → TIMESTAMP_NTZ(6)    [remove session-dependency]
     TIME(n) n≠6              → TIME(6)             [only µs precision in Iceberg]
     NUMBER (bare, no p/s)    → NUMBER(38,9)        [Iceberg requires explicit p,s]

   Why scale 6 over scale 9 for timestamps:
     Scale 9 (ns) max date: ~2262  → overflows on sentinel dates like 9999-12-31
     Scale 6 (µs) max date: ~294247 → safe for all business data

   Not cast (natively supported in Iceberg v3):
     VARIANT / ARRAY / OBJECT  — Iceberg v3 supports semi-structured types
     VARCHAR / TEXT / STRING   — maps cleanly without explicit cast
     NUMBER(p,s) with explicit p,s — already valid for Iceberg

   Returns the original compiled_code unchanged when:
     - execute == false (compile-only / dry-run)
     - no columns need casting
   ============================================================================ #}

{% macro iceberg_type_safe_wrap(compiled_code, relation) %}

    {%- if not execute -%}
        {{ return(compiled_code) }}
    {%- endif -%}

    {#-- Build a temp view name scoped to this relation --#}
    {%- set tmp_view = make_temp_relation(relation).incorporate(type='view') -%}

    {#-- Unique statement IDs prevent name collisions across 25 parallel threads --#}
    {%- set stmt_id = relation.identifier | replace('.', '_') -%}

    {#-- Create a TEMPORARY VIEW — zero data written; Snowflake resolves types from the query plan --#}
    {% call statement('iceberg_introspect_create__' ~ stmt_id) %}
        CREATE OR REPLACE TEMPORARY VIEW {{ tmp_view }} AS (
            {{ compiled_code }}
        )
    {% endcall %}

    {#-- Describe the view to get inferred column types --#}
    {%- set describe_sql -%}
        DESCRIBE VIEW {{ tmp_view }}
    {%- endset -%}
    {%- set col_results = run_query(describe_sql) -%}

    {#-- Classify each column --#}
    {%- set columns = [] -%}
    {%- set needs_cast = [] -%}

    {%- for row in col_results.rows -%}
        {%- set col_name  = row['name'] -%}
        {%- set col_type  = (row['type'] | string | upper).strip() -%}

        {#-- Flag any TIMESTAMP not already at scale 6 — all get cast to µs (6) --#}
        {%- set is_ts_ltz  = 'TIMESTAMP_LTZ' in col_type
                             and 'TIMESTAMP_LTZ(6)' not in col_type -%}
        {%- set is_ts_ntz  = 'TIMESTAMP_NTZ' in col_type
                             and 'TIMESTAMP_NTZ(6)' not in col_type -%}
        {%- set is_ts_tz   = 'TIMESTAMP_TZ'  in col_type
                             and 'TIMESTAMP_LTZ' not in col_type -%}
        {%- set is_ts_bare = col_type.startswith('TIMESTAMP')
                             and not is_ts_ltz and not is_ts_ntz and not is_ts_tz
                             and 'TIMESTAMP_LTZ' not in col_type
                             and 'TIMESTAMP_NTZ' not in col_type
                             and 'TIMESTAMP_TZ'  not in col_type -%}
        {%- set is_time    = col_type.startswith('TIME')
                             and 'TIMESTAMP' not in col_type
                             and 'TIME(6)' not in col_type -%}
        {#-- Flag bare NUMBER (no precision/scale) — Iceberg v3 requires explicit NUMBER(p,s) --#}
        {%- set is_bare_number = col_type in ('NUMBER', 'DECIMAL', 'NUMERIC') -%}
        {%- set is_incompatible = is_ts_ltz or is_ts_ntz or is_ts_tz
                                  or is_ts_bare or is_time or is_bare_number -%}

        {%- if is_incompatible -%}
            {%- do needs_cast.append(col_name) -%}
        {%- endif -%}

        {%- do columns.append({
              'name':            col_name,
              'type':            col_type,
              'is_ts_ltz':       is_ts_ltz,
              'is_ts_ntz':       is_ts_ntz,
              'is_ts_tz':        is_ts_tz,
              'is_ts_bare':      is_ts_bare,
              'is_time':         is_time,
              'is_bare_number':  is_bare_number,
              'is_incompatible': is_incompatible
        }) -%}
    {%- endfor -%}

    {#-- Drop the introspection view immediately — we no longer need it --#}
    {% call statement('iceberg_introspect_drop__' ~ stmt_id) %}
        DROP VIEW IF EXISTS {{ tmp_view }}
    {% endcall %}

    {#-- If nothing needed casting, return the original SQL untouched --#}
    {%- if needs_cast | length == 0 -%}
        {{ return(compiled_code) }}
    {%- endif -%}

    {#-- Build the type-safe wrapper SELECT --#}
    {%- set safe_select -%}
        SELECT
        {% for col in columns %}
            {%- set q = '"' ~ col.name ~ '"' -%}
            {%- if col.is_ts_ltz -%}
                CAST({{ q }} AS TIMESTAMP_LTZ(6)) AS {{ q }}
            {%- elif col.is_ts_ntz -%}
                CAST({{ q }} AS TIMESTAMP_NTZ(6)) AS {{ q }}
            {%- elif col.is_ts_tz -%}
                CAST({{ q }} AS TIMESTAMP_LTZ(6)) AS {{ q }}
            {%- elif col.is_ts_bare -%}
                CAST({{ q }} AS TIMESTAMP_NTZ(6)) AS {{ q }}
            {%- elif col.is_time -%}
                CAST({{ q }} AS TIME(6)) AS {{ q }}
            {%- elif col.is_bare_number -%}
                CAST({{ q }} AS NUMBER(38,9)) AS {{ q }}
            {%- else -%}
                {{ q }}
            {%- endif -%}
            {%- if not loop.last -%},{%- endif %}
        {%- endfor %}
        FROM (
            {{ compiled_code }}
        ) AS __iceberg_type_safe_source
    {%- endset -%}

    {{ return(safe_select) }}

{% endmacro %}


{# ============================================================================
   SECTION 4: SCHEMA EVOLUTION OVERRIDE — snowflake__alter_relation_add_remove_columns
   Intercepts incremental `sync_all_columns` to ensure new columns added via
   ALTER TABLE also adhere to Iceberg v3 type constraints.
   ============================================================================ #}

{% macro snowflake__alter_relation_add_remove_columns(relation, add_columns, remove_columns) %}

    {%- set catalog_relation = adapter.build_catalog_relation(config.model) -%}
    {%- set is_built_in_iceberg = catalog_relation is not none and catalog_relation.catalog_type == 'BUILT_IN' -%}
    {%- set has_add_columns = add_columns is not none and add_columns | length > 0 -%}
    
    {%- if is_built_in_iceberg and has_add_columns -%}
        
        {%- set sql -%}
            alter {{ relation.type }} {{ relation }}
            {%- for col in add_columns %}
                {%- set col_type = (col.data_type | string | upper).strip() -%}
                {%- set safe_type = col_type -%}
                
                {#-- Apply the same Iceberg type-safety rules --#}
                {%- if 'TIMESTAMP_LTZ' in col_type and 'TIMESTAMP_LTZ(6)' not in col_type -%}
                    {%- set safe_type = 'TIMESTAMP_LTZ(6)' -%}
                {%- elif 'TIMESTAMP_NTZ' in col_type and 'TIMESTAMP_NTZ(6)' not in col_type -%}
                    {%- set safe_type = 'TIMESTAMP_NTZ(6)' -%}
                {%- elif 'TIMESTAMP_TZ' in col_type and 'TIMESTAMP_LTZ' not in col_type -%}
                    {%- set safe_type = 'TIMESTAMP_LTZ(6)' -%}
                {%- elif col_type.startswith('TIMESTAMP') and 'TIMESTAMP_LTZ' not in col_type and 'TIMESTAMP_NTZ' not in col_type and 'TIMESTAMP_TZ' not in col_type -%}
                    {%- set safe_type = 'TIMESTAMP_NTZ(6)' -%}
                {%- elif col_type.startswith('TIME') and 'TIMESTAMP' not in col_type and 'TIME(6)' not in col_type -%}
                    {%- set safe_type = 'TIME(6)' -%}
                {%- elif col_type in ('NUMBER', 'DECIMAL', 'NUMERIC') -%}
                    {%- set safe_type = 'NUMBER(38,9)' -%}
                {%- endif -%}
                
                add column {{ adapter.quote(col.name) }} {{ safe_type }}{{ ',' if not loop.last }}
            {%- endfor -%}
            
            {{- ',' if remove_columns is not none and remove_columns | length > 0 else '' -}}
            
            {%- if remove_columns is not none -%}
                {%- for col in remove_columns %}
                    drop column {{ adapter.quote(col.name) }}{{ ',' if not loop.last }}
                {%- endfor -%}
            {%- endif -%}
        {%- endset -%}
        
        {{ return(sql) }}
        
    {%- else -%}
        
        {#-- Not a BUILT_IN Iceberg table, or no columns to add; delegate to dbt natively --#}
        {{ return(dbt.snowflake__alter_relation_add_remove_columns(relation, add_columns, remove_columns)) }}
        
    {%- endif -%}

{% endmacro %}


{# ============================================================================
   SECTION 5: DDL COLUMN BYPASS (The "Smart DDL Nuke")
   Prevents dbt from injecting YAML-defined column types (like bare `number`) 
   directly into the CREATE TABLE DDL block. This forces Snowflake to infer 
   the safe types entirely from our AS SELECT wrapper instead.
   ============================================================================ #}

{% macro snowflake__get_table_columns_and_constraints() %}
    {%- set catalog_relation = adapter.build_catalog_relation(config.model) -%}
    
    {%- if catalog_relation is not none and catalog_relation.catalog_type == 'BUILT_IN' -%}
        {#-- Bypass YAML column injection for Iceberg --#}
        {{ return('') }}
    {%- else -%}
        {#-- Native behavior for standard tables --#}
        {{ return(dbt.default__get_table_columns_and_constraints()) }}
    {%- endif -%}
{% endmacro %}