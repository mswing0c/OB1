-- =====================================================================
-- Open Brain — Pass 2 — Source / source_id / document_code backfill
-- =====================================================================
-- Purpose:    Populate first-class structural columns from regex over content.
--             Adds the full set of new columns proposed in the audit (so future
--             passes don't need to ALTER TABLE) but only POPULATES three:
--             source, source_id, document_code. project / parent_thought_id /
--             event_date / supersedes stay NULL until Pass 3+.
-- Risk:       LOW — additive columns, regex-based UPDATE, no JSONB tricks
--             (the failure modes that bit Pass 1 don't apply here).
-- Reversible: YES — set the new columns back to NULL or DROP COLUMN.
-- LLM cost:   $0 (pure SQL, no API calls)
-- Option B:   Per user choice 2026-05-06, the (source, source_id) UNIQUE
--             index is DEFERRED. Duplicates (the known 2026-04-28 digest)
--             are surfaced as a COUNT in the verification block but do not
--             fail the migration. Future Pass 2.5 can reconcile and add
--             UNIQUE once the corpus is clean.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Block 0. Schema additions (all 7 audit-proposed columns, NULL-able)
-- ---------------------------------------------------------------------
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS source            TEXT;
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS source_id         TEXT;
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS project           TEXT;
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS parent_thought_id UUID REFERENCES thoughts(id) ON DELETE SET NULL;
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS document_code     TEXT;
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS event_date        DATE;
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS supersedes        UUID REFERENCES thoughts(id) ON DELETE SET NULL;

DO $$ BEGIN RAISE NOTICE 'Block 0 (schema add) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block 1. Backfill `source` via regex on content prefix.
--          ORDER MATTERS — most specific patterns first. Every UPDATE has
--          `WHERE source IS NULL` so each row is classified exactly once.
-- ---------------------------------------------------------------------

-- Claude Code subagent — must be checked BEFORE claude-code-ide because
-- "[Claude Code (subagent):" also begins with "[Claude Code:"
UPDATE thoughts SET source = 'claude-code-subagent'
WHERE source IS NULL AND content ~ '^\[Claude Code \(subagent\):';

UPDATE thoughts SET source = 'claude-code-ide'
WHERE source IS NULL AND content ~ '^\[Claude Code:';

-- Granola meeting backfill — by far the largest cluster (~244 rows)
UPDATE thoughts SET source = 'granola-meeting-backfill'
WHERE source IS NULL AND content ~ '^\[TMC-01 / Granola \d{4}-\d{2}-\d{2}\]';

-- System log: backfill checkpoints, completion, status, memory operations,
-- data governance notes (all are operational metadata, not project content)
UPDATE thoughts SET source = 'system-log'
WHERE source IS NULL AND content ~ '^\[TMC-01 / (Backfill|Memory|Data Governance)';

-- Daily digest: the rolled-up daily project summary
UPDATE thoughts SET source = 'tmc01-daily-digest'
WHERE source IS NULL AND content ~ '^#?\s*TMC-01 Daily Digest \d{4}-\d{2}-\d{2}';

-- Document chunks: pasted multi-thought documents
UPDATE thoughts SET source = 'document-chunk'
WHERE source IS NULL AND (content ~ '^TMC-01 IX Test Work Report Rev' OR content ~ '^GM-01 ');

-- System setup: Open Brain installation / platform notes
UPDATE thoughts SET source = 'system-setup'
WHERE source IS NULL AND content ~ '^(Open Brain MCP|Installed Open Brain|OB1 MCP)';

-- Atomized event snippets (per-email/per-Teams-message/per-PO captures
-- that get rolled up into the daily digest)
UPDATE thoughts SET source = 'tmc-event-snippet'
WHERE source IS NULL AND content ~ '^(Mass balance review|External supplier action|External stakeholder action|Correction from|Decision locked|New RFI opened|Teams:|SharePoint material update|PO activity:|TMC-01 Submittal )';

-- Strategy fragments: Saltworks AI / OS 2027 / CEO notes
UPDATE thoughts SET source = 'strategy-fragment'
WHERE source IS NULL AND (
    content ~ '^Saltworks (AI|OS|SharePoint|Lunch|Crystallizer)' OR
    content ~ '^Ben Sparrow' OR
    content ~ '^MCP governance' OR
    content ~ '^Custom Claude skills' OR
    content ~ '^External AI Consultant' OR
    content ~ '^Claude capacity' OR
    content ~ '^Justin Lee shared Anthropic' OR
    content ~ '^CORRECTION / SUPERSEDES'
);

-- Entity profiles: one-line bios of people / vendors
UPDATE thoughts SET source = 'entity-profile'
WHERE source IS NULL AND (
    content ~ '^[A-Z][a-z]+ ([A-Z][a-z]+ )?(is|works|leads|handles|runs|coordinates|manages) ' OR
    content ~ '^Justin (Lee )?(works|started|uses|also supports)' OR
    content ~ '^[A-Z][a-z]+ at (Saltworks|Wigen|Alfa Laval|Sundt|Carollo|Pillar|Howden|Andritz|TSMC|DuPont)' OR
    content ~ '^[A-Z][a-z]+ and [A-Z][a-z]+ are '
);

-- Default: anything left is a manual freeform capture
UPDATE thoughts SET source = 'manual' WHERE source IS NULL;

DO $$ BEGIN RAISE NOTICE 'Block 1 (source backfill) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block 2. Backfill `source_id` for sources where a natural key exists
--          and is reliably extractable from content.
-- ---------------------------------------------------------------------

-- Granola meeting: source_id = the YYYY-MM-DD inside the prefix
UPDATE thoughts
SET    source_id = (regexp_match(content, '^\[TMC-01 / Granola (\d{4}-\d{2}-\d{2})\]'))[1]
WHERE  source = 'granola-meeting-backfill' AND source_id IS NULL;

-- Daily digest: source_id = the YYYY-MM-DD the digest covers
UPDATE thoughts
SET    source_id = (regexp_match(content, 'TMC-01 Daily Digest (\d{4}-\d{2}-\d{2})'))[1]
WHERE  source = 'tmc01-daily-digest' AND source_id IS NULL;

-- System log: source_id = the YYYY-MM-DD of the run, when present
UPDATE thoughts
SET    source_id = (regexp_match(content, 'Run on (\d{4}-\d{2}-\d{2})'))[1]
WHERE  source = 'system-log' AND source_id IS NULL
  AND  content ~ 'Run on \d{4}-\d{2}-\d{2}';

DO $$ BEGIN RAISE NOTICE 'Block 2 (source_id backfill) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block 3. Granola source_id refinement — append slugified meeting name.
--          Idempotent: only fires on rows whose source_id is still
--          date-only (no colon).
-- ---------------------------------------------------------------------
UPDATE thoughts
SET    source_id = source_id || ':' || regexp_replace(
           LOWER(SUBSTRING(content FROM '\] ([^.\n]{1,80})')),
           '[^a-z0-9]+', '-', 'g'
       )
WHERE  source = 'granola-meeting-backfill'
  AND  source_id ~ '^\d{4}-\d{2}-\d{2}$'                            -- date-only (idempotent guard)
  AND  SUBSTRING(content FROM '\] ([^.\n]{1,80})') IS NOT NULL;     -- meeting name extractable

DO $$ BEGIN RAISE NOTICE 'Block 3 (granola slug refinement) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block 4. Document code extraction.
--          Pattern: SW_<XX>_<TMC-01|GM-01>_<rest>
--          e.g. SW_PL_TMC-01_XTRACT-IX_RPT-RP, SW_EN_GM-01_MVR_CN_R1
-- ---------------------------------------------------------------------
-- regexp_match returns the entire match in [1] when the pattern uses only
-- non-capturing groups (?:...). Single UPDATE is sufficient.
UPDATE thoughts
SET    document_code = (regexp_match(content, 'SW_[A-Z]{2}_(?:TMC-01|GM-01)_[A-Z0-9_-]+'))[1]
WHERE  document_code IS NULL
  AND  content ~ 'SW_[A-Z]{2}_(TMC-01|GM-01)_';

DO $$ BEGIN RAISE NOTICE 'Block 4 (document code extraction) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Block 5. Indexes (non-unique only — UNIQUE on (source, source_id)
--          deferred per Option B until duplicates are reconciled).
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_thoughts_source            ON thoughts (source)            WHERE source IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_thoughts_project           ON thoughts (project)           WHERE project IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_thoughts_parent_thought_id ON thoughts (parent_thought_id) WHERE parent_thought_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_thoughts_document_code     ON thoughts (document_code)     WHERE document_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_thoughts_event_date        ON thoughts (event_date)        WHERE event_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_thoughts_source_id_lookup  ON thoughts (source, source_id) WHERE source_id IS NOT NULL;
-- NOT created (Option B): CREATE UNIQUE INDEX ... ON thoughts (source, source_id) WHERE source_id IS NOT NULL;

DO $$ BEGIN RAISE NOTICE 'Block 5 (indexes — non-unique per Option B) complete.'; END $$;

-- ---------------------------------------------------------------------
-- Verification — strong invariants. Migration aborts if any fails.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    total              INTEGER;
    src_null           INTEGER;
    src_manual         INTEGER;
    src_granola        INTEGER;
    src_claude_total   INTEGER;
    src_digest         INTEGER;
    src_syslog         INTEGER;
    src_event_snippet  INTEGER;
    src_doc_chunk      INTEGER;
    src_setup          INTEGER;
    src_strategy       INTEGER;
    src_entity         INTEGER;
    src_id_granola     INTEGER;
    src_id_with_slug   INTEGER;
    src_id_digest      INTEGER;
    doc_codes_count    INTEGER;
    distinct_docs      INTEGER;
    duplicate_pairs    INTEGER;
    duplicate_examples TEXT;
BEGIN
    SELECT COUNT(*) INTO total FROM thoughts;
    SELECT COUNT(*) INTO src_null            FROM thoughts WHERE source IS NULL;
    SELECT COUNT(*) INTO src_manual          FROM thoughts WHERE source = 'manual';
    SELECT COUNT(*) INTO src_granola         FROM thoughts WHERE source = 'granola-meeting-backfill';
    SELECT COUNT(*) INTO src_claude_total    FROM thoughts WHERE source IN ('claude-code-ide', 'claude-code-subagent');
    SELECT COUNT(*) INTO src_digest          FROM thoughts WHERE source = 'tmc01-daily-digest';
    SELECT COUNT(*) INTO src_syslog          FROM thoughts WHERE source = 'system-log';
    SELECT COUNT(*) INTO src_event_snippet   FROM thoughts WHERE source = 'tmc-event-snippet';
    SELECT COUNT(*) INTO src_doc_chunk       FROM thoughts WHERE source = 'document-chunk';
    SELECT COUNT(*) INTO src_setup           FROM thoughts WHERE source = 'system-setup';
    SELECT COUNT(*) INTO src_strategy        FROM thoughts WHERE source = 'strategy-fragment';
    SELECT COUNT(*) INTO src_entity          FROM thoughts WHERE source = 'entity-profile';
    SELECT COUNT(*) INTO src_id_granola      FROM thoughts WHERE source = 'granola-meeting-backfill' AND source_id IS NOT NULL;
    SELECT COUNT(*) INTO src_id_with_slug    FROM thoughts WHERE source = 'granola-meeting-backfill' AND source_id ~ ':';
    SELECT COUNT(*) INTO src_id_digest       FROM thoughts WHERE source = 'tmc01-daily-digest' AND source_id IS NOT NULL;
    SELECT COUNT(*) INTO doc_codes_count     FROM thoughts WHERE document_code IS NOT NULL;
    SELECT COUNT(DISTINCT document_code) INTO distinct_docs FROM thoughts WHERE document_code IS NOT NULL;

    SELECT COUNT(*) INTO duplicate_pairs FROM (
        SELECT source, source_id
        FROM   thoughts
        WHERE  source_id IS NOT NULL
        GROUP  BY source, source_id
        HAVING COUNT(*) > 1
    ) sub;

    SELECT string_agg(source || '|' || source_id || '(x' || c::text || ')', ', ')
    INTO   duplicate_examples
    FROM (
        SELECT source, source_id, COUNT(*) c
        FROM   thoughts
        WHERE  source_id IS NOT NULL
        GROUP  BY source, source_id
        HAVING COUNT(*) > 1
        ORDER  BY c DESC
        LIMIT  5
    ) e;

    RAISE NOTICE '======== POST-PASS-2 VERIFICATION ========';
    RAISE NOTICE 'Total thoughts:                          %', total;
    RAISE NOTICE 'Rows with source IS NULL (must be 0):    %', src_null;
    RAISE NOTICE '--- Source distribution ---';
    RAISE NOTICE '  granola-meeting-backfill:              % (audit predicted ~244)', src_granola;
    RAISE NOTICE '  manual:                                % (audit predicted ~50)', src_manual;
    RAISE NOTICE '  system-log:                            % (audit predicted ~30)', src_syslog;
    RAISE NOTICE '  claude-code-ide + claude-code-subagent:% (was 38 untyped)', src_claude_total;
    RAISE NOTICE '  strategy-fragment:                     %', src_strategy;
    RAISE NOTICE '  entity-profile:                        %', src_entity;
    RAISE NOTICE '  document-chunk:                        %', src_doc_chunk;
    RAISE NOTICE '  tmc01-daily-digest:                    %', src_digest;
    RAISE NOTICE '  tmc-event-snippet:                     %', src_event_snippet;
    RAISE NOTICE '  system-setup:                          %', src_setup;
    RAISE NOTICE '--- source_id coverage ---';
    RAISE NOTICE '  granola w/ source_id:                  % (must equal %)', src_id_granola, src_granola;
    RAISE NOTICE '  granola w/ slug-refined source_id:     %', src_id_with_slug;
    RAISE NOTICE '  daily digest w/ source_id:             % (must equal %)', src_id_digest, src_digest;
    RAISE NOTICE '--- document codes ---';
    RAISE NOTICE '  Thoughts with document_code:           %', doc_codes_count;
    RAISE NOTICE '  Distinct document codes:               %', distinct_docs;
    RAISE NOTICE '--- (source, source_id) duplicates [Option B observation, not failure] ---';
    RAISE NOTICE '  Duplicate pairs:                       %', duplicate_pairs;
    RAISE NOTICE '  Examples:                              %', COALESCE(duplicate_examples, 'none');
    RAISE NOTICE '==========================================';

    -- Hard invariants
    IF src_null > 0 THEN
        RAISE EXCEPTION 'Invariant: % rows have source IS NULL', src_null;
    END IF;
    IF src_granola < 240 THEN
        RAISE EXCEPTION 'Invariant: granola count = %, expected ~244', src_granola;
    END IF;
    IF src_claude_total < 35 THEN
        RAISE EXCEPTION 'Invariant: claude-code source count = %, expected ~38', src_claude_total;
    END IF;
    IF src_id_granola <> src_granola THEN
        RAISE EXCEPTION 'Invariant: granola-meeting-backfill rows missing source_id: %/%', src_id_granola, src_granola;
    END IF;
    IF src_id_digest <> src_digest THEN
        RAISE EXCEPTION 'Invariant: tmc01-daily-digest rows missing source_id: %/%', src_id_digest, src_digest;
    END IF;
    IF distinct_docs < 3 THEN
        RAISE EXCEPTION 'Invariant: distinct document_codes = %, expected ~4', distinct_docs;
    END IF;
END $$;

COMMIT;
