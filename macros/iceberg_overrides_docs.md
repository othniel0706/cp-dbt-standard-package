# `iceberg_overrides.sql` — Technical Reference

## Overview

`iceberg_overrides.sql` is a Jinja macro file in `cp-dbt-standard-package` that intercepts dbt's native Snowflake materialization macros. Its primary purpose is to make model output **safe for Snowflake Native Iceberg tables** (Iceberg v3) by dynamically inspecting and recasting column types that Iceberg requires explicit precision for, and by bypassing Iceberg-specific DDL/contract limitations.

- Semi-structured types (`ARRAY`, `OBJECT`) — serialized to JSON string
- `VARIANT` — **natively supported in Iceberg v3; no cast applied**
- Timestamp / numeric type normalization
- Avoiding invalid `ALTER TABLE` DDL on Iceberg tables for unsupported types
- Incremental merge strategies when semi-structured types are involved
- Contract DDL and assertion bypasses **scoped to Iceberg models only**

It is organized into four active sections (Section 2 was removed in v3 — see below). These macros are meant to be used with **dbt Core ≥ 1.11** and **dbt-snowflake ≥ 1.12** (Iceberg v3 support).

---

## Sections

### Section 1 — DDL Contract Bypass (Iceberg models only)

**Macros:** `get_table_columns_and_constraints`, `render_raw_columns_constraints` (and their `default__` / `snowflake__` variants)

dbt's contract enforcement injects `COLUMN col_name col_type NOT NULL` DDL into `CREATE TABLE` statements when a model has `contract: enforced`. Snowflake Iceberg tables do not support inline column-level constraints in DDL.

**Iceberg v3 scoping:** These overrides check `is_iceberg` (via `config.get('catalog_name')` or `config.get('table_format') == 'iceberg'`) before acting. For Iceberg models they return an empty string to silence constraint injection. For non-Iceberg models they delegate to `dbt.default__*` so that `contract: enforced` models on regular Snowflake tables continue to inject `NOT NULL` DDL correctly. This is important when the same package is used across both Iceberg and non-Iceberg repos.

---

### ~~Section 2 — Incremental Staging Type Override~~ (Removed in Iceberg v3)

**Macro:** `snowflake__get_tmp_relation_type` — **no longer overridden**

This section was removed because dbt-snowflake ≥ 1.12 natively handles the temp relation type for Iceberg models. The adapter's `dbt_snowflake_get_tmp_relation_type` already returns `"table"` for BUILT_IN Iceberg catalog models via `snowflake__is_catalog_linked_database`, making this override a duplicate.

---

### Section 3 — Materialization Overrides (Safe Temp Table Routing)

**Macros:** `snowflake__create_table_as`, `snowflake__create_view_as`, `snowflake__get_create_view_as_sql`, `snowflake__get_create_table_as_sql`, `snowflake__get_create_iceberg_table_as_sql`, `snowflake__create_iceberg_table_as`

These macros intercept every DDL path dbt uses to materialize a model. The pattern for table materializations is:

1. Run `iceberg_type_safe_wrap(compiled_code)` to get a cast-safe SELECT.
2. Pass that safe SQL directly into dbt's native table/view creation macros as the body of the real `CREATE ICEBERG <TABLE>` DDL.

This two-step approach ensures type coercions happen in a different SQL before being read into the strict Iceberg target.

### Section 3B & 3C — Incremental Merge & Alter Bypass

**Macros:** `snowflake__get_merge_sql`, `snowflake__alter_column_type`

**MERGE Override:** For incremental Iceberg models, the staging relation might natively hold semi-structured types that cannot be merged directly into Iceberg columns. This macro intercepts the MERGE operation, dynamically introspects the staging table, and wraps it in a temporary safe view (`__safe`) that casts untyped `ARRAY` and `OBJECT` to JSON strings before merging into the final target.

**Iceberg v3 change:** `VARIANT` is no longer included in the merge cast. Iceberg v3 natively stores `VARIANT` — casting it to `VARCHAR` via `TO_JSON` would corrupt the stored type. Only untyped `ARRAY` and `OBJECT` are cast.

**ALTER Bypass:** Prevents dbt from attempting to `ALTER COLUMN TYPE` on Iceberg tables for untyped `ARRAY`/`OBJECT` phantom mismatches (e.g. the staging view holds a native semi-structured type that doesn't match the Iceberg `VARCHAR` stored column). Skipping the ALTER prevents errors since the cast is handled at merge time.

**Iceberg v3 change:** `VARIANT` is no longer skipped in ALTER — `ALTER ICEBERG TABLE ... ALTER COLUMN col SET DATA TYPE VARIANT` is valid in v3 and now runs correctly.

---

### Section 4 — Contract Column Assertion Bypass (Iceberg models only)

**Macros:** `get_assert_columns_equivalent`, `default__get_assert_columns_equivalent`, `snowflake__get_assert_columns_equivalent`

dbt's Python-level contract validation compares columns returned by the model against the YAML contract definition. Because `iceberg_type_safe_wrap` recasts some types (e.g. `TIMESTAMP_TZ` → `TIMESTAMP_LTZ`), this comparison would false-fail for Iceberg models.

**Iceberg v3 scoping:** These overrides check `is_iceberg` before acting. For Iceberg models they return an empty string to silence the assertion. For non-Iceberg models they delegate to `dbt.default__get_assert_columns_equivalent` so that `contract: enforced` models on regular Snowflake tables (e.g. models declaring `data_type: timestamp_tz`) continue to validate correctly.

---

### Section 5 — `iceberg_type_safe_wrap` (The Wrapper Engine)

**Macro:** `iceberg_type_safe_wrap(compiled_code)`

This is the core engine. It dynamically introspects the output columns of any compiled SQL and wraps it with explicit `CAST` expressions for every type that Snowflake Native Iceberg cannot store or requires in a specific precision.

#### How It Works

1. **Create introspection view** — executes `CREATE OR REPLACE VIEW <temp_view> AS (<compiled_code>)` in the current schema. The closing `)` is placed on its own line to prevent trailing SQL comments in `compiled_code` from commenting it out.
2. **Describe the view** — runs `DESCRIBE VIEW <temp_view>` to get the resolved column names and types.
3. **Classify columns** — builds a list of columns that need casting and a complete list of all columns with their types.
4. **Drop the view** — executes `DROP VIEW IF EXISTS <temp_view>` immediately after introspection.
5. **Early exit** — if no columns need casting, returns `compiled_code` unchanged (zero overhead).
6. **Generate safe SELECT** — builds a new `SELECT` that wraps each column in the appropriate `CAST`, then returns `SELECT <casts> FROM (<compiled_code>) AS __iceberg_type_safe_source`.

#### Type Mapping

| Snowflake source type | Cast applied | Reason |
|---|---|---|
| `TIMESTAMP_LTZ` | `TIMESTAMP_LTZ(6)` | Explicit precision required |
| `TIMESTAMP_NTZ` | `TIMESTAMP_NTZ(6)` | Explicit precision required |
| `TIMESTAMP_TZ` | `TIMESTAMP_LTZ(6)` | Iceberg does not support `TZ`; converted to `LTZ` |
| `TIMESTAMP` (unqualified) | `TIMESTAMP_NTZ(6)` | Ambiguous; normalized to `NTZ` |
| `TIME` | `TIME(6)` | Explicit precision required |
| `ARRAY` / `OBJECT` (untyped) | `TO_JSON(...) AS VARCHAR(16777216)` | Untyped semi-structured types not supported as Iceberg stored column types |
| `VARCHAR` / `STRING` | `VARCHAR(16777216)` | Snowflake Iceberg max VARCHAR is 16 MB |
| `NUMBER` / `DECIMAL` / `NUMERIC` (unspecified or `38,0`) | `NUMBER(38, 0)` | Unqualified NUMBER defaults may be rejected |
| `VARIANT` | **no cast** | **Natively supported in Iceberg v3** (GA May 2026) |
| All other types | **no cast** | Passed through as-is |

---

## FAQs

### Will this trigger on non-Iceberg models?

**`iceberg_type_safe_wrap` (Section 5) runs on every model** because the Section 3 materialization overrides are global. However, the macro performs a live `DESCRIBE VIEW` and only injects casts for columns that actually need them. For models with no castable types the early-exit path fires and the original SQL is returned unchanged with minimal overhead (two lightweight DDL statements).

**Sections 1 and 4** (contract DDL and assertion bypasses) are scoped to Iceberg-only via an `is_iceberg` guard. Non-Iceberg models with `contract: enforced` are unaffected and continue to validate normally.

---

### Why does `TIMESTAMP_TZ` get converted to `TIMESTAMP_LTZ`?

Snowflake Native Iceberg (built-in catalog) maps Iceberg's `timestamptz` type to `TIMESTAMP_LTZ`. Storing a `TIMESTAMP_TZ` column directly is not supported. The cast to `TIMESTAMP_LTZ(6)` preserves timezone offset semantics while conforming to the Iceberg type system.

---

### Why are `ARRAY` and `OBJECT` cast to `VARCHAR`? What about `VARIANT`?

**Iceberg v3 update:** `VARIANT` is now natively supported in Snowflake Iceberg v3 (GA May 2026) and is **no longer cast**. It is stored as-is without any `TO_JSON` conversion.

Untyped `ARRAY` and `OBJECT` still cannot be stored as Iceberg column types and must be serialized to JSON string (`VARCHAR(16777216)`) via `TO_JSON()` for the `CREATE ICEBERG TABLE` DDL to succeed.

> **Important downstream implication for `ARRAY`/`OBJECT` columns**: any model that reads from an Iceberg table and uses Snowflake's semi-structured path accessor syntax (e.g. `col:field::TYPE`) on such a column will fail at query time because the column is stored as `VARCHAR`. Those models must use `PARSE_JSON(col):field::TYPE` instead. This does **not** apply to `VARIANT` columns, which remain as native semi-structured types.

---

### What happens with columns that use semi-structured path notation (`:`) in their name?

`DESCRIBE VIEW` can return column names containing `:` when the view references a semi-structured accessor path inline (e.g. `inherent_risk:value`). Wrapping such a name in `CAST("col:field" AS ...)` is misinterpreted by Snowflake as `GET(col, 'field')`, which fails with `Invalid argument types for function 'GET'`. The macro detects any column name containing `:` and passes it through without a cast.

---

### Why is VARCHAR capped at 16,777,216?

That is Snowflake's maximum `VARCHAR` length for Iceberg tables (16 MB). The original codebase used `VARCHAR(134217728)` (128 MB), which exceeded this limit and caused `unexpected '<EOF>'` SQL compilation errors.

---

### What if a model's SQL ends with a trailing comment (`---` or `--`)?

A trailing single-line comment at the end of `compiled_code` would have commented out the `)` that closes the `CREATE OR REPLACE VIEW ... AS (...)` introspection wrapper, causing an `unexpected '<EOF>'` error. The fix places the closing `)` on its own new line, so a trailing comment only affects the last line of `compiled_code` itself, never the wrapper syntax.

---

### Does this affect temporary tables used by incremental models?

No. `snowflake__create_table_as` skips the two-step wrap-and-cast path when `temporary=True`. Temporary staging relations for incremental models are regular Snowflake tables (not Iceberg), accept all types natively, and do not need type coercion.

---

### What is the `__dbt_pre` table?

A short-lived `TEMPORARY TABLE` created in the same session as the dbt run, named `<relation>__dbt_pre`. It holds the output of the cast-safe SELECT. The final `CREATE ICEBERG TABLE ... AS SELECT * FROM __dbt_pre` then reads from it. Being a temporary table it is automatically dropped at session end and does not persist.

---

## Edge Cases Captured & Mitigated

| Edge case | Symptom without fix | Mitigation |
|---|---|---|
| Untyped `ARRAY` / `OBJECT` output columns | `Unsupported data type 'ARRAY'/'OBJECT' for iceberg tables` | Cast to `TO_JSON(...) AS VARCHAR(16777216)` |
| `VARIANT` output columns | ~~Cast required~~ — **no longer an issue in Iceberg v3** | `VARIANT` is natively supported; no cast applied |
| `TIMESTAMP_TZ` output columns | DDL rejected by Iceberg type system | Cast to `TIMESTAMP_LTZ(6)` |
| Unqualified `TIMESTAMP` columns | Ambiguous precision may be rejected | Normalize to `TIMESTAMP_NTZ(6)` |
| `VARCHAR` exceeding 16 MB | `unexpected '<EOF>'` compilation error | Cap cast at `VARCHAR(16777216)` |
| Trailing `---` / `--` comment in model SQL | `unexpected '<EOF>'` in introspection view | Closing `)` on its own line |
| Temporary incremental staging tables | Oversized generated SQL, unnecessary overhead | Guard: skip wrap when `temporary=True` |
| Semi-structured column name aliases (`:` in name) | `Invalid argument types for function 'GET'` | Guard: skip cast when column name contains `:` |
| Jinja loop variable scoping (`is_array_or_object`) | ARRAY columns not cast despite detection in first loop | Recalculate `is_array_or_object` inside the cast loop |
| dbt YAML contract DDL injection on Iceberg models | `CREATE ICEBERG TABLE` fails with inline constraint syntax | §1 override returns empty string for Iceberg models only; non-Iceberg contracts unaffected |
| dbt Python contract column assertion on Iceberg models | Build failure due to type name mismatch after casting | §4 override returns empty string for Iceberg models only; non-Iceberg contract validation runs normally |
| Iceberg incremental models using view as temp relation | Merge/delete+insert fails — can't merge from a view into Iceberg | **Removed in v3** — dbt-snowflake ≥ 1.12 handles this natively |
| Phantom type mismatches during incremental runs (ARRAY/OBJECT) | dbt attempts `ALTER COLUMN TYPE` and fails | `snowflake__alter_column_type` skips ALTER for untyped ARRAY/OBJECT on Iceberg |
| Phantom type mismatch for VARIANT during incremental runs | dbt attempts `ALTER COLUMN TYPE VARIANT` | **Resolved in v3** — VARIANT ALTER is valid; no longer skipped |
