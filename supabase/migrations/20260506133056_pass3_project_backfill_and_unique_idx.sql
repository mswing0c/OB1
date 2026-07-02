-- =====================================================================
-- Open Brain — Pass 3 — Project backfill + UNIQUE source_id index
-- =====================================================================
-- Purpose:    (1) Populate the `project` column with canonical codes:
--                 TMC-01, GM-01, OPEN-BRAIN, SALTWORKS-OS, MISC.
--             (2) Add the UNIQUE constraint on (source, source_id) now that
--                 Pass 2.5 cleaned all duplicates.
-- Risk:       LOW — additive UPDATE on an empty column; UNIQUE INDEX add.
--             Pre-flight: assert 0 duplicate (source, source_id) pairs
--             before attempting unique index creation.
-- Reversible: YES (UPDATE: SET project = NULL; DROP INDEX).
-- LLM cost:   $0
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Block 0. Pre-flight: confirm zero duplicates so UNIQUE INDEX can succeed.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    dup_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO dup_count
    FROM (
        SELECT 1 FROM thoughts
        WHERE  source_id IS NOT NULL
        GROUP  BY source, source_id HAVING COUNT(*) > 1
    ) sub;
    IF dup_count > 0 THEN
        RAISE EXCEPTION 'Block 0 pre-flight: % duplicate (source, source_id) pairs remain. Pass 2.5 may not have completed.', dup_count;
    END IF;
    RAISE NOTICE 'Block 0 pre-flight: zero duplicates. Safe to add UNIQUE constraint.';
END $$;

-- ---------------------------------------------------------------------
-- Block 1. Project backfill — priority-ordered rules, source-as-prior.
-- ---------------------------------------------------------------------

-- 1.1 OPEN-BRAIN — system meta. Wins over content match because
--     "[TMC-01 / Backfill checkpoint]" prefix would otherwise cause TMC-01.
UPDATE thoughts SET project = 'OPEN-BRAIN'
WHERE  project IS NULL AND source IN ('system-log', 'system-setup');

-- 1.2 SALTWORKS-OS — Saltworks-internal AI/OS strategy.
UPDATE thoughts SET project = 'SALTWORKS-OS'
WHERE  project IS NULL AND (
       source = 'strategy-fragment'
    OR content ~* 'Saltworks OS 2027'
    OR content ~* 'AI Stack Rank'
    OR content ~* 'AI Leadership Team'
);

-- 1.3 GM-01 document chunks — specific source class wins for these.
UPDATE thoughts SET project = 'GM-01'
WHERE  project IS NULL
  AND  source = 'document-chunk'
  AND  content ~ '^GM-01';

-- 1.4 TMC-01 — content or topic mention of any project alias.
UPDATE thoughts SET project = 'TMC-01'
WHERE  project IS NULL AND (
       content ~ 'TMC-01'
    OR content ~ 'TSMC'
    OR content ~ 'IRWP'
    OR (metadata->'topics') ?| array['TMC-01','TSMC','IRWP']
);

-- 1.5 GM-01 catch-all — any remaining GM-01 mentions outside TMC-01 context.
UPDATE thoughts SET project = 'GM-01'
WHERE  project IS NULL AND content ~ 'GM-01';

-- 1.6 Default — leftovers go to MISC per user choice.
UPDATE thoughts SET project = 'MISC' WHERE project IS NULL;

DO $$ BEGIN RAISE NOTICE 'Block 1 (project backfill) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block 2. Replace non-unique source_id index with UNIQUE constraint.
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS idx_thoughts_source_id_lookup;

CREATE UNIQUE INDEX idx_thoughts_src_id_unique
    ON thoughts (source, source_id)
    WHERE source_id IS NOT NULL;

DO $$ BEGIN RAISE NOTICE 'Block 2 (UNIQUE source_id index) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total       INTEGER;
    proj_null   INTEGER;
    proj_tmc    INTEGER;
    proj_gm     INTEGER;
    proj_ob     INTEGER;
    proj_sos    INTEGER;
    proj_misc   INTEGER;
    has_unique  BOOLEAN;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;
    SELECT COUNT(*) INTO proj_null FROM thoughts WHERE project IS NULL;
    SELECT COUNT(*) INTO proj_tmc  FROM thoughts WHERE project = 'TMC-01';
    SELECT COUNT(*) INTO proj_gm   FROM thoughts WHERE project = 'GM-01';
    SELECT COUNT(*) INTO proj_ob   FROM thoughts WHERE project = 'OPEN-BRAIN';
    SELECT COUNT(*) INTO proj_sos  FROM thoughts WHERE project = 'SALTWORKS-OS';
    SELECT COUNT(*) INTO proj_misc FROM thoughts WHERE project = 'MISC';

    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public' AND indexname = 'idx_thoughts_src_id_unique'
    ) INTO has_unique;

    RAISE NOTICE '======== POST-PASS-3 VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                  %', total;
    RAISE NOTICE 'project IS NULL (must be 0):     %', proj_null;
    RAISE NOTICE 'project = TMC-01:                % (audit predicted ~336)', proj_tmc;
    RAISE NOTICE 'project = GM-01:                 % (audit predicted ~12)', proj_gm;
    RAISE NOTICE 'project = OPEN-BRAIN:            % (audit predicted ~35)', proj_ob;
    RAISE NOTICE 'project = SALTWORKS-OS:          % (audit predicted ~27)', proj_sos;
    RAISE NOTICE 'project = MISC:                  %', proj_misc;
    RAISE NOTICE 'UNIQUE idx_thoughts_src_id present: %', has_unique;
    RAISE NOTICE '==========================================';

    IF proj_null > 0 THEN
        RAISE EXCEPTION 'Invariant: % rows have NULL project', proj_null;
    END IF;
    IF proj_tmc < 320 THEN
        RAISE EXCEPTION 'Invariant: TMC-01 count %, expected ~336', proj_tmc;
    END IF;
    IF NOT has_unique THEN
        RAISE EXCEPTION 'Invariant: UNIQUE index idx_thoughts_src_id_unique not found';
    END IF;
END $$;

COMMIT;
