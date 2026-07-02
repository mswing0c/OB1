-- =====================================================================
-- Open Brain — Pass 2.5 — Digest dedup + system-log timestamp source_id
-- =====================================================================
-- Purpose:    Resolve the two issues surfaced by Pass 2 verification:
--             (1) tmc01-daily-digest 2026-04-28 has 2 rows (real duplicate).
--                 User decision: keep the longer one, delete the shorter.
--             (2) system-log source_id is too coarse (just date), causing
--                 false-positive "duplicates" for legitimate multi-run days.
--                 Fix: use created_at timestamp for guaranteed uniqueness.
-- Risk:       LOW for Block 1 (UPDATE only, idempotent guard).
--             MEDIUM for Block 0 (DELETE — irreversible). Mitigation: only
--             deletes the shorter of two digest rows for ONE specific date,
--             and the verification asserts exactly 1 row remains for that
--             date. The deleted row's embedding is permanently lost; the
--             retained row contains a superset of the same day's content.
-- Reversible: NO for Block 0 once committed (DELETE is destructive). Pass 1
--             snapshot columns belonged to that row and are gone with it.
--             Reversible YES for Block 1 (re-run idempotent update).
-- LLM cost:   $0
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Block 0. Reconcile 2026-04-28 daily digest duplicate.
--          Keep the longer (more comprehensive) version per user choice.
-- ---------------------------------------------------------------------

-- Pre-flight: confirm there are exactly 2 rows for this digest before delete.
DO $$
DECLARE
    n INTEGER;
    longest_len INTEGER;
    shortest_len INTEGER;
BEGIN
    SELECT COUNT(*) INTO n
    FROM   thoughts
    WHERE  source = 'tmc01-daily-digest' AND source_id = '2026-04-28';
    IF n <> 2 THEN
        RAISE EXCEPTION 'Block 0 pre-flight: expected 2 rows for 2026-04-28 digest, got %. Aborting.', n;
    END IF;

    SELECT MAX(LENGTH(content)), MIN(LENGTH(content))
    INTO   longest_len, shortest_len
    FROM   thoughts
    WHERE  source = 'tmc01-daily-digest' AND source_id = '2026-04-28';
    RAISE NOTICE 'Block 0 pre-flight: 2 rows present. Longest=%, shortest=%. Deleting shortest.', longest_len, shortest_len;
END $$;

-- Delete the shorter row. Uses a deterministic ORDER BY content_length to
-- guarantee the SAME row is selected even if rerun (idempotency note: this
-- migration is run once; the WHERE filter on count=2 in pre-flight prevents
-- accidental over-delete on rerun because after this, count=1).
WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY LENGTH(content) DESC, created_at ASC) AS rn
    FROM   thoughts
    WHERE  source = 'tmc01-daily-digest' AND source_id = '2026-04-28'
)
DELETE FROM thoughts
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

-- Post-check
DO $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n
    FROM   thoughts
    WHERE  source = 'tmc01-daily-digest' AND source_id = '2026-04-28';
    IF n <> 1 THEN
        RAISE EXCEPTION 'Block 0 post-check: expected 1 row remaining, got %. Aborting.', n;
    END IF;
    RAISE NOTICE 'Block 0 complete. 1 row remains for 2026-04-28 digest.';
END $$;

-- ---------------------------------------------------------------------
-- Block 1. Refine system-log source_id to use created_at timestamp.
--          Sets canonical form for ALL system-log rows (including those
--          with NULL or date-only source_ids from Pass 2). Idempotent:
--          only fires when the current value differs from the target.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    source_id = to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
WHERE  source = 'system-log'
  AND  source_id IS DISTINCT FROM to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

DO $$ BEGIN RAISE NOTICE 'Block 1 (system-log timestamp source_id) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total                       INTEGER;
    digest_dup_pairs            INTEGER;
    syslog_total                INTEGER;
    syslog_with_iso_timestamp   INTEGER;
    syslog_dup_pairs            INTEGER;
    all_dup_pairs               INTEGER;
    sample_syslog_id            TEXT;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;

    SELECT COUNT(*) INTO digest_dup_pairs
    FROM (
        SELECT 1 FROM thoughts
        WHERE  source = 'tmc01-daily-digest' AND source_id IS NOT NULL
        GROUP  BY source, source_id HAVING COUNT(*) > 1
    ) sub;

    SELECT COUNT(*) INTO syslog_total
    FROM   thoughts WHERE source = 'system-log';

    SELECT COUNT(*) INTO syslog_with_iso_timestamp
    FROM   thoughts
    WHERE  source = 'system-log' AND source_id ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$';

    SELECT COUNT(*) INTO syslog_dup_pairs
    FROM (
        SELECT 1 FROM thoughts
        WHERE  source = 'system-log' AND source_id IS NOT NULL
        GROUP  BY source, source_id HAVING COUNT(*) > 1
    ) sub;

    SELECT COUNT(*) INTO all_dup_pairs
    FROM (
        SELECT 1 FROM thoughts
        WHERE  source_id IS NOT NULL
        GROUP  BY source, source_id HAVING COUNT(*) > 1
    ) sub;

    SELECT source_id INTO sample_syslog_id
    FROM   thoughts WHERE source = 'system-log' ORDER BY created_at DESC LIMIT 1;

    RAISE NOTICE '======== POST-PASS-2.5 VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                            %', total;
    RAISE NOTICE 'tmc01-daily-digest duplicate pairs:        % (was 1, must be 0)', digest_dup_pairs;
    RAISE NOTICE 'system-log total:                          %', syslog_total;
    RAISE NOTICE 'system-log with ISO-Z timestamp source_id: % (must equal %)', syslog_with_iso_timestamp, syslog_total;
    RAISE NOTICE 'system-log duplicate pairs:                % (was 3, must be 0)', syslog_dup_pairs;
    RAISE NOTICE 'ALL (source, source_id) duplicate pairs:   % (was 4, must be 0)', all_dup_pairs;
    RAISE NOTICE 'Sample system-log source_id:               %', sample_syslog_id;
    RAISE NOTICE '=============================================';

    IF digest_dup_pairs > 0 THEN
        RAISE EXCEPTION 'Digest duplicate still present: % pair(s)', digest_dup_pairs;
    END IF;
    IF syslog_with_iso_timestamp <> syslog_total THEN
        RAISE EXCEPTION 'Some system-log rows still missing ISO-Z source_id: %/%', syslog_with_iso_timestamp, syslog_total;
    END IF;
    IF syslog_dup_pairs > 0 THEN
        RAISE EXCEPTION 'system-log duplicates remain: %', syslog_dup_pairs;
    END IF;
    IF all_dup_pairs > 0 THEN
        RAISE EXCEPTION 'Some (source, source_id) duplicates remain across all sources: %', all_dup_pairs;
    END IF;
END $$;

COMMIT;
