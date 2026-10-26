-- Getting a quick look at all the columns
select table_name, column_name, data_type from `atom-analytics-candidates.de_raw.INFORMATION_SCHEMA.COLUMNS`
order by table_name, ordinal_position;


-- Distinct subjects
select distinct subject_name from `atom-analytics-candidates.de_raw.course_hierarchy`;

-- 1   Non-Verbal Reasoning
-- 2	Wellbeing
-- 3	English
-- 4	Science
-- 5	Maths
-- 6	Verbal Reasoning
-- 7	Screeners

-- Links:
-- https://www.gov.uk/government/publications/key-stage-2-tests-2026-scaled-scores
-- https://www.gov.uk/government/publications/key-stage-2-tests-2025-scaled-scores


-- =====================================================================
-- 1. Table inventory: row counts, size, freshness (metadata only, no table scan)
-- =====================================================================
select
  table_id as table_name,
  row_count,
  round(size_bytes / pow(1024, 2), 2) as size_mb,
  timestamp_millis(creation_time) as created_at,
  timestamp_millis(last_modified_time) as last_modified_at,
  if(type = 1, 'TABLE', 'VIEW') as table_type
from `atom-analytics-candidates.de_raw.__TABLES__`
order by table_name;


-- =====================================================================
-- 2. Null profile for every column in every table (one result set)
--    Builds one UNION ALL query from INFORMATION_SCHEMA, so it adapts to schema changes.
--    Scans every column once: dry-run first to check bytes billed.
--    ARRAY / STRUCT / JSON / GEOGRAPHY columns are skipped (no plain null/distinct semantics).
-- =====================================================================
declare null_profile_sql string;

set null_profile_sql = (
  select string_agg(
    format(
      "select '%s' as table_name, '%s' as column_name, '%s' as data_type, count(*) as n_rows, "
      || "countif(`%s` is null) as n_null, approx_count_distinct(`%s`) as approx_n_distinct "
      || "from `atom-analytics-candidates.de_raw.%s`",
      table_name, column_name, data_type, column_name, column_name, table_name
    ),
    ' union all '
  )
  from `atom-analytics-candidates.de_raw.INFORMATION_SCHEMA.COLUMNS`
  where data_type not like 'ARRAY%'
    and data_type not like 'STRUCT%'
    and data_type not in ('JSON', 'GEOGRAPHY')
);

execute immediate
  "select *, round(100 * safe_divide(n_null, n_rows), 2) as pct_null from (" -- percentage null
  || null_profile_sql
  || ") order by table_name, column_name";


-- =====================================================================
-- 3. Disguised nulls in STRING columns: blanks, sentinel text, padding
-- =====================================================================
declare string_profile_sql string;

set string_profile_sql = (
  select string_agg(
    format(
      "select '%s' as table_name, '%s' as column_name, "
      || "countif(trim(`%s`) = '') as n_blank, "
      || "countif(lower(trim(`%s`)) in ('null', 'none', 'n/a', 'na', 'nan', 'undefined', '-')) as n_sentinel_text, "
      || "countif(`%s` != trim(`%s`)) as n_padded "
      || "from `atom-analytics-candidates.de_raw.%s`",
      table_name, column_name, column_name, column_name, column_name, column_name, table_name
    ),
    ' union all '
  )
  from `atom-analytics-candidates.de_raw.INFORMATION_SCHEMA.COLUMNS`
  where data_type = 'STRING'
);

execute immediate
  "select * from (" || string_profile_sql || ") "
  || "where n_blank + n_sentinel_text + n_padded > 0 order by table_name, column_name";

-- no result

-- =====================================================================
-- 4a. Timestamp handling: native DATE / DATETIME / TIMESTAMP columns
--     Range, future-dated values, implausibly old values, epoch-like values.
--     NB: DATETIME has no timezone, timestamp(datetime) assumes UTC.
--     ASSUMPTION: 2000-01-01 is the earliest plausible date. Adjust once the domain is clear.
-- =====================================================================
declare ts_profile_sql string;

set ts_profile_sql = (
  select string_agg(
    format(
      "select '%s' as table_name, '%s' as column_name, '%s' as data_type, "
      || "cast(min(`%s`) as string) as min_value, cast(max(`%s`) as string) as max_value, "
      || "countif(`%s` is null) as n_null, "
      || "countif(timestamp(`%s`) > current_timestamp()) as n_future, "
      || "countif(timestamp(`%s`) < timestamp '2000-01-01') as n_before_2000, "
      || "countif(timestamp(`%s`) < timestamp '1970-01-02') as n_epoch_like "
      || "from `atom-analytics-candidates.de_raw.%s`",
      table_name, column_name, data_type,
      column_name, column_name, column_name, column_name, column_name, column_name, table_name
    ),
    ' union all '
  )
  from `atom-analytics-candidates.de_raw.INFORMATION_SCHEMA.COLUMNS`
  where data_type in ('DATE', 'DATETIME', 'TIMESTAMP')
);

execute immediate "select * from (" || ts_profile_sql || ") order by table_name, column_name";

-- nov 2025 to sept 2026

-- =====================================================================
-- 4b. Timestamps stored as STRING (name looks temporal): do they parse?
--     safe_cast only accepts ISO-style formats, so unparseable != necessarily bad, but inspect the sample.
-- =====================================================================
declare str_ts_sql string;

set str_ts_sql = (
  select string_agg(
    format(
      "select '%s' as table_name, '%s' as column_name, "
      || "countif(`%s` is not null) as n_non_null, "
      || "countif(`%s` is not null and safe_cast(`%s` as timestamp) is null) as n_unparseable, "
      || "any_value(if(`%s` is not null and safe_cast(`%s` as timestamp) is null, `%s`, null)) as sample_unparseable "
      || "from `atom-analytics-candidates.de_raw.%s`",
      table_name, column_name, column_name, column_name, column_name,
      column_name, column_name, column_name, table_name
    ),
    ' union all '
  )
  from `atom-analytics-candidates.de_raw.INFORMATION_SCHEMA.COLUMNS`
  where data_type = 'STRING'
    and regexp_contains(lower(column_name), r'(date|time|_at$|_on$|dob|birth)')
);

-- str_ts_sql is null when no column name matches; the guard avoids executing a null statement.
execute immediate
  ifnull("select * from (" || str_ts_sql || ") order by table_name, column_name", "select 'no candidate string timestamp columns' as note");

-- none

-- =====================================================================
-- 5. Fully duplicated rows per table
-- =====================================================================
select 'responses' as table_name, count(*) as n_rows, count(distinct to_json_string(t)) as n_distinct_rows
from `atom-analytics-candidates.de_raw.responses` as t
union all
select 'assessment_sittings', count(*), count(distinct to_json_string(t))
from `atom-analytics-candidates.de_raw.assessment_sittings` as t
union all
select 'course_hierarchy', count(*), count(distinct to_json_string(t))
from `atom-analytics-candidates.de_raw.course_hierarchy` as t
union all
select 'pupils', count(*), count(distinct to_json_string(t))
from `atom-analytics-candidates.de_raw.pupils` as t;

-- all distinct


-- =====================================================================
-- 6. Foreign key candidates: same column name in more than one table, flagging type mismatches
--    (a join on mismatched types fails or silently casts)
-- =====================================================================
select
  column_name,
  array_agg(struct(table_name, data_type) order by table_name) as appears_in,
  count(distinct data_type) as n_distinct_types
from `atom-analytics-candidates.de_raw.INFORMATION_SCHEMA.COLUMNS`
group by column_name
having count(distinct table_name) > 1
order by n_distinct_types desc, column_name;


-- =====================================================================
-- 7a. Key uniqueness: set the table and column, run. Expect n_rows = n_distinct_keys for a primary key.
-- =====================================================================
declare key_table string default '<table>';
declare key_column string default '<key_column>';

execute immediate replace(replace("""
select
  count(*) as n_rows,
  countif({col} is null) as n_null_keys,
  count(distinct {col}) as n_distinct_keys,
  count(*) - countif({col} is null) - count(distinct {col}) as n_duplicate_key_rows
from `atom-analytics-candidates.de_raw.{tbl}`
""", '{tbl}', key_table), '{col}', key_column);

-- pupils/pupil_id
-- assessment_sittings/session_id
-- responses/response_id
-- course_hierarchy/question_id

-- All tables behave as expected

-- =====================================================================
-- 7b. Foreign key integrity (orphans): child.fk must exist in parent.pk
--     Parent keys are de-duplicated first so a non-unique parent key can't inflate child row counts.
-- =====================================================================
DECLARE child_table STRING DEFAULT 'responses'; -- PAIR A
DECLARE child_fk STRING DEFAULT 'pupil_id';
DECLARE parent_table STRING DEFAULT 'pupils';
DECLARE parent_pk STRING DEFAULT 'pupil_id';
-- 0 orphan keys

-- DECLARE child_table STRING DEFAULT 'responses'; -- PAIR B
-- DECLARE child_fk STRING DEFAULT 'session_id';
-- DECLARE parent_table STRING DEFAULT 'assessment_sittings';
-- DECLARE parent_pk STRING DEFAULT 'session_id';
-- orphan keys. will inspect more closely
-- responses existing that aren't in assessment sittings


-- DECLARE child_table STRING DEFAULT 'responses'; -- PAIR C
-- DECLARE child_fk STRING DEFAULT 'question_id';
-- DECLARE parent_table STRING DEFAULT 'course_hierarchy';
-- DECLARE parent_pk STRING DEFAULT 'question_id';
-- no orphan keys


-- DECLARE child_table STRING DEFAULT 'assessment_sittings'; -- PAIR D
-- DECLARE child_fk STRING DEFAULT 'pupil_id';
-- DECLARE parent_table STRING DEFAULT 'pupils';
-- DECLARE parent_pk STRING DEFAULT 'pupil_id';
-- no orphan keys

execute immediate replace(replace(replace(replace("""
select
  count(*) as n_child_rows,
  countif(c.{fk} is null) as n_null_fk,
  countif(c.{fk} is not null and p.k is null) as n_orphan_rows,
  count(distinct if(c.{fk} is not null and p.k is null, c.{fk}, null)) as n_orphan_distinct_keys,
  array_agg(distinct  if(c.{fk} is not null and p.k is null, c.{fk}, null) ignore nulls limit 5) as sample_orphan_keys
from `atom-analytics-candidates.de_raw.{child}` as c
left join (select distinct {pk} as k from `atom-analytics-candidates.de_raw.{parent}`) as p
  on c.{fk} = p.k
""", '{child}', child_table), '{fk}', child_fk), '{parent}', parent_table), '{pk}', parent_pk);


-- =====================================================================
-- 8. Closer look: responses.session_id not found in assessment_sittings.session_id (PAIR B)
-- =====================================================================

-- 8a. Size of the gap in both directions (distinct session_ids).
--     only_in_sittings is informational: a sitting with no responses may be legitimate (abandoned sitting).
with
  r as (select distinct session_id as k from `atom-analytics-candidates.de_raw.responses` where session_id is not null),
  s as (select distinct session_id as k from `atom-analytics-candidates.de_raw.assessment_sittings` where session_id is not null)
select
  countif(r.k is not null and s.k is not null) as n_sessions_in_both,
  countif(s.k is null) as n_sessions_only_in_responses,
  countif(r.k is null) as n_sessions_only_in_sittings
from r full outer join s on r.k = s.k;


-- 8b. One row per orphan session_id: how big it is, who it belongs to, and whether it would match
--     after trim/lower-casing (i.e. a formatting problem rather than a genuinely missing sitting).
with
  sitting_keys as (
    select lower(trim(cast(session_id as string))) as k_norm, any_value(session_id) as k
    from `atom-analytics-candidates.de_raw.assessment_sittings`
    group by k_norm
  ),
  orphans as (
    select r.*
    from `atom-analytics-candidates.de_raw.responses` as r
    left join (select distinct session_id as k from `atom-analytics-candidates.de_raw.assessment_sittings`) as s
      on r.session_id = s.k
    where r.session_id is not null and s.k is null
  )
select
  o.session_id as orphan_session_id,
  length(cast(o.session_id as string)) as key_length,
  count(*) as n_responses,
  count(distinct o.pupil_id) as n_pupils,
  count(distinct o.question_id) as n_questions,
  logical_or(sk.k is not null) as matches_after_normalising,
  any_value(sk.k) as normalised_match
from orphans as o
left join sitting_keys as sk on lower(trim(cast(o.session_id as string))) = sk.k_norm
group by orphan_session_id, key_length
order by n_responses desc;


-- 8c. Key shape comparison: letters -> 'a', digits -> '9'. A pattern that only appears on the orphan side
--     (different prefix, length, separators) points at a different source or format.
with
  sitting_keys as (select distinct session_id as k from `atom-analytics-candidates.de_raw.assessment_sittings`),
  response_keys as (select distinct session_id as k from `atom-analytics-candidates.de_raw.responses` where session_id is not null)
select
  rk.k in (select k from sitting_keys) as found_in_sittings,
  regexp_replace(regexp_replace(cast(rk.k as string), r'[A-Za-z]', 'a'), r'[0-9]', '9') as key_pattern,
  count(*) as n_keys,
  any_value(rk.k) as example_key
from response_keys as rk
group by found_in_sittings, key_pattern
order by found_in_sittings, n_keys desc;


--- 9. Checking for mismatched pupil IDs
SELECT
  COUNT(*) AS total_joined_responses,
  COUNTIF(r.pupil_id = s.pupil_id) AS matching_pupil_ids,
  COUNTIF(r.pupil_id != s.pupil_id) AS mismatched_pupil_ids,
  ROUND(100 * COUNTIF(r.pupil_id != s.pupil_id) / COUNT(*), 4) AS pct_mismatched
FROM `atom-analytics-candidates.de_raw.responses` r
JOIN `atom-analytics-candidates.de_raw.assessment_sittings` s
  ON r.session_id = s.session_id;



--- 10. Column names: 
-- Column names:
-- Row	table_name	column_name	data_type
-- 1	assessment_sittings	session_id	STRING
-- 2	assessment_sittings	pupil_id	STRING
-- 3	assessment_sittings	assessment_id	STRING
-- 4	assessment_sittings	session_type	STRING
-- 5	assessment_sittings	style	STRING
-- 6	assessment_sittings	year_group_at_sitting	INT64
-- 7	assessment_sittings	total_questions	INT64
-- 8	assessment_sittings	is_complete	BOOL
-- 9	assessment_sittings	is_deleted	BOOL
-- 10	assessment_sittings	started_at	TIMESTAMP
-- 11	assessment_sittings	finished_at	TIMESTAMP
-- 12	course_hierarchy	question_id	STRING
-- 13	course_hierarchy	atom_id	STRING
-- 14	course_hierarchy	subtopic_id	STRING
-- 15	course_hierarchy	topic_id	STRING
-- 16	course_hierarchy	subject_id	STRING
-- 17	course_hierarchy	subject_name	STRING
-- 18	pupils	pupil_id	STRING
-- 19	pupils	is_deleted	BOOL
-- 20	responses	response_id	STRING
-- 21	responses	pupil_id	STRING
-- 22	responses	session_id	STRING
-- 23	responses	session_type	STRING
-- 24	responses	question_id	STRING
-- 25	responses	is_correct	BOOL
-- 26	responses	is_no_attempt	BOOL
-- 27	responses	seconds_taken	INT64
-- 28	responses	question_number	INT64
-- 29	responses	answered_at	TIMESTAMP