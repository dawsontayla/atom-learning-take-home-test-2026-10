-- =====================================================================
-- pupil_sat_scores: scaled (80-120) score per pupil per academic subject, as at a snapshot date.
--
-- Grain / primary key : (snapshot_date, pupil_id, subject_id)
-- Layers (as CTEs)    : 1. cleaning    - soft-deletes, incomplete sittings, orphans, non-academic subjects, snapshot cut-off
--                       2. aggregating - attempts / correct / raw percentage per pupil per subject
--                       3. scoring     - linear map of raw percentage onto the 80-120 scale
-- Idempotency         : re-running a snapshot_date deletes and rewrites only that partition, inside one transaction.
-- Usage               : set p_snapshot_date below (or bind it from a scheduled query) and run the whole script.
-- =====================================================================

declare p_snapshot_date date default date '2026-09-30';  -- the as-at date; the whole day (UTC) is included
declare p_run_timestamp timestamp default current_timestamp();
declare snapshot_cutoff timestamp;                        -- exclusive upper bound for all event timestamps

-- Scale anchors: 0% -> 80, 50% -> 100, 100% -> 120 (linear: floor + (ceiling - floor) * raw_percentage)
declare scale_floor int64 default 80;
declare scale_ceiling int64 default 120;

set snapshot_cutoff = timestamp(date_add(p_snapshot_date, interval 1 day));


-- ---------------------------------------------------------------------
-- Target table (no-op once it exists). Partitioned by snapshot_date, clustered for pupil/subject lookups.
-- ---------------------------------------------------------------------
create table if not exists `atom-analytics-candidates.tayla_dawson.pupil_sat_scores` (
  snapshot_date   date      not null options (description = 'As-at date of the snapshot; partition column'),
  pupil_id        string    not null,
  subject_id      string    not null,
  subject_name    string,
  total_attempted int64     options (description = 'COUNT(response_id) within the snapshot'),
  correct_answers int64     options (description = 'COUNTIF(is_correct = TRUE) within the snapshot'),
  raw_percentage  float64   options (description = 'correct_answers / total_attempted, 0 to 1'),
  scaled_score    int64     options (description = 'Linear map of raw_percentage onto 80-120, rounded'),
  run_timestamp   timestamp not null options (description = 'When this row was produced'),
  primary key (snapshot_date, pupil_id, subject_id) not enforced
)
partition by snapshot_date
cluster by pupil_id, subject_id
options (
  description = 'Scaled score (80-120) per pupil per academic subject, one partition per snapshot_date',
  require_partition_filter = true  -- queries must filter on snapshot_date, preventing accidental full scans
);


begin transaction;

-- Replace exactly one partition: delete it, then rewrite it.
delete from `atom-analytics-candidates.tayla_dawson.pupil_sat_scores`
where snapshot_date = p_snapshot_date;

insert into `atom-analytics-candidates.tayla_dawson.pupil_sat_scores`
  (snapshot_date, pupil_id, subject_id, subject_name,
   total_attempted, correct_answers, raw_percentage, scaled_score, run_timestamp)

with
  -- ===== 1. CLEANING =================================================
  clean_sittings as (
    select
      s.session_id,
      s.pupil_id
    from `atom-analytics-candidates.de_raw.assessment_sittings` as s
    inner join `atom-analytics-candidates.de_raw.pupils` as p
      on p.pupil_id = s.pupil_id
    where p.is_deleted = false
      and s.is_deleted = false
      and s.is_complete = true
      and s.started_at < snapshot_cutoff
      and s.finished_at < snapshot_cutoff
  ),

  academic_questions as (
    select
      question_id,
      subject_id,
      subject_name
    from `atom-analytics-candidates.de_raw.course_hierarchy`
    where upper(subject_name) not in ('WELLBEING', 'SCREENERS')
  ),

  -- The inner join to clean_sittings also drops responses whose session_id has no sitting (known orphans).
  clean_responses as (
    select
      cs.pupil_id,
      q.subject_id,
      q.subject_name,
      r.response_id,
      r.is_correct
    from `atom-analytics-candidates.de_raw.responses` as r
    inner join clean_sittings as cs
      on cs.session_id = r.session_id
    inner join academic_questions as q
      on q.question_id = r.question_id
    where r.answered_at < snapshot_cutoff
  ),

  -- ===== 2. AGGREGATING ==============================================
  pupil_subject_performance as (
    select
      pupil_id,
      subject_id,
      subject_name,
      count(response_id)         as total_attempted,
      countif(is_correct = true) as correct_answers
    from clean_responses
    group by pupil_id, subject_id, subject_name
  ),

  -- ===== 3. SCORING ==================================================
  scored as (
    select
      *,
      safe_divide(correct_answers, total_attempted) as raw_percentage
    from pupil_subject_performance
  )

select
  p_snapshot_date as snapshot_date,
  pupil_id,
  subject_id,
  subject_name,
  total_attempted,
  correct_answers,
  raw_percentage,
  cast(
    least(scale_ceiling, greatest(scale_floor, round(scale_floor + (scale_ceiling - scale_floor) * raw_percentage)))
    as int64
  ) as scaled_score,
  p_run_timestamp as run_timestamp
from scored;

-- Fail (and roll back) if the primary key is not unique within the partition just written.
assert (
  select count(*) = count(distinct concat(pupil_id, '|', subject_id))
  from `atom-analytics-candidates.tayla_dawson.pupil_sat_scores`
  where snapshot_date = p_snapshot_date
) as 'pupil_sat_scores primary key (snapshot_date, pupil_id, subject_id) is not unique';

commit transaction;
