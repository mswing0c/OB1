-- =====================================================================
-- Open Brain — Pass 5 — Document parent linking
-- =====================================================================
-- Purpose:    Link multi-chunk pasted documents under a canonical parent
--             thought so vector-search hits can be reconstructed into the
--             full document.
-- Documents:  (1) IX Test Work Report Rev 1 — 4 chunks, parent is the
--                 chunk containing "Executive summary" (the canonical
--                 issue/transmission summary).
--             (2) GM-01 MVR Power Loss — 12 chunks, parent is the chunk
--                 starting with "GM-01 Power Loss reference" (the master
--                 index pointing to all subsystem chunks).
--             The freeform "GM-01 project: synthetic water chemistry"
--             thought is intentionally LEFT STANDALONE (it doesn't
--             contain "Power Loss" so the regex naturally excludes it).
-- Risk:       LOW — additive UPDATE on parent_thought_id column. Pre-flight
--             asserts exactly 1 parent for each document; if not, abort.
-- Reversible: YES — UPDATE thoughts SET parent_thought_id = NULL
--             WHERE source = 'document-chunk';
-- LLM cost:   $0
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Pre-flight: confirm expected counts and exactly one parent per document.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    ix_chunks  INTEGER;
    ix_parents INTEGER;
    gm_chunks  INTEGER;
    gm_parents INTEGER;
    gm_freeform INTEGER;
BEGIN
    SELECT COUNT(*) INTO ix_chunks
    FROM   thoughts
    WHERE  source = 'document-chunk' AND content ~ '^TMC-01 IX Test Work Report Rev';

    SELECT COUNT(*) INTO ix_parents
    FROM   thoughts
    WHERE  source = 'document-chunk'
      AND  content ~ '^TMC-01 IX Test Work Report Rev'
      AND  content ~ 'Executive summary';

    SELECT COUNT(*) INTO gm_chunks
    FROM   thoughts
    WHERE  source = 'document-chunk' AND content ~ '^GM-01' AND content ~ 'Power Loss';

    SELECT COUNT(*) INTO gm_parents
    FROM   thoughts
    WHERE  source = 'document-chunk' AND content ~ '^GM-01 Power Loss reference';

    SELECT COUNT(*) INTO gm_freeform
    FROM   thoughts
    WHERE  source = 'document-chunk' AND content ~ '^GM-01 project: synthetic';

    RAISE NOTICE 'Pre-flight: IX chunks=%, IX parents=%, GM Power Loss chunks=%, GM parents=%, GM freeform standalone=%',
        ix_chunks, ix_parents, gm_chunks, gm_parents, gm_freeform;

    IF ix_parents <> 1 THEN
        RAISE EXCEPTION 'Pre-flight: expected exactly 1 IX parent (Executive summary), found %', ix_parents;
    END IF;
    IF gm_parents <> 1 THEN
        RAISE EXCEPTION 'Pre-flight: expected exactly 1 GM-01 parent (Power Loss reference), found %', gm_parents;
    END IF;
    IF ix_chunks < 4 THEN
        RAISE EXCEPTION 'Pre-flight: expected at least 4 IX chunks, found %', ix_chunks;
    END IF;
    IF gm_chunks < 11 THEN
        RAISE EXCEPTION 'Pre-flight: expected at least 11 GM Power Loss chunks, found %', gm_chunks;
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Block 1. Link IX Test Work Report Rev 1 children to Executive Summary parent.
-- ---------------------------------------------------------------------
WITH ix_parent AS (
    SELECT id
    FROM   thoughts
    WHERE  source = 'document-chunk'
      AND  content ~ '^TMC-01 IX Test Work Report Rev'
      AND  content ~ 'Executive summary'
    LIMIT  1
)
UPDATE thoughts
SET    parent_thought_id = (SELECT id FROM ix_parent)
WHERE  source = 'document-chunk'
  AND  content ~ '^TMC-01 IX Test Work Report Rev'
  AND  content !~ 'Executive summary'
  AND  parent_thought_id IS NULL;     -- idempotent guard

DO $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts
    WHERE source = 'document-chunk'
      AND content ~ '^TMC-01 IX Test Work Report Rev'
      AND parent_thought_id IS NOT NULL;
    RAISE NOTICE 'Block 1 complete. % IX children linked to Executive Summary parent.', n;
END $$;

-- ---------------------------------------------------------------------
-- Block 2. Link GM-01 Power Loss children to Power Loss reference parent.
--          The "Power Loss" filter excludes the standalone freeform
--          synthetic-water-chemistry thought.
-- ---------------------------------------------------------------------
WITH gm_parent AS (
    SELECT id
    FROM   thoughts
    WHERE  source = 'document-chunk'
      AND  content ~ '^GM-01 Power Loss reference'
    LIMIT  1
)
UPDATE thoughts
SET    parent_thought_id = (SELECT id FROM gm_parent)
WHERE  source = 'document-chunk'
  AND  content ~ '^GM-01'
  AND  content ~ 'Power Loss'
  AND  content !~ '^GM-01 Power Loss reference'   -- exclude the parent itself
  AND  parent_thought_id IS NULL;                  -- idempotent guard

DO $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts
    WHERE source = 'document-chunk'
      AND content ~ '^GM-01'
      AND content ~ 'Power Loss'
      AND parent_thought_id IS NOT NULL;
    RAISE NOTICE 'Block 2 complete. % GM-01 Power Loss children linked to master parent.', n;
END $$;

-- ---------------------------------------------------------------------
-- Verification — strong invariants
-- ---------------------------------------------------------------------
DO $$
DECLARE
    ix_total              INTEGER;
    ix_with_parent        INTEGER;
    ix_root_count         INTEGER;
    gm_pl_total           INTEGER;
    gm_pl_with_parent     INTEGER;
    gm_pl_root_count      INTEGER;
    gm_freeform_orphaned  INTEGER;
    same_parent_id        UUID;
BEGIN
    -- IX Report invariants
    SELECT COUNT(*) INTO ix_total
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^TMC-01 IX Test Work Report Rev';

    SELECT COUNT(*) INTO ix_with_parent
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^TMC-01 IX Test Work Report Rev'
                    AND parent_thought_id IS NOT NULL;

    SELECT COUNT(*) INTO ix_root_count
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^TMC-01 IX Test Work Report Rev'
                    AND parent_thought_id IS NULL;

    -- GM Power Loss invariants
    SELECT COUNT(*) INTO gm_pl_total
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^GM-01' AND content ~ 'Power Loss';

    SELECT COUNT(*) INTO gm_pl_with_parent
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^GM-01' AND content ~ 'Power Loss'
                    AND parent_thought_id IS NOT NULL;

    SELECT COUNT(*) INTO gm_pl_root_count
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^GM-01' AND content ~ 'Power Loss'
                    AND parent_thought_id IS NULL;

    -- GM freeform must remain standalone
    SELECT COUNT(*) INTO gm_freeform_orphaned
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^GM-01 project: synthetic'
                    AND parent_thought_id IS NULL;

    -- Verify all IX children point to the same parent
    SELECT DISTINCT parent_thought_id INTO same_parent_id
    FROM thoughts WHERE source = 'document-chunk' AND content ~ '^TMC-01 IX Test Work Report Rev'
                    AND parent_thought_id IS NOT NULL;
    -- (DISTINCT into a single var raises if more than one — Postgres feature)

    RAISE NOTICE '======== POST-PASS-5 VERIFICATION ========';
    RAISE NOTICE '--- IX Test Work Report Rev 1 ---';
    RAISE NOTICE '  Total chunks:                   %', ix_total;
    RAISE NOTICE '  Children linked to parent:      %', ix_with_parent;
    RAISE NOTICE '  Root (parent_thought_id IS NULL): % (must be 1)', ix_root_count;
    RAISE NOTICE '  Common parent_thought_id:       %', same_parent_id;
    RAISE NOTICE '--- GM-01 MVR Power Loss ---';
    RAISE NOTICE '  Total chunks:                   %', gm_pl_total;
    RAISE NOTICE '  Children linked to parent:      %', gm_pl_with_parent;
    RAISE NOTICE '  Root (parent_thought_id IS NULL): % (must be 1)', gm_pl_root_count;
    RAISE NOTICE '--- GM-01 freeform standalone ---';
    RAISE NOTICE '  Synthetic water chemistry orphaned (must be 1): %', gm_freeform_orphaned;
    RAISE NOTICE '==========================================';

    IF ix_root_count <> 1 THEN
        RAISE EXCEPTION 'IX Report should have exactly 1 root, has %', ix_root_count;
    END IF;
    IF ix_with_parent <> (ix_total - 1) THEN
        RAISE EXCEPTION 'IX children link mismatch: %/% (expected %)', ix_with_parent, ix_total, ix_total - 1;
    END IF;
    IF gm_pl_root_count <> 1 THEN
        RAISE EXCEPTION 'GM Power Loss should have exactly 1 root, has %', gm_pl_root_count;
    END IF;
    IF gm_pl_with_parent <> (gm_pl_total - 1) THEN
        RAISE EXCEPTION 'GM children link mismatch: %/% (expected %)', gm_pl_with_parent, gm_pl_total, gm_pl_total - 1;
    END IF;
    IF gm_freeform_orphaned <> 1 THEN
        RAISE EXCEPTION 'GM freeform standalone should remain orphaned, count=%', gm_freeform_orphaned;
    END IF;
END $$;

COMMIT;
