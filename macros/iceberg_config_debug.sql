{% macro print_iceberg_config_debug() %}
    {{ log("=== ICEBERG CONFIG DEBUG (from cp-dbt-standard-package) ===", info=True) }}
    {{ log("Project name: " ~ project_name, info=True) }}

    {# Test 1: Can child repo read vars defined in the package's dbt_project.yml? #}
    {% set catalog_cur = var('iceberg_catalog_cur', 'NOT_FOUND') %}
    {% set catalog_con = var('iceberg_catalog_con', 'NOT_FOUND') %}
    {{ log("var('iceberg_catalog_cur'): " ~ catalog_cur, info=True) }}
    {{ log("var('iceberg_catalog_con'): " ~ catalog_con, info=True) }}

    {# Test 2: Are env vars accessible? (these always work) #}
    {% set db_cur = env_var('DBT_SF_DATABASE_CUR', 'NOT_SET') %}
    {% set db_con = env_var('DBT_SF_DATABASE_CON', 'NOT_SET') %}
    {{ log("env_var('DBT_SF_DATABASE_CUR'): " ~ db_cur, info=True) }}
    {{ log("env_var('DBT_SF_DATABASE_CON'): " ~ db_con, info=True) }}

    {# Test 3: Does flags.enable_iceberg_materializations from package propagate? #}
    {# If it does, dbt will have parsed without errors even though analytics-ex has no flags block #}
    {{ log("If you see this line, on-run-start hooks from packages execute successfully.", info=True) }}
    {{ log("Check if models built as Iceberg (flags test) or regular tables (flags did NOT propagate).", info=True) }}

    {{ log("=== END ICEBERG CONFIG DEBUG ===", info=True) }}
{% endmacro %}
