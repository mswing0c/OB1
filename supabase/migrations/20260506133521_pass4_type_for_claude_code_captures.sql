-- =====================================================================
-- Open Brain — Pass 4 — Type assignment for Claude Code captures
-- =====================================================================
-- Purpose:    Classify the ~49 untyped Claude Code IDE / subagent captures.
--             These rows have metadata.type missing because their
--             "[Claude Code: <ide_opened_file>...]" preamble derailed the
--             original LLM extractor at capture time.
-- Approach:   DETERMINISTIC regex on the first verb after the prefix.
--             Every Claude Code capture follows the pattern:
--             "[Claude Code: ...| YYYY-MM-DD] I <verb> ..."
--             The verb tells us the type:
--               decision    — I decided/chose/implemented/created/recommended/...
--               observation — I learned/discovered/noted/found/confirmed/...
--             This is reproducible, $0, and faster than 49 LLM round-trips.
--             v2 enum: introduces `decision` as a new type (audit recommended).
-- Risk:       LOW — only writes to metadata.type on rows where type IS NULL
--             AND source = claude-code-*. Idempotent.
-- Reversible: YES — UPDATE thoughts SET metadata = metadata - 'type'
--             WHERE source IN ('claude-code-ide','claude-code-subagent');
-- LLM cost:   $0 (deterministic SQL, no API calls)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Block 0. Pre-flight: count untyped Claude Code rows.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    untyped_cc INTEGER;
BEGIN
    SELECT COUNT(*) INTO untyped_cc
    FROM   thoughts
    WHERE  source IN ('claude-code-ide','claude-code-subagent')
      AND  (NOT (metadata ? 'type') OR metadata->>'type' IS NULL);
    RAISE NOTICE 'Block 0 pre-flight: % untyped Claude Code captures to classify.', untyped_cc;
END $$;

-- ---------------------------------------------------------------------
-- Block 1. Set type='decision' for action-verb captures.
--          Verbs: decided, chose, implemented, created, recommended,
--                 added, built, wrote, set up, structured, generated,
--                 made, introduced.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{type}', '"decision"'::jsonb)
WHERE  source IN ('claude-code-ide','claude-code-subagent')
  AND  (NOT (metadata ? 'type') OR metadata->>'type' IS NULL)
  AND  content ~ '\| \d{4}-\d{2}-\d{2}\]\s+I (decided|chose|implemented|created|recommended?|added|built|wrote|set up|structured|generated|made|introduced)\b';

DO $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts
    WHERE source IN ('claude-code-ide','claude-code-subagent')
      AND metadata->>'type' = 'decision';
    RAISE NOTICE 'Block 1 (decision verbs) complete. % rows now type=decision.', n;
END $$;

-- ---------------------------------------------------------------------
-- Block 2. Set type='observation' for the remaining Claude Code captures.
--          This catches the "I learned/discovered/noted/found/etc"
--          variants AND anything that didn't match Block 1's verb list.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{type}', '"observation"'::jsonb)
WHERE  source IN ('claude-code-ide','claude-code-subagent')
  AND  (NOT (metadata ? 'type') OR metadata->>'type' IS NULL);

DO $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts
    WHERE source IN ('claude-code-ide','claude-code-subagent')
      AND metadata->>'type' = 'observation';
    RAISE NOTICE 'Block 2 (observation default) complete. % rows now type=observation.', n;
END $$;

-- ---------------------------------------------------------------------
-- Verification — strong invariants
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total                  INTEGER;
    untyped_total          INTEGER;
    untyped_claude_code    INTEGER;
    type_decision          INTEGER;
    type_observation       INTEGER;
    type_task              INTEGER;
    type_reference         INTEGER;
    cc_decision            INTEGER;
    cc_observation         INTEGER;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;

    SELECT COUNT(*) INTO untyped_total FROM thoughts
    WHERE NOT (metadata ? 'type') OR metadata->>'type' IS NULL;

    SELECT COUNT(*) INTO untyped_claude_code FROM thoughts
    WHERE source IN ('claude-code-ide','claude-code-subagent')
      AND (NOT (metadata ? 'type') OR metadata->>'type' IS NULL);

    SELECT COUNT(*) INTO type_decision    FROM thoughts WHERE metadata->>'type' = 'decision';
    SELECT COUNT(*) INTO type_observation FROM thoughts WHERE metadata->>'type' = 'observation';
    SELECT COUNT(*) INTO type_task        FROM thoughts WHERE metadata->>'type' = 'task';
    SELECT COUNT(*) INTO type_reference   FROM thoughts WHERE metadata->>'type' = 'reference';

    SELECT COUNT(*) INTO cc_decision FROM thoughts
    WHERE source IN ('claude-code-ide','claude-code-subagent') AND metadata->>'type' = 'decision';

    SELECT COUNT(*) INTO cc_observation FROM thoughts
    WHERE source IN ('claude-code-ide','claude-code-subagent') AND metadata->>'type' = 'observation';

    RAISE NOTICE '======== POST-PASS-4 VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                       %', total;
    RAISE NOTICE 'Untyped (must be 0 if everything OK): %', untyped_total;
    RAISE NOTICE 'Untyped claude-code (must be 0):      %', untyped_claude_code;
    RAISE NOTICE '--- Type distribution (full corpus) ---';
    RAISE NOTICE '  task:                               %', type_task;
    RAISE NOTICE '  observation:                        %', type_observation;
    RAISE NOTICE '  reference:                          %', type_reference;
    RAISE NOTICE '  decision:                           % (NEW type, introduced this pass)', type_decision;
    RAISE NOTICE '--- Claude Code captures classified ---';
    RAISE NOTICE '  decision:                           %', cc_decision;
    RAISE NOTICE '  observation:                        %', cc_observation;
    RAISE NOTICE '==========================================';

    IF untyped_claude_code > 0 THEN
        RAISE EXCEPTION 'Invariant: % Claude Code rows still untyped', untyped_claude_code;
    END IF;
END $$;

COMMIT;
