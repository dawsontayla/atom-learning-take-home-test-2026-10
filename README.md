# atom-learning-take-home-test-2026-10
A repository in which to store my code for the Atom Learning take-home test for the Data Engineer role.


## Core Work

The model is split into three layers, implemented as CTEs in [sql_files/02_pupil_sat_scores.sql](sql_files/02_pupil_sat_scores.sql):

| Layer | Responsibility |
|---|---|
| Cleaning | Remove soft-deleted pupils/sittings, incomplete sittings, orphaned responses and non-academic subjects; apply the snapshot cut-off |
| Aggregating | `total_attempted`, `correct_answers` and `raw_percentage` per pupil per subject |
| Score scaling | Map `raw_percentage` onto the 80-120 scale |

Investigation queries that informed these decisions are in [sql_files/initial_investigation.sql](sql_files/initial_investigation.sql).


## Architectural Decisions

### Scope: which subjects are scored
Of the seven subjects, only three are official SATs subjects. The options considered were to:
- apply scaling only to the official SATs subjects
- apply it only to academic subjects
- apply it only to qualitative subjects

**Decision:** score every academic subject (Maths, English, Science, Verbal Reasoning, Non-Verbal Reasoning) and exclude the non-academic `Wellbeing` and `Screeners`.

### Scaling formula
Having looked at the 2025 and 2026 GOV.UK scaled score conversions, I chose a single linear formula for all subjects. The national standard of 100 sits at roughly 50% of the marks, so the formula anchors on that:

| raw_percentage | scaled_score |
|---|---|
| 0% | 80 (lowest possible) |
| 50% | 100 (expected standard) |
| 100% | 120 (highest possible) |

`scaled_score = ROUND(LEAST(120, GREATEST(80, 80 + 40 * raw_percentage)))`

### Grain and keys
One row per pupil per subject per snapshot. Primary key: `(snapshot_date, pupil_id, subject_id)`. BigQuery primary keys are not enforced, so the script asserts uniqueness after writing each partition. Metadata column: `run_timestamp`.

### Point-in-time snapshots
`snapshot_date` is a parameter. A row is included only if, by the end of that day (UTC):
- the sitting had started (`started_at`) and finished (`finished_at`), and
- the response had been answered (`answered_at`).

Scores are therefore cumulative as at the snapshot date.

### Idempotency
The target table is created with `CREATE TABLE IF NOT EXISTS`. Each run then deletes and re-inserts only its own `snapshot_date` partition in a single transaction. Re-running a date gives the same rows and leaves other snapshots untouched. A plain `CREATE OR REPLACE TABLE` was rejected because it would overwrite every other snapshot with the latest run.

### Partitioning and clustering
- **Partitioned by `snapshot_date`.** BigQuery bills by bytes scanned, so partitioning keeps reads and per-snapshot rewrites cheap. This matters because `responses` will comfortably exceed 100M rows.
- **Clustered by `pupil_id`, `subject_id`** to prune on the most common lookups.
- **Source is unpartitioned.** The raw tables in `de_raw` are not partitioned, so each snapshot run performs full-column scans of the columns it reads. We accept that cost at source and partition downstream so everything built on top stays as cost-efficient as possible.
- **`require_partition_filter = TRUE`** on the output table. Any query against `pupil_sat_scores` must filter on `snapshot_date`, which prevents accidental full-table scans. The script's own `DELETE` and assert filter on `snapshot_date`, so they are unaffected.

### Filters applied in cleaning
- `UPPER(subject_name)` is not `'WELLBEING'` or `'SCREENERS'`, so the exclusion is case-insensitive.
- `pupils.is_deleted = FALSE`
- `assessment_sittings.is_deleted = FALSE` and `is_complete = TRUE`
- Responses with no matching sitting are dropped by the inner join (see DQIs).


## Data Quality Issues (DQIs)
- **Orphaned responses:** `responses.session_id` contains values that do not exist in `assessment_sittings.session_id`. These responses cannot be tied to a complete, non-deleted sitting, so they are excluded from scoring. See section 8 of `initial_investigation.sql` for queries that size and profile them.

Checks that came back clean:
- Primary keys are unique in every table.
- There are no fully duplicated rows.
- There are no blank, sentinel-text or padded values in STRING columns.
- There are no temporal values stored as STRING.
- Foreign keys are intact for `responses.pupil_id`, `responses.question_id` and `assessment_sittings.pupil_id`.
- `responses.pupil_id` matches `assessment_sittings.pupil_id` on every joined row, so the pupil can safely be taken from the sitting.
- Timestamps fall between Nov 2025 and Sep 2026.


## Assumptions
- **`is_no_attempt` rows count towards `total_attempted`.** `total_attempted` is `COUNT(response_id)`, so skipped questions stay in the denominator. A pupil who skips half the paper and gets the answered half fully correct should not be awarded the equivalent of 100%.


## Step 3 - Explanation
`Explain how you might predict a pupil's GCSE results from their primary-school
work. Tell us what you would need to build that - what data, what assumptions and why. A
few paragraphs is a complete answer`


### Data requirements
- Plenty of prior attainment data of students from diverse academic backgrounds.
- Any data scaling metric used.
- Continuous stream of engagement data from the platform.
- Published DfE Progress 8 and Attainment 8 benchmarks, to use as the prior.

### Assumptions
- The curriculum will not stay identical, but the topics that distinguish upper-end attainment are largely stable over time. Mastery is approximately measured by demonstrable comprehension of those core topics, so the model leans on them rather than on the full curriculum.
- Non-linear student learning trajectories.

### Approach
Due to the assumption of non-linear learning, I would use Bayesian updating as my underpinning method. I would use historical data of a student's KS2 results as a baseline for the model and the continuous activity on the platform as observation data. The prior would come from the published DfE Progress 8 and Attainment 8 benchmarks, which describe typical KS2-to-GCSE progress, so the model is usable before enough of our own pupils have reached GCSE. It would then be calibrated against our own cohorts as their outcomes arrive. This approach allows for a continuously updating distribution system to model. Snapshotting would be maintained to prevent any look-ahead bias.


## What I would have done with more time
- Provided more specific details on the DQIs and sample queries to view them (rather than attaching IDs to the README).
- Visually fleshed out the architecture further using a tool like Excalidraw or Lucidchart.
- More detailed answer to Step 3.
- Explored more optimisation techniques for columnar data.
- Materialised each layer as its own table or view, and moved scale parameters into a config table.
- Created a lookup table of subjects to reference against, replacing the hard-coded subject name exclusions.
- Added automated data quality tests, for example key uniqueness, orphan checks and score range checks.
- Spent more time testing the output.
- Removed more of the superfluous AI comments.
- Implemented different schematic layets/tables (rather than CTEs) for the cleaning-aggreagating-scaling process.