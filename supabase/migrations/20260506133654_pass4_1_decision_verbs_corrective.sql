-- =====================================================================
-- Open Brain — Pass 4.1 — Decision-verb classification (corrective)
-- =====================================================================
-- Purpose:    Pass 4 used `\b` (Postgres = backspace, NOT word boundary),
--             so the action-verb pattern matched 0 rows and all 49 Claude
--             Code captures defaulted to type=observation. This pass uses
--             `\y` (Postgres word boundary) to upgrade the action-verb
--             rows to type=decision.
-- Risk:       LOW — only updates rows currently classified as observation
--             where source is claude-code-* and the action verb pattern
--             matches with the corrected regex.
-- Reversible: YES — UPDATE thoughts SET metadata = jsonb_set(metadata,
--             '{type}', '"observation"'::jsonb) WHERE source IN (...)
--             AND metadata->>'type' = 'decision';
-- =====================================================================

BEGIN;

UPDATE thoughts
SET    metadata = jsonb_set(metadata, '{type}', '"decision"'::jsonb)
WHERE  source IN ('claude-code-ide','claude-code-subagent')
  AND  metadata->>'type' = 'observation'
  AND  content ~ '\| \d{4}-\d{2}-\d{2}\]\s+I (decided|chose|implemented|created|recommended?|added|built|wrote|set up|structured|generated|made|introduced)\y';

-- Verification
DO $$
DECLARE
    cc_decision    INTEGER;
    cc_observation INTEGER;
    cc_total       INTEGER;
BEGIN
    SELECT COUNT(*) INTO cc_decision    FROM thoughts WHERE source IN ('claude-code-ide','claude-code-subagent') AND metadata->>'type' = 'decision';
    SELECT COUNT(*) INTO cc_observation FROM thoughts WHERE source IN ('claude-code-ide','claude-code-subagent') AND metadata->>'type' = 'observation';
    SELECT COUNT(*) INTO cc_total       FROM thoughts WHERE source IN ('claude-code-ide','claude-code-subagent');

    RAISE NOTICE '======== POST-PASS-4.1 VERIFICATION ========';
    RAISE NOTICE 'Claude Code total:                 %', cc_total;
    RAISE NOTICE '  classified as decision:          %', cc_decision;
    RAISE NOTICE '  classified as observation:       %', cc_observation;
    RAISE NOTICE '  classified sum (must equal total): %', cc_decision + cc_observation;
    RAISE NOTICE '=============================================';

    IF (cc_decision + cc_observation) <> cc_total THEN
        RAISE EXCEPTION 'Sum mismatch: decision+observation (%) <> total (%)', cc_decision + cc_observation, cc_total;
    END IF;
END $$;

COMMIT;
