-- =====================================================================
-- Open Brain — Pass 1 Corrective Migration
-- =====================================================================
-- Purpose:    Fix two bugs in 20260505232432_pass1_tag_normalization.sql:
--               1. `to_jsonb(LOWER(value::text))` re-wrapped an already-quoted
--                  JSON string, producing values with embedded literal quote
--                  characters (e.g. stored as `"project management"` instead
--                  of the JSON string `project management`). Cascade failure:
--                  Block C's CASE-WHEN-IN comparisons could not match the
--                  corrupted form, so no alias merges fired.
--               2. For rows where `metadata->'topics'` was an empty array `[]`,
--                  `jsonb_array_elements(...)` returned no rows, so
--                  `jsonb_agg(...)` returned SQL NULL, so
--                  `jsonb_set(metadata, '{topics}', NULL)` returned SQL NULL,
--                  so `SET metadata = NULL` wiped the entire metadata —
--                  including type, people, action_items, dates_mentioned.
--                  91 thoughts lost their type field.
-- Strategy:   Roll forward, not back. The snapshot column populated by the
--             previous migration preserves every row's original metadata.
--             Step 1: revert metadata from snapshot for ALL rows.
--             Step 2: re-run Blocks B / C / F / G with the bug fixes.
--             Step 3: re-populate the snapshot to reflect the corrected state.
-- Reversible: YES — `metadata_pre_pass1` snapshot column is preserved and
--             repopulated to match the new corrected `metadata`. To roll back
--             to the original-original state (pre-Pass 1), run
--             `UPDATE thoughts SET metadata = metadata_pre_pass1_original;`
--             after the snapshot-of-the-snapshot column is added below.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Block 0. Preserve the ORIGINAL pre-Pass1 snapshot under a new column
--          so we don't lose it when we overwrite metadata_pre_pass1.
-- ---------------------------------------------------------------------
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS metadata_pre_pass1_original JSONB;

UPDATE thoughts
SET    metadata_pre_pass1_original = metadata_pre_pass1
WHERE  metadata_pre_pass1_original IS NULL
  AND  metadata_pre_pass1 IS NOT NULL;

DO $$
DECLARE
    backup_count INTEGER;
    total INTEGER;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;
    SELECT COUNT(*) INTO backup_count FROM thoughts WHERE metadata_pre_pass1_original IS NOT NULL;
    IF backup_count <> total THEN
        RAISE EXCEPTION 'Block 0 failed: only %/% rows have original snapshot. Aborting.', backup_count, total;
    END IF;
    RAISE NOTICE 'Block 0 complete. Original pre-Pass1 snapshot preserved for all % rows.', total;
END $$;

-- ---------------------------------------------------------------------
-- Block 1. Revert metadata from the original snapshot.
--          After this, the live `metadata` column equals exactly what it
--          was before the original buggy migration ran.
-- ---------------------------------------------------------------------
UPDATE thoughts SET metadata = metadata_pre_pass1_original;

DO $$ BEGIN RAISE NOTICE 'Block 1 complete. Metadata reverted from original snapshot.'; END $$;

-- ---------------------------------------------------------------------
-- Block B (FIXED). Topic case-fold preserving acronyms.
-- Fix 1: LOWER(value::text)::jsonb — keep the JSON string round-trip
--        (no double-quoting).
-- Fix 2: COALESCE(jsonb_agg(...), '[]'::jsonb) — empty topic arrays
--        no longer produce NULL.
-- Fix 3: WHERE clause now also requires the array to be non-empty,
--        so we don't even hit the COALESCE in the empty case.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{topics}',
           COALESCE(
               (
                   SELECT jsonb_agg(
                       CASE
                           -- Project codenames
                           WHEN value::text IN ('"TMC-01"','"GM-01"','"APM"','"PIXY"','"Aurora"','"OB1"','"OPEN-BRAIN"','"SALTWORKS-OS"') THEN value
                           -- Org / contract codes (Saltworks added per user choice)
                           WHEN value::text IN ('"TSMC"','"IRWP"','"IRWP-A"','"IRWP-B"','"AFL"','"BSS"','"BPI"','"Saltworks"') THEN value
                           -- Process abbreviations
                           WHEN value::text IN ('"MVR"','"RO"','"IX"','"MBR"','"RCW"','"SCR"','"SLD"','"ZLD"','"BOM"','"BMR"','"HEX"','"DPT"','"RTD"','"VFD"','"PSV"','"NPSH"','"MTZ"','"OLI"') THEN value
                           -- Software / standards
                           WHEN value::text IN ('"P&ID"','"PFD"','"PFID"','"GAD"','"FAT"','"SAT"','"ITP"','"PCP"','"ECO"','"ECI"','"NTP"','"NEMA"','"SPD"','"SCCR"','"GIS"','"HVAC"','"SCADA"','"HMI"','"PLC"','"BIM"','"CAD"','"AWG"','"PE"','"EVP"','"DXT"','"MCP"','"SDR"','"ASTM"','"ISA101"','"ISA18"','"USMCA"') THEN value
                           -- Email / Teams / SharePoint / Wrike
                           WHEN value::text IN ('"SharePoint"','"Wrike"','"Bluebeam"','"Granola"','"Notion"','"Outlook"','"Teams"') THEN value
                           -- AI tools
                           WHEN value::text IN ('"Claude"','"AI"','"Grafana"','"OpenAI"','"Codex"','"Anthropic"') THEN value
                           -- Chemistry tokens
                           WHEN value::text IN ('"NaCl"','"NaOH"','"HCl"','"LiOH"','"Li2CO3"','"OSHA"','"K1"','"K2"') THEN value
                           -- Anything else: lowercase via JSON round-trip (NO double-quoting)
                           ELSE LOWER(value::text)::jsonb
                       END
                   )
                   FROM jsonb_array_elements(metadata->'topics')
               ),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'topics'
  AND  jsonb_typeof(metadata->'topics') = 'array'
  AND  jsonb_array_length(metadata->'topics') > 0;

DO $$ BEGIN RAISE NOTICE 'Block B (FIXED case-fold) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block C (unchanged from original). Conservative alias merges.
-- After fixed Block B, lowercase-with-spaces values now have the
-- correct JSON string format, so these IN matches can fire.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{topics}',
           COALESCE(
               (
                   SELECT jsonb_agg(DISTINCT
                       CASE
                           WHEN value::text IN ('"project management"','"project mgmt"','"pmo"','"pmo work"')                 THEN '"project_management"'::jsonb
                           WHEN value::text IN ('"action items"','"action_items"')                                            THEN '"action_items"'::jsonb
                           WHEN value::text IN ('"meeting"','"meetings"','"meeting notes"','"meeting summary"')               THEN '"meeting_notes"'::jsonb
                           WHEN value::text IN ('"project status"')                                                           THEN '"project_status"'::jsonb
                           WHEN value::text IN ('"project updates"','"project_update"')                                       THEN '"project_updates"'::jsonb
                           WHEN value::text IN ('"project coordination"')                                                     THEN '"project_coordination"'::jsonb
                           WHEN value::text IN ('"vendor coordination"','"vendor management"','"vendor updates"')             THEN '"vendor_coordination"'::jsonb
                           WHEN value::text IN ('"design review"')                                                            THEN '"design_review"'::jsonb
                           WHEN value::text IN ('"thermal work group"')                                                       THEN '"thermal_work_group"'::jsonb
                           WHEN value::text IN ('"mass balance"','"water balance"','"mass balance review"')                   THEN '"mass_balance"'::jsonb
                           WHEN value::text IN ('"risk management"')                                                          THEN '"risk_management"'::jsonb
                           WHEN value::text IN ('"safety"','"safety compliance"','"osha compliance"')                         THEN '"safety"'::jsonb
                           WHEN value::text IN ('"contract review"')                                                          THEN '"contract_review"'::jsonb
                           WHEN value::text IN ('"contract terms"')                                                           THEN '"contract_terms"'::jsonb
                           WHEN value::text IN ('"contract management"')                                                      THEN '"contract_management"'::jsonb
                           WHEN value::text IN ('"contract negotiation"')                                                     THEN '"contract_negotiation"'::jsonb
                           WHEN value::text IN ('"engineering coordination"')                                                 THEN '"engineering_coordination"'::jsonb
                           WHEN value::text IN ('"engineering deliverables"')                                                 THEN '"engineering_deliverables"'::jsonb
                           WHEN value::text IN ('"engineering management"')                                                   THEN '"engineering_management"'::jsonb
                           WHEN value::text IN ('"water chemistry"')                                                          THEN '"water_chemistry"'::jsonb
                           WHEN value::text IN ('"water treatment"')                                                          THEN '"water_treatment"'::jsonb
                           WHEN value::text IN ('"electrical design"','"electrical engineering"')                             THEN '"electrical_design"'::jsonb
                           WHEN value::text IN ('"system design"')                                                            THEN '"system_design"'::jsonb
                           WHEN value::text IN ('"tank design"')                                                              THEN '"tank_design"'::jsonb
                           WHEN value::text IN ('"thermal design"')                                                           THEN '"thermal_design"'::jsonb
                           WHEN value::text IN ('"p&id review"','"p&id"')                                                     THEN '"pid_review"'::jsonb
                           ELSE value
                       END
                   )
                   FROM jsonb_array_elements(metadata->'topics')
               ),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'topics'
  AND  jsonb_typeof(metadata->'topics') = 'array'
  AND  jsonb_array_length(metadata->'topics') > 0;

DO $$ BEGIN RAISE NOTICE 'Block C (alias merges) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block F (FIXED with COALESCE + non-empty guard). People alias merge.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{people}',
           COALESCE(
               (
                   SELECT jsonb_agg(DISTINCT
                       CASE
                           WHEN value::text = '"Justin"'           THEN '"Justin Lee"'::jsonb
                           WHEN value::text = '"JL"'               THEN '"Justin Lee"'::jsonb
                           WHEN value::text = '"J.J. Burdick"'     THEN '"Jared Burdick"'::jsonb
                           WHEN value::text = '"JJ"'               THEN '"Jared Burdick"'::jsonb
                           WHEN value::text = '"Jared"'            THEN '"Jared Burdick"'::jsonb  -- unambiguous in corpus
                           WHEN value::text = '"Mitch"'            THEN '"Mitch Rockey"'::jsonb
                           WHEN value::text = '"Dylan"'            THEN '"Dylan Uecker"'::jsonb
                           WHEN value::text = '"John"'             THEN '"John Fourie"'::jsonb
                           WHEN value::text = '"Ben"'              THEN '"Ben Sparrow"'::jsonb
                           WHEN value::text = '"Mark"'             THEN '"Mark Burnett"'::jsonb
                           WHEN value::text = '"Bryce"'            THEN '"Bryce Williamson"'::jsonb
                           WHEN value::text = '"Brian"'            THEN '"Brian Noh"'::jsonb
                           WHEN value::text = '"Maulin"'           THEN '"Maulin Trivedi"'::jsonb
                           WHEN value::text = '"Nader"'            THEN '"Nader Shakerin"'::jsonb
                           WHEN value::text = '"Ross"'             THEN '"Ross Coleman"'::jsonb
                           WHEN value::text = '"Jordan"'           THEN '"Jordan Stahn"'::jsonb
                           WHEN value::text = '"Cindy"'            THEN '"Cindy Pries"'::jsonb
                           WHEN value::text = '"Luke"'             THEN '"Luke Wilson"'::jsonb
                           ELSE value
                       END
                   )
                   FROM jsonb_array_elements(metadata->'people')
               ),
               '[]'::jsonb
           )
       )
WHERE  metadata ? 'people'
  AND  jsonb_typeof(metadata->'people') = 'array'
  AND  jsonb_array_length(metadata->'people') > 0;

DO $$ BEGIN RAISE NOTICE 'Block F (people alias merge) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block G. Flag ambiguous bare-first-names.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(metadata, '{people_ambiguous}', 'true'::jsonb)
WHERE  metadata ? 'people'
  AND  jsonb_typeof(metadata->'people') = 'array'
  AND  EXISTS (
           SELECT 1 FROM jsonb_array_elements(metadata->'people') v
           WHERE v::text IN ('"Ryan"','"Matt"','"Josh"','"Andrew"','"Mike"','"David"')
       );

DO $$ BEGIN RAISE NOTICE 'Block G (ambiguous-people flag) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block H. Repopulate metadata_pre_pass1 to reflect the now-corrected state.
--          The original-original lives on in metadata_pre_pass1_original.
-- ---------------------------------------------------------------------
UPDATE thoughts SET metadata_pre_pass1 = metadata;

DO $$ BEGIN RAISE NOTICE 'Block H (snapshot refreshed) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Verification block — STRONGER invariants this time
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total                INTEGER;
    snap_total           INTEGER;
    orig_snap_total      INTEGER;
    distinct_topics      INTEGER;
    untyped              INTEGER;
    typed_total          INTEGER;
    justin_lee_cnt       INTEGER;
    pm_canonical         INTEGER;
    ambiguous_cnt        INTEGER;
    bad_quote_topics     INTEGER;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;
    SELECT COUNT(*) INTO snap_total FROM thoughts WHERE metadata_pre_pass1 IS NOT NULL;
    SELECT COUNT(*) INTO orig_snap_total FROM thoughts WHERE metadata_pre_pass1_original IS NOT NULL;

    SELECT COUNT(DISTINCT t.value)
    INTO   distinct_topics
    FROM   thoughts, jsonb_array_elements_text(metadata->'topics') AS t(value);

    SELECT COUNT(*) INTO untyped FROM thoughts WHERE NOT (metadata ? 'type') OR metadata->>'type' IS NULL;
    SELECT COUNT(*) INTO typed_total FROM thoughts WHERE metadata->>'type' IS NOT NULL;

    SELECT COUNT(*) INTO justin_lee_cnt FROM thoughts WHERE metadata->'people' @> '["Justin Lee"]'::jsonb;
    SELECT COUNT(*) INTO pm_canonical   FROM thoughts WHERE metadata->'topics' @> '["project_management"]'::jsonb;
    SELECT COUNT(*) INTO ambiguous_cnt  FROM thoughts WHERE (metadata->>'people_ambiguous')::boolean IS TRUE;

    -- Detect any topic value that contains a literal quote character (would
    -- indicate the format-corruption bug returned).
    SELECT COUNT(*)
    INTO   bad_quote_topics
    FROM   thoughts, jsonb_array_elements_text(metadata->'topics') AS t(value)
    WHERE  t.value LIKE '"%"';

    RAISE NOTICE '======== POST-CORRECTIVE VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                            %', total;
    RAISE NOTICE 'Rows with refreshed snapshot:              %', snap_total;
    RAISE NOTICE 'Rows with original-pre-Pass1 snapshot:     %', orig_snap_total;
    RAISE NOTICE 'Distinct topic values:                     %', distinct_topics;
    RAISE NOTICE 'Total typed thoughts (was 423):            %', typed_total;
    RAISE NOTICE 'Untyped thoughts (was 38, max should be 38+~3 new): %', untyped;
    RAISE NOTICE 'Thoughts tagging "Justin Lee" (was 217):   %', justin_lee_cnt;
    RAISE NOTICE 'Thoughts tagging "project_management":     %', pm_canonical;
    RAISE NOTICE 'Thoughts flagged people_ambiguous:         %', ambiguous_cnt;
    RAISE NOTICE 'Topics with literal embedded quotes (bug): %', bad_quote_topics;
    RAISE NOTICE '==============================================';

    -- Hard invariants
    IF snap_total <> total THEN
        RAISE EXCEPTION 'Invariant violated: refreshed snapshot count (%) != total (%)', snap_total, total;
    END IF;
    IF orig_snap_total <> total THEN
        RAISE EXCEPTION 'Invariant violated: original snapshot count (%) != total (%)', orig_snap_total, total;
    END IF;
    IF justin_lee_cnt < 217 THEN
        RAISE EXCEPTION 'Invariant violated: "Justin Lee" count (%) below floor (217)', justin_lee_cnt;
    END IF;
    IF pm_canonical < 50 THEN
        RAISE EXCEPTION 'Invariant violated: project_management count (%) below floor (50). Block C may have failed.', pm_canonical;
    END IF;
    IF typed_total < 420 THEN
        RAISE EXCEPTION 'Invariant violated: typed_total (%) is below floor (420). Block 1 revert may have failed; metadata.type was lost.', typed_total;
    END IF;
    IF bad_quote_topics > 0 THEN
        RAISE EXCEPTION 'Invariant violated: % topics still contain literal quotes. Block B fix did not work.', bad_quote_topics;
    END IF;
END $$;

COMMIT;
