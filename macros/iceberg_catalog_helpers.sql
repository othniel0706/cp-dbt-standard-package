{#
  Iceberg Catalog Helper Macros
  -----------------------------
  Dynamically derive catalog names, integration names, and external volume names
  from DBT_SF_DATABASE_CUR / DBT_SF_DATABASE_CON environment variables.

  Usage in child repo dbt_project.yml:
    +catalog_name: "{{ cp_dbt_standard_package.get_iceberg_catalog_name('CUR') }}"

  Naming conventions (derived from env vars):
    DBT_SF_DATABASE_CUR=EX_CUR  ->  catalog: EX_CUR
                                     integration: EX_CUR_CATALOG_INT
                                     external_volume: EX_CUR_EXT_VOL
#}

{% macro get_iceberg_catalog_name(layer) %}
    {%- if layer | upper == 'CUR' -%}
        {{ return(env_var('DBT_SF_DATABASE_CUR')) }}
    {%- elif layer | upper == 'CON' -%}
        {{ return(env_var('DBT_SF_DATABASE_CON')) }}
    {%- else -%}
        {{ exceptions.raise_compiler_error("get_iceberg_catalog_name: layer must be 'CUR' or 'CON', got '" ~ layer ~ "'") }}
    {%- endif -%}
{% endmacro %}


{% macro get_iceberg_catalog_integration(layer) %}
    {%- if layer | upper == 'CUR' -%}
        {{ return(env_var('DBT_SF_DATABASE_CUR') ~ '_CATALOG_INT') }}
    {%- elif layer | upper == 'CON' -%}
        {{ return(env_var('DBT_SF_DATABASE_CON') ~ '_CATALOG_INT') }}
    {%- else -%}
        {{ exceptions.raise_compiler_error("get_iceberg_catalog_integration: layer must be 'CUR' or 'CON', got '" ~ layer ~ "'") }}
    {%- endif -%}
{% endmacro %}


{% macro get_iceberg_external_volume(layer) %}
    {%- if layer | upper == 'CUR' -%}
        {{ return(env_var('DBT_SF_DATABASE_CUR') ~ '_EXT_VOL') }}
    {%- elif layer | upper == 'CON' -%}
        {{ return(env_var('DBT_SF_DATABASE_CON') ~ '_EXT_VOL') }}
    {%- else -%}
        {{ exceptions.raise_compiler_error("get_iceberg_external_volume: layer must be 'CUR' or 'CON', got '" ~ layer ~ "'") }}
    {%- endif -%}
{% endmacro %}
