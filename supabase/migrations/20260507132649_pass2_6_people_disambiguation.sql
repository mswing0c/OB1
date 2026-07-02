-- =====================================================================
-- Open Brain — Pass 2.6 — Bare-first-name disambiguation
-- =====================================================================
-- Purpose:    Apply user-confirmed canonical name resolutions for the
--             bare first names that Pass 1 deliberately LEFT-AS-IS due
--             to ambiguity. Form: ambiguous_names_form.md (filled 2026-05-07).
-- Resolutions (per user form):
--   Andrew -> Andrew Frankwitz (Wigen)
--   Josh   -> Joshua Zoshi (Saltworks COO + IT Tech leader; user
--                           confirmed both roles same person)
--   David  -> David Reyes (Sundt) [conditional - see Block 3/4]
--   Mike   -> LEAVE-BARE (multiple Mikes, kept ambiguous)
--   Matt   -> LEAVE-BARE (multiple Matts, Sundt-priority noted but no
--                         per-thought rule provided)
--   Ryan   -> LEAVE-BARE (Collins vs Nordquist, kept ambiguous)
-- After:     people_ambiguous flag is recomputed - thoughts that ONLY
--            had Andrew/Josh/David as their ambiguous names are unflagged.
-- Risk:      LOW - additive UPDATE on metadata.people; idempotent guards.
-- Reversible: metadata_pre_pass1_original snapshot (from Pass 1 corrective)
--            preserves the canonical pre-Pass1 state. To undo just this pass,
--            re-run Pass 1 corrective which restores from snapshot.
-- LLM cost:  $0
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Block 1. Andrew -> Andrew Frankwitz
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{people}',
           COALESCE(
               (SELECT jsonb_agg(DISTINCT
                   CASE WHEN value::text = '"Andrew"' THEN '"Andrew Frankwitz"'::jsonb ELSE value END
                ) FROM jsonb_array_elements(metadata->'people')),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'people'
  AND  jsonb_typeof(metadata->'people') = 'array'
  AND  jsonb_array_length(metadata->'people') > 0
  AND  metadata->'people' @> '["Andrew"]'::jsonb;

DO $$
DECLARE n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts WHERE metadata->'people' @> '["Andrew Frankwitz"]'::jsonb;
    RAISE NOTICE 'Block 1 (Andrew -> Andrew Frankwitz) complete. % thoughts now tag Andrew Frankwitz.', n;
END $$;

-- ---------------------------------------------------------------------
-- Block 2. Josh -> Joshua Zoshi
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{people}',
           COALESCE(
               (SELECT jsonb_agg(DISTINCT
                   CASE WHEN value::text = '"Josh"' THEN '"Joshua Zoshi"'::jsonb ELSE value END
                ) FROM jsonb_array_elements(metadata->'people')),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'people'
  AND  jsonb_typeof(metadata->'people') = 'array'
  AND  jsonb_array_length(metadata->'people') > 0
  AND  metadata->'people' @> '["Josh"]'::jsonb;

DO $$
DECLARE n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts WHERE metadata->'people' @> '["Joshua Zoshi"]'::jsonb;
    RAISE NOTICE 'Block 2 (Josh -> Joshua Zoshi) complete. % thoughts now tag Joshua Zoshi.', n;
END $$;

-- ---------------------------------------------------------------------
-- Block 3. David -> David Reyes (only if no other David <LastName> present)
--          Handles thoughts where bare "David" appears alone in metadata.people.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{people}',
           COALESCE(
               (SELECT jsonb_agg(DISTINCT
                   CASE WHEN value::text = '"David"' THEN '"David Reyes"'::jsonb ELSE value END
                ) FROM jsonb_array_elements(metadata->'people')),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'people'
  AND  jsonb_typeof(metadata->'people') = 'array'
  AND  jsonb_array_length(metadata->'people') > 0
  AND  metadata->'people' @> '["David"]'::jsonb
  AND  NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(metadata->'people') AS p(value)
           WHERE p.value::text ~ '^"David [A-Z]'   -- matches "David Walsh", "David Reyes" already present, etc.
       );

DO $$
DECLARE n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts WHERE metadata->'people' @> '["David Reyes"]'::jsonb;
    RAISE NOTICE 'Block 3 (David -> David Reyes) complete. % thoughts now tag David Reyes.', n;
END $$;

-- ---------------------------------------------------------------------
-- Block 4. Drop bare "David" from thoughts that ALSO have a David <LastName>
--          (e.g. David Walsh) - bare entry was redundant with the full name.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{people}',
           COALESCE(
               (SELECT jsonb_agg(DISTINCT v.value)
                FROM jsonb_array_elements(metadata->'people') AS v(value)
                WHERE v.value::text != '"David"'),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'people'
  AND  jsonb_typeof(metadata->'people') = 'array'
  AND  metadata->'people' @> '["David"]'::jsonb
  AND  EXISTS (
           SELECT 1 FROM jsonb_array_elements(metadata->'people') AS p(value)
           WHERE p.value::text ~ '^"David [A-Z]'
       );

DO $$
DECLARE n INTEGER;
BEGIN
    SELECT COUNT(*) INTO n FROM thoughts WHERE metadata->'people' @> '["David"]'::jsonb;
    RAISE NOTICE 'Block 4 (drop bare David in mixed-context thoughts) complete. % bare David rows remain (should be 0).', n;
END $$;

-- ---------------------------------------------------------------------
-- Block 5. Recompute people_ambiguous flag.
--          A thought stays flagged only if it still contains a bare name
--          we agreed to LEAVE-BARE: Mike, Matt, Ryan.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(metadata, '{people_ambiguous}', 'false'::jsonb)
WHERE  (metadata->>'people_ambiguous')::boolean IS TRUE
  AND  NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(metadata->'people') AS p(value)
           WHERE p.value::text IN ('"Mike"', '"Matt"', '"Ryan"')
       );

DO $$ BEGIN RAISE NOTICE 'Block 5 (recompute people_ambiguous) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total                INTEGER;
    andrew_bare          INTEGER;
    andrew_canonical     INTEGER;
    josh_bare            INTEGER;
    josh_canonical       INTEGER;
    david_bare           INTEGER;
    david_canonical      INTEGER;
    david_walsh          INTEGER;
    mike_bare            INTEGER;
    matt_bare            INTEGER;
    ryan_bare            INTEGER;
    ambiguous_remaining  INTEGER;
    ambiguous_resolved   INTEGER;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;

    SELECT COUNT(*) INTO andrew_bare      FROM thoughts WHERE metadata->'people' @> '["Andrew"]'::jsonb;
    SELECT COUNT(*) INTO andrew_canonical FROM thoughts WHERE metadata->'people' @> '["Andrew Frankwitz"]'::jsonb;

    SELECT COUNT(*) INTO josh_bare        FROM thoughts WHERE metadata->'people' @> '["Josh"]'::jsonb;
    SELECT COUNT(*) INTO josh_canonical   FROM thoughts WHERE metadata->'people' @> '["Joshua Zoshi"]'::jsonb;

    SELECT COUNT(*) INTO david_bare       FROM thoughts WHERE metadata->'people' @> '["David"]'::jsonb;
    SELECT COUNT(*) INTO david_canonical  FROM thoughts WHERE metadata->'people' @> '["David Reyes"]'::jsonb;
    SELECT COUNT(*) INTO david_walsh      FROM thoughts WHERE metadata->'people' @> '["David Walsh"]'::jsonb;

    SELECT COUNT(*) INTO mike_bare        FROM thoughts WHERE metadata->'people' @> '["Mike"]'::jsonb;
    SELECT COUNT(*) INTO matt_bare        FROM thoughts WHERE metadata->'people' @> '["Matt"]'::jsonb;
    SELECT COUNT(*) INTO ryan_bare        FROM thoughts WHERE metadata->'people' @> '["Ryan"]'::jsonb;

    SELECT COUNT(*) INTO ambiguous_remaining FROM thoughts WHERE (metadata->>'people_ambiguous')::boolean IS TRUE;
    SELECT COUNT(*) INTO ambiguous_resolved  FROM thoughts WHERE (metadata->>'people_ambiguous')::boolean IS FALSE;

    RAISE NOTICE '======== POST-PASS-2.6 VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                          %', total;
    RAISE NOTICE '--- Resolved canonicals ---';
    RAISE NOTICE '  Bare "Andrew" remaining (must be 0):     %', andrew_bare;
    RAISE NOTICE '  "Andrew Frankwitz":                      %', andrew_canonical;
    RAISE NOTICE '  Bare "Josh" remaining (must be 0):       %', josh_bare;
    RAISE NOTICE '  "Joshua Zoshi":                          %', josh_canonical;
    RAISE NOTICE '  Bare "David" remaining (must be 0):      %', david_bare;
    RAISE NOTICE '  "David Reyes":                           %', david_canonical;
    RAISE NOTICE '  "David Walsh" preserved:                 %', david_walsh;
    RAISE NOTICE '--- LEAVE-BARE (still ambiguous): ---';
    RAISE NOTICE '  Bare "Mike":                             %', mike_bare;
    RAISE NOTICE '  Bare "Matt":                             %', matt_bare;
    RAISE NOTICE '  Bare "Ryan":                             %', ryan_bare;
    RAISE NOTICE '--- Ambiguous flag ---';
    RAISE NOTICE '  Thoughts still flagged ambiguous:        %', ambiguous_remaining;
    RAISE NOTICE '  Thoughts cleared (resolved):             %', ambiguous_resolved;
    RAISE NOTICE '==============================================';

    -- Hard invariants
    IF andrew_bare > 0 THEN RAISE EXCEPTION 'Bare Andrew still present: %', andrew_bare; END IF;
    IF josh_bare   > 0 THEN RAISE EXCEPTION 'Bare Josh still present: %', josh_bare; END IF;
    IF david_bare  > 0 THEN RAISE EXCEPTION 'Bare David still present: %', david_bare; END IF;
    -- Note: Mike/Matt/Ryan deliberately stay bare (LEAVE-BARE policy)
END $$;

COMMIT;
