-- =====================================================================
-- Open Brain — Pass 1 — Tag Normalization
-- =====================================================================
-- Purpose:    Normalize metadata.topics (case-fold + alias merge) and
--             metadata.people (alias merge for unambiguous fragments)
-- Risk:       LOW — additive snapshot column; UPDATEs touch metadata JSONB only;
--             content / embedding / created_at untouched.
-- Reversible: YES — `metadata_pre_pass1` snapshot column preserves original.
--             Rollback: `UPDATE thoughts SET metadata = metadata_pre_pass1;`
--             Cleanup:  `ALTER TABLE thoughts DROP COLUMN metadata_pre_pass1;`
--             (only after verification + a comfortable cooling-off period)
-- LLM cost:   $0 (pure SQL, no API calls)
-- Author:     Justin Lee + Claude (audit 2026-05-05)
-- =====================================================================
-- Block layout (each block is independent and can be applied in isolation):
--   A. Snapshot column                     (REQUIRED FIRST — gives rollback path)
--   B. Topic case-fold                     (Conservative)  ~62 collision groups merged
--   C. Topic case-pair alias merges        (Conservative)  hand-mapped variants of same concept
--   D. Topic close-synonym merges          (Moderate)      e.g. "water balance" → "mass_balance"
--   E. Topic concept rollups               (Aggressive)    e.g. engineering* → "engineering"
--   F. People alias merge — unambiguous    (Conservative)  Justin → Justin Lee, etc
--   G. People — flag ambiguous (Ryan/Matt) (Conservative)  add ambiguous=true marker, NEVER auto-merge
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- Block A. Snapshot column (REQUIRED — provides rollback path)
-- ---------------------------------------------------------------------
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS metadata_pre_pass1 JSONB;

UPDATE thoughts
SET    metadata_pre_pass1 = metadata
WHERE  metadata_pre_pass1 IS NULL;

-- Sanity check — every row must have a snapshot before any further UPDATE
DO $$
DECLARE
    unsnapshotted INTEGER;
BEGIN
    SELECT COUNT(*) INTO unsnapshotted FROM thoughts WHERE metadata_pre_pass1 IS NULL;
    IF unsnapshotted > 0 THEN
        RAISE EXCEPTION 'Block A failed: % rows have no snapshot. Aborting.', unsnapshotted;
    END IF;
    RAISE NOTICE 'Block A complete. Snapshot populated for all rows.';
END $$;

-- ---------------------------------------------------------------------
-- Block B. Topic case-fold (preserves known acronyms)
-- ---------------------------------------------------------------------
-- Strategy: lowercase every topic value EXCEPT those in the preserve list.
-- Preserve list = project codenames, process abbreviations, org acronyms
-- that have a canonical capitalization users will recognize.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{topics}',
           (
               SELECT jsonb_agg(
                   CASE
                       -- Project codenames
                       WHEN value::text IN ('"TMC-01"','"GM-01"','"APM"','"PIXY"','"Aurora"','"OB1"','"OPEN-BRAIN"','"SALTWORKS-OS"') THEN value
                       -- Org / contract codes
                       WHEN value::text IN ('"TSMC"','"IRWP"','"IRWP-A"','"IRWP-B"','"AFL"','"BSS"','"BPI"','"Saltworks"') THEN value
                       -- Process abbreviations
                       WHEN value::text IN ('"MVR"','"RO"','"IX"','"MBR"','"RCW"','"SCR"','"SLD"','"ZLD"','"BOM"','"BMR"','"HEX"','"DPT"','"RTD"','"VFD"','"PSV"','"NPSH"','"MTZ"','"OLI"') THEN value
                       -- Software / standards
                       WHEN value::text IN ('"P&ID"','"PFD"','"PFID"','"GAD"','"FAT"','"SAT"','"ITP"','"PCP"','"ECO"','"ECI"','"NTP"','"NEMA"','"SPD"','"SCCR"','"GIS"','"HVAC"','"SCADA"','"HMI"','"PLC"','"BIM"','"CAD"','"AWG"','"PE"','"EVP"','"DXT"','"MCP"','"SDR"','"ASTM"','"ISA101"','"ISA18"','"USMCA"') THEN value
                       -- Email / Teams / SharePoint / Wrike (treat as acronyms)
                       WHEN value::text IN ('"SharePoint"','"Wrike"','"Bluebeam"','"Granola"','"Notion"','"Outlook"','"Teams"') THEN value
                       -- AI tools
                       WHEN value::text IN ('"Claude"','"AI"','"Grafana"','"OpenAI"','"Codex"','"Anthropic"') THEN value
                       -- Chemistry tokens that should stay capitalized
                       WHEN value::text IN ('"NaCl"','"NaOH"','"HCl"','"LiOH"','"Li2CO3"','"OSHA"','"K1"','"K2"') THEN value
                       -- Anything else: lowercase
                       ELSE to_jsonb(LOWER(value::text))
                   END
               )
               FROM jsonb_array_elements(metadata->'topics')
           )
       )
WHERE  metadata ? 'topics' AND jsonb_typeof(metadata->'topics') = 'array';

DO $$ BEGIN RAISE NOTICE 'Block B (topic case-fold) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block C. Topic case-pair alias merges (CONSERVATIVE)
-- ---------------------------------------------------------------------
-- Merges only obvious case/punctuation variants that mean the same thing.
-- Does NOT merge semantically-distinct activities (e.g. "contract review"
-- stays distinct from "contract terms").
-- After Block B, most of these should already be lowercase, so we match
-- the lowercase forms.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{topics}',
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
           )
       )
WHERE  metadata ? 'topics' AND jsonb_typeof(metadata->'topics') = 'array';

DO $$ BEGIN RAISE NOTICE 'Block C (conservative alias merges) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block D. Topic close-synonym merges (MODERATE — OPTIONAL)
-- ---------------------------------------------------------------------
-- Comment out the entire block to skip. These merges fold semantically
-- close but distinct activities into shared concepts. Lossy in nuance,
-- but improves topic-filter recall.
-- ---------------------------------------------------------------------
-- (No additional rules in this default. Block D is reserved for future
-- refinements once Block B + C are observed in production. Leaving as a
-- no-op so the structural slot exists.)

DO $$ BEGIN RAISE NOTICE 'Block D (moderate merges) — no-op in this migration.'; END $$;

-- ---------------------------------------------------------------------
-- Block E. Topic concept rollups (AGGRESSIVE — DO NOT APPLY BY DEFAULT)
-- ---------------------------------------------------------------------
-- The block below rolls multiple "engineering*" topics up to a single
-- "engineering" tag. Same for "contract*". This is the most lossy step.
-- It is COMMENTED OUT so it does not run unless explicitly enabled.
-- Uncomment the UPDATE to apply.
-- ---------------------------------------------------------------------
-- UPDATE thoughts
-- SET metadata = jsonb_set(metadata, '{topics}',
--     (SELECT jsonb_agg(DISTINCT
--         CASE
--             WHEN value::text IN ('"engineering"','"engineering_coordination"','"engineering_deliverables"','"engineering_management"') THEN '"engineering"'::jsonb
--             WHEN value::text IN ('"contract"','"contract_review"','"contract_terms"','"contract_management"','"contract_negotiation"') THEN '"contract"'::jsonb
--             ELSE value
--         END)
--      FROM jsonb_array_elements(metadata->'topics')))
-- WHERE metadata ? 'topics' AND jsonb_typeof(metadata->'topics') = 'array';

DO $$ BEGIN RAISE NOTICE 'Block E (aggressive rollups) — disabled by default.'; END $$;

-- ---------------------------------------------------------------------
-- Block F. People alias merge — unambiguous fragments only
-- ---------------------------------------------------------------------
-- IMPORTANT: bare ambiguous first names ("Ryan", "Matt") are LEFT AS-IS
-- in this block. They will be flagged in Block G for human disambiguation.
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    metadata = jsonb_set(
           metadata,
           '{people}',
           (
               SELECT jsonb_agg(DISTINCT
                   CASE
                       WHEN value::text = '"Justin"'           THEN '"Justin Lee"'::jsonb
                       WHEN value::text = '"JL"'               THEN '"Justin Lee"'::jsonb
                       WHEN value::text = '"J.J. Burdick"'     THEN '"Jared Burdick"'::jsonb
                       WHEN value::text = '"JJ"'               THEN '"Jared Burdick"'::jsonb
                       WHEN value::text = '"Mitch"'            THEN '"Mitch Rockey"'::jsonb
                       WHEN value::text = '"Dylan"'            THEN '"Dylan Uecker"'::jsonb
                       WHEN value::text = '"John"'             THEN '"John Fourie"'::jsonb
                       WHEN value::text = '"Ben"'              THEN '"Ben Sparrow"'::jsonb
                       WHEN value::text = '"Mark"'             THEN '"Mark Burnett"'::jsonb   -- only Mark in corpus
                       WHEN value::text = '"Bryce"'            THEN '"Bryce Williamson"'::jsonb
                       WHEN value::text = '"Brian"'            THEN '"Brian Noh"'::jsonb
                       WHEN value::text = '"Maulin"'           THEN '"Maulin Trivedi"'::jsonb
                       WHEN value::text = '"Nader"'            THEN '"Nader Shakerin"'::jsonb
                       WHEN value::text = '"Ross"'             THEN '"Ross Coleman"'::jsonb
                       WHEN value::text = '"Jordan"'           THEN '"Jordan Stahn"'::jsonb
                       WHEN value::text = '"Patrick"'          THEN '"Patrick (Alfa Laval)"'::jsonb  -- placeholder; refine after Block G review
                       WHEN value::text = '"Cindy"'            THEN '"Cindy Pries"'::jsonb
                       WHEN value::text = '"Luke"'             THEN '"Luke Wilson"'::jsonb
                       -- AMBIGUOUS — DO NOT MERGE:
                       --   "Ryan"  could be Ryan Collins (Saltworks) OR Ryan Nordquist (Sundt)
                       --   "Matt"  could be Matt Holopirek (Sundt)  OR Matt Harmon  (Wigen)
                       --   "Josh"  could be Josh (Saltworks contracts) OR Josh Z. (Saltworks IT)
                       ELSE value
                   END
               )
               FROM jsonb_array_elements(metadata->'people')
           )
       )
WHERE  metadata ? 'people' AND jsonb_typeof(metadata->'people') = 'array';

DO $$ BEGIN RAISE NOTICE 'Block F (people alias merge) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block G. Flag ambiguous bare-first-names for manual disambiguation
-- ---------------------------------------------------------------------
-- Adds metadata.people_ambiguous = true to any thought whose people array
-- contains a known-ambiguous bare first name. Does NOT modify the people
-- array itself — humans (or a future tool) will resolve these.
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
-- Verification block — runs in same transaction, before COMMIT
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total            INTEGER;
    snap_total       INTEGER;
    distinct_topics  INTEGER;
    untyped          INTEGER;
    justin_lee_cnt   INTEGER;
    pm_canonical     INTEGER;
    ambiguous_cnt    INTEGER;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;
    SELECT COUNT(*) INTO snap_total FROM thoughts WHERE metadata_pre_pass1 IS NOT NULL;

    SELECT COUNT(DISTINCT t.value)
    INTO   distinct_topics
    FROM   thoughts, jsonb_array_elements_text(metadata->'topics') AS t(value);

    SELECT COUNT(*) INTO untyped FROM thoughts WHERE NOT (metadata ? 'type') OR metadata->>'type' IS NULL;

    SELECT COUNT(*) INTO justin_lee_cnt FROM thoughts WHERE metadata->'people' @> '["Justin Lee"]'::jsonb;
    SELECT COUNT(*) INTO pm_canonical   FROM thoughts WHERE metadata->'topics' @> '["project_management"]'::jsonb;
    SELECT COUNT(*) INTO ambiguous_cnt  FROM thoughts WHERE (metadata->>'people_ambiguous')::boolean IS TRUE;

    RAISE NOTICE '======== POST-PASS-1 VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                          %', total;
    RAISE NOTICE 'Rows with snapshot (must equal total):   %', snap_total;
    RAISE NOTICE 'Distinct topic values (was 868):         %', distinct_topics;
    RAISE NOTICE 'Thoughts still untyped (was 38):         %', untyped;
    RAISE NOTICE 'Thoughts tagging "Justin Lee" (was 217): %', justin_lee_cnt;
    RAISE NOTICE 'Thoughts tagging "project_management":   %', pm_canonical;
    RAISE NOTICE 'Thoughts flagged people_ambiguous:       %', ambiguous_cnt;
    RAISE NOTICE '==========================================';

    -- Hard invariants
    IF snap_total <> total THEN
        RAISE EXCEPTION 'Invariant violated: snapshot count (%) != total count (%)', snap_total, total;
    END IF;
    IF justin_lee_cnt < 217 THEN
        RAISE EXCEPTION 'Invariant violated: "Justin Lee" count (%) is below pre-merge floor (217). Block F may have over-merged.', justin_lee_cnt;
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- COMMIT (or ROLLBACK if any DO block raised an exception)
-- ---------------------------------------------------------------------
COMMIT;
