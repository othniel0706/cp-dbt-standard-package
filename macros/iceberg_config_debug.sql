{% macro print_iceberg_config_debug() %}
    {{ log("=== ICEBERG CONFIG DEBUG ===", info=True) }}
    {{ log("Project name: " ~ project_name, info=True) }}

    {# Test 1: Can we read the custom 'iceberg_config' namespace from the package? #}
    {% if var('iceberg_config', none) is not none %}
        {{ log("iceberg_config via var(): " ~ var('iceberg_config'), info=True) }}
    {% else %}
        {{ log("iceberg_config via var(): NOT FOUND", info=True) }}
    {% endif %}

    {# Test 2: Check if flags.enable_iceberg_materializations propagated from package #}
    {% set iceberg_flag = config.get('enable_iceberg_materializations', none) if config is defined else none %}
    {{ log("enable_iceberg_materializations via config: " ~ iceberg_flag, info=True) }}

    {# Test 3: Check env vars that would be used for catalog naming #}
    {% set db_cur = env_var('DBT_SF_DATABASE_CUR', 'NOT_SET') %}
    {% set db_con = env_var('DBT_SF_DATABASE_CON', 'NOT_SET') %}
    {{ log("DBT_SF_DATABASE_CUR: " ~ db_cur, info=True) }}
    {{ log("DBT_SF_DATABASE_CON: " ~ db_con, info=True) }}

    {{ log("=== END ICEBERG CONFIG DEBUG ===", info=True) }}
{% endmacro %}
