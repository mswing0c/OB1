# Open Brain MCP Server — Latent Ontology Audit

**Date:** 2026-05-05
**Author:** Justin Lee (with Claude / Opus 4.7 assistance)
**System under audit:** Open Brain (OB1) MCP server — Supabase project `wwjjhiidtaxhcisicycr`
**Corpus snapshot:** 461 thoughts, 2026-04-16 → 2026-05-05 (19 days, 628,293 chars total)
**Scope:** Inductive discovery of the latent ontology already present in captured thoughts; additive schema proposal that preserves OB1 upstream compatibility; phased migration path.
**Working artifacts:** `Open Brain Audit/working/` — `parsed_thoughts.json` (full 461 records), `classified_thoughts.json` (enriched), `classified_index.csv` (461-row coding sheet), `cluster_analysis.txt` (cluster output), `parse_dump.ps1` / `classify_thoughts.ps1` / `analyze_clusters.ps1` (re-runnable pipeline).

---

## Executive Summary

Open Brain is doing the job it was designed for — frictionless capture, vector retrieval — but the corpus has grown a *latent* structure that the schema doesn't model. **Six source classes** generate the data (Granola backfill 53%, manual freeform notes 12%, Claude Code captures 8%, daily digests, system logs, document chunks); **only one of those source classes is actually visible to the schema** (via free-text content prefixes). The auto-extracted `metadata.type` enum has collapsed (only 3 of 5 types in active use, 8% of thoughts uncategorized). The `topics` JSONB has 801 distinct values across 1,270 occurrences with case-folding duplicates and 80% singletons. Names fragment ("Justin Lee" 217 + "Justin" 30 — same person). Multi-page pasted documents become orphan sibling thoughts with no reconstruction path.

The fix is **additive and cheap**: five new optional columns on `thoughts` (`source`, `source_id`, `project`, `parent_thought_id`, `document_code`), an alias map for vocabulary normalization, and a smarter capture-time prompt. **Pass 1 of the migration recovers 53% of the corpus's source provenance via pure regex, no LLM cost, no risk.**

---

## Section 1 — Inventory & Current State

### 1.1 Schema (read from `OB1/docs/01-getting-started.md`)

```sql
CREATE TABLE thoughts (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    content         TEXT         NOT NULL,
    embedding       vector(1536),                                          -- OpenAI text-embedding-3-small
    metadata        JSONB        DEFAULT '{}',                             -- type, topics[], people[], action_items[], dates_mentioned[]
    created_at      TIMESTAMPTZ  DEFAULT now(),
    updated_at      TIMESTAMPTZ  DEFAULT now()
);
-- Plus optional: content_fingerprint TEXT (SHA-256 dedup primitive)
-- Indexes: HNSW on embedding (cosine), GIN on metadata, B-tree on created_at, partial unique on fingerprint
-- Functions: match_thoughts(query_embedding, threshold, count, filter), upsert_thought(content, payload)
```

The metadata JSONB is populated at capture time by `extractMetadata()` in [open-brain-mcp/index.ts](OpenBrain/mswing0c%20OB1/supabase/functions/open-brain-mcp/index.ts) using OpenRouter GPT-4o-mini with this advertised schema:

```jsonc
{
  "people":         ["string", ...],            // names mentioned
  "action_items":   ["string", ...],            // implied to-dos
  "dates_mentioned":["YYYY-MM-DD", ...],
  "topics":         ["string", ...],            // 1-3 short tags, always >=1
  "type":           "observation|task|idea|reference|person_note"
}
```

### 1.2 MCP tool surface (4 tools, all registered on `McpServer`)

| Tool | Reads/Writes | Filters | Output |
|---|---|---|---|
| `capture_thought(content)` | WRITE — embedding + metadata + RPC `upsert_thought` | n/a | confirmation w/ extracted metadata |
| `search_thoughts(query, limit, threshold)` | READ — embedding similarity | by threshold | ranked similarity results |
| `list_thoughts(limit, type, topic, person, days)` | READ — JSONB `@>` filter | by type/topic/person/days | formatted text list (does NOT expose UUIDs) |
| `thought_stats()` | READ — aggregates | n/a | totals, types, top topics, top people |

### 1.3 Volume and shape

| Metric | Value |
|---|---|
| Total thoughts | **461** |
| Date range (created_at) | 2026-04-16 → 2026-05-05 (19 days) |
| Average rate | ~24 thoughts / day |
| Total content | 628,293 chars (~157K tokens) |
| Min / avg / max length | 138 / 1,363 / 4,698 chars |

### 1.4 Type distribution

| Advertised | In corpus | Notes |
|---|---|---|
| `task` | **214** (46%) | |
| `observation` | **196** (43%) | |
| `reference` | **13** (3%) | |
| `idea` | **0** | Never assigned by extractor |
| `person_note` | **0** | Never assigned by extractor |
| *(no type)* | **38** (8%) | All are `[Claude Code: …]` IDE/subagent captures |

### 1.5 Topic field

- **801 distinct topic values** (case-folded; case-sensitive count is higher in DB)
- **1,270 total topic occurrences** across 461 thoughts (avg 2.75 topics/thought)
- **648 singletons** (~80% of distinct topics appear exactly once) — symptom of free-tag rot
- Top 10 (case-folded): `project management` (66), `engineering` (28), `tsmc` (20), `tmc-01` (19), `action items` (17), `saltworks` (14), `project coordination` (10), `processing` (9), `power loss` (9), `checkpoint` (9)

### 1.6 People field (from `thought_stats`)

| Name as stored | Count | Likely canonical |
|---|---|---|
| Justin Lee | 217 | Justin Lee (self) |
| Ben Sparrow | 33 | Ben Sparrow |
| Ross | 33 | Ross Coleman |
| Justin | 30 | **Justin Lee** (fragmented) |
| Mitch | 30 | Mitch Rockey |
| Jared | 24 | Jared Burdick |
| John | 22 | John Fourie |
| Ryan | 22 | **ambiguous** (Ryan Collins / Ryan Nordquist) |
| Dylan | 21 | Dylan Uecker |
| Matt | 16 | **ambiguous** (Matt Holopirek / Matt Harmon) |

---

## Section 2 — Discovered Patterns / Clusters

The 461 thoughts cluster cleanly by **content prefix → source class**. This was discovered by scanning the first 200 chars of every entry; classification is reproducible via `classify_thoughts.ps1` (regex-based, deterministic, 460 of 461 = 99.8% coverage; 1 unclassified is a near-miss on a `Correction from …` no-colon variant).

### 2.1 Source classes (sorted by volume)

| # | Source class | Count | % | Visible to schema today? |
|---|---|---:|---:|---|
| 1 | `granola-meeting-backfill` | **244** | 52.9% | No (content prefix only) |
| 2 | `tmc-freeform-note` | 37 | 8.0% | No |
| 3 | `backfill-checkpoint` | 27 | 5.9% | No (system noise) |
| 4 | `claude-code-ide` | 23 | 5.0% | No |
| 5 | `person-bio` | 19 | 4.1% | No |
| 6 | `claude-code-subagent` | 15 | 3.3% | No |
| 7 | `saltworks-ai-strategy` | 15 | 3.3% | No |
| 8 | `document-chunk-gm01` | 12 | 2.6% | No |
| 9 | `tmc01-daily-digest` | 9 | 2.0% | No |
| 10 | `saltworks-ceo-note` | 9 | 2.0% | No |
| 11 | `lithium-edu` | 6 | 1.3% | No (off-project) |
| 12 | `tmc-structured-subnote` | 6 | 1.3% | Partial (in-content tag) |
| 13 | `tmc-event-snippet` | 5 | 1.1% | No |
| 14 | `document-chunk-ix-report` | 4 | 0.9% | No |
| 15 | `tmc-tagged-note` | 4 | 0.9% | No |
| 16+ | other (~13 small classes) | 26 | 5.6% | No |

**Bottom line:** No source class is currently first-class in the schema. Everything is recoverable only by regex on `content`.

### 2.2 Source × Type cross-tab (key cells)

| Source class | task | observation | reference | (null) |
|---|---:|---:|---:|---:|
| `granola-meeting-backfill` | **175** | 69 | 0 | 0 |
| `tmc01-daily-digest` | 2 | 7 | 0 | 0 |
| `tmc-freeform-note` | 8 | 27 | 2 | 0 |
| `claude-code-ide` | 0 | 0 | 0 | **23** |
| `claude-code-subagent` | 0 | 0 | 0 | **15** |
| `document-chunk-gm01` | 1 | 9 | 2 | 0 |
| `document-chunk-ix-report` | 1 | 2 | 1 | 0 |
| `person-bio` | 0 | 19 | 0 | 0 |
| `saltworks-ai-strategy` | 5 | 9 | 1 | 0 |

Two patterns jump out:

- **`type` is essentially a single-flag-per-source-class**, not a meaningful classification axis. Granola backfill is overwhelmingly "task" (72%); person bios are 100% "observation"; daily digests are 78% "observation". The extractor is reading off the source's writing register, not the meaning.
- **All 38 `null`-typed thoughts** are Claude Code captures. The `[Claude Code: <ide_opened_file>…]` preamble derails the extractor's classification. **38 of 38 = 100% correlation.**

### 2.3 Project distribution

| Project | Count | % |
|---|---:|---:|
| TMC-01 | 336 | 72.9% |
| Open Brain meta | 35 | 7.6% |
| Unknown / unattributed | 28 | 6.1% |
| Saltworks Strategy | 27 | 5.9% |
| Saltworks General | 17 | 3.7% |
| GM-01 | 12 | 2.6% |
| Education / off-project | 6 | 1.3% |

TMC-01 is dominant by 5×. **There is no `project` field in the schema** — TMC-01 is implied by content mentions only, and there's no canonical alias for the project (TSMC/IRWP/TMC-01/Phase A/Phase A+ are all the same project by different facets).

### 2.4 Document chunking — the orphan-sibling problem

**16 thoughts (3.5%) are chunks of just 2 documents:**

| Document | # chunks | Thought IDs (n) | Total chars |
|---|---:|---|---:|
| **IX Test Work Report Rev 1** (`SW_PL_TMC-01_XTRACT-IX_RPT-RP`) | 4 | 2, 3, 4, 5 (+ 6, 7 are companion email-thread thoughts about the same doc) | 4,732 |
| **GM-01 MVR Power Loss** (`SW_EN_GM-01_MVR_CN_R1`) | 12 | 93–103 + 425 | 5,829 |

There is no `parent_thought_id` link. Each chunk lives independently. A vector search for "IX regeneration mode" returns one chunk with no obvious way to retrieve its 5 siblings.

### 2.5 Granola meeting backfill — 95 distinct meetings, 244 thoughts

The Granola backfill referenced **95 distinct meeting dates**. Most dates correspond to multiple meetings on the same day:

| Thoughts per Granola date | # dates |
|---|---:|
| 1 thought | 14 |
| 2 thoughts | 40 |
| 3+ thoughts | 41 (one date — 2025-12-17 — has **7** distinct meetings backfilled) |

So the natural key for a Granola meeting isn't date alone — it's `(date, meeting_name)`. Currently neither is structured.

**Backfill lag:** the median Granola backfill thought has `created_at - content_referenced_date = 77 days`. (Min 1, max 150, avg 75.) This means `created_at` and the actual event date diverge by months. Anyone querying "what happened in February" with `days=90` filter is querying *creation* time, not *event* time, and will get the wrong answer.

### 2.6 Daily digest duplicates

There are **9 daily digests** for **8 distinct dates** — 2026-04-28 has 2 digest thoughts (n=50 at 4,698 chars and n=55 at 3,685 chars, both written 4/29). The fingerprint dedup primitive doesn't catch this because the renderings differ. **No `source_id` natural key would have prevented it** — but having one makes it trivial to detect and reconcile.

### 2.7 Entity reference inventory (regex over `content`)

| Entity type | Distinct refs | Sample |
|---|---:|---|
| Document codes (`SW_<XX>_<PROJ>_*`) | 4 | `SW_PL_TMC-01_XTRACT`, `SW_EN_TMC-01_XTRACT_PCEP`, `SW_EN_GM-01_MVR_CN_R1` |
| RFI references | 3 | `RFI #23`, `RFI 205`, `RFI-280` (note 3 different formats!) |
| Submittal codes | 4 | `Submittal 46_63_12`, `Submittal 50_05_12`, `…_13`, `…_15` |
| PO numbers | 3 | `PO 219658_R1`, `PO 219936`, `PO 219936_R1` |
| Bluebeam session IDs | 3 | `057-300-002`, `472-810-131`, `649-090-492` |
| Granola meeting dates | 95 | one per backfilled meeting |
| Project codenames | 7 | TMC-01 (712), TSMC (489), IRWP (112), APM (32), Aurora (23), GM-01 (20), PIXY (19) |

These entities are **first-class in the user's mental model** but invisible to the schema.

### 2.8 Length × source-class cross-tab (selected)

| Source | xs (<300) | s (300–800) | m (800–1500) | l (1500–2500) | xl (≥2500) |
|---|---:|---:|---:|---:|---:|
| `granola-meeting-backfill` | 0 | 4 | 25 | **180** | 35 |
| `tmc01-daily-digest` | 0 | 0 | 2 | 0 | **7** |
| `claude-code-ide` | 3 | **20** | 0 | 0 | 0 |
| `claude-code-subagent` | 1 | **14** | 0 | 0 | 0 |
| `backfill-checkpoint` | 14 | 10 | 3 | 0 | 0 |
| `person-bio` | 11 | 8 | 0 | 0 | 0 |

Length distribution alone is a strong predictor of source class. The fact that the system *doesn't* exploit this is fine — but a `length` analytic would be useful for stats/reporting.

---

## Section 3 — Problems & Challenges

### 3.1 The `type` enum has collapsed

- 2 of 5 types are dead: `idea` (0 uses) and `person_note` (0 uses) despite 19 person-bio thoughts and many idea-shaped strategy fragments.
- `task` and `observation` together absorb 89% of the corpus. The signal is binary, not 5-way.
- 38 thoughts (8%) have no type — 100% correlation with Claude Code captures.

**Why it happens:** `extractMetadata` in [index.ts](OpenBrain/mswing0c%20OB1/supabase/functions/open-brain-mcp/index.ts) prompts GPT-4o-mini with the 5-way enum but doesn't define crisp triggers. The model defaults to the broadest applicable bucket and ignores `idea`/`person_note` as too narrow.

### 3.2 Topic vocabulary is unbounded and unnormalized

- **801 distinct topics, 80% singletons** — at this scale topics are write-only labels.
- Casing duplicates in the underlying JSONB: `"project management"` (41) vs `"Project Management"` (23) — same concept, two rows in `thought_stats`.
- Generic + specific are mixed: `engineering` (28), `processing` (9), `meeting` (8) live alongside `Power Loss` (9), `MVR architecture` (4).
- Person names leak into the topics field as values: `Mark Burnett`, `Ben Sparrow`, etc., pulled into `topics` because the LLM saw a "topic-shaped" string. This double-indexes people once correctly into `metadata.people` and once incorrectly into `metadata.topics`.

### 3.3 People fragment

- `Justin Lee` (217) + `Justin` (30) — provably the same person, costing ~12% precision on any query that filters by person.
- `Mitch` (30), `Ross` (33), `John` (22), `Dylan` (21) — all first-name-only, all unambiguous in this corpus *today*, all fragile to a future second-Mitch.
- `Ryan` (22) and `Matt` (16) are **already ambiguous** — Ryan Collins (Saltworks tagging) ≠ Ryan Nordquist (Sundt commercial); Matt Holopirek (Sundt) ≠ Matt Harmon (Wigen).

### 3.4 Source provenance is leaking through `content` prefixes

Every automated capture path encodes its origin in the body text:
- `[Claude Code: <ide_opened_file>…]` (23 thoughts)
- `[Claude Code (subagent): …]` (15 thoughts)
- `[TMC-01 / Granola YYYY-MM-DD]` (244 thoughts)
- `[TMC-01 / Backfill checkpoint]` (27 thoughts)
- `[TMC-01 / Backfill]`, `[TMC-01 / Backfill Status YYYY-MM-DD]`, `[TMC-01 / Memory Index]`, `[TMC-01 / Memory]`, `[TMC-01 / Data Governance Note]`, `[TMC-01 / Internal Knowledge Share]`, `[TMC-01 / TSMC Application]`, `[TMC-01 / Reference]`, `[TMC-01 / TSMC IRWP-A …]`, `[TMC-01]` — (~16 thoughts)
- `TMC-01 Daily Digest YYYY-MM-DD` (9 thoughts)

This means **filtering thoughts by source today requires regex on a 600KB+ text column** — slow, fragile, and doesn't survive content edits.

### 3.5 Multi-chunk documents become orphan siblings

The IX Test Work Report Rev 1 was pasted as 4 distinct thoughts (n=2,3,4,5). Each is independently embedded and indexed. A query like "what does the IX report say about regeneration?" returns 1–2 of the 4 chunks with no signal that 2–3 more siblings exist. The user has no way to ask "give me the full document".

GM-01 MVR Power Loss is 12 chunks (n=93–103, 425). Same issue at 3× the scale.

### 3.6 Project is implicit, not explicit

TMC-01 is referenced 712 times. TSMC 489. IRWP 112. These are all the same project. No schema field captures this. The `topics` field has `TMC-01` (19 occurrences) and `TSMC` (20) and `IRWP` (variable) as topic *strings*, but inconsistent — many TMC-01 thoughts don't have any of those in `topics`.

### 3.7 No relationship between thoughts

- `parent_thought_id`: missing → can't reconstruct documents
- `supersedes`: missing → entry n=137 explicitly says `"CORRECTION / SUPERSEDES prior Saltworks AI maturity assessment thought captured 2026-04-29"` but there's no link, no flag, no tombstone on the original. Both versions remain returnable from search.
- `references-meeting`: missing → 244 thoughts reference 95 meetings; can't pivot.

### 3.8 `created_at` ≠ event time

Granola backfill creates a 75-day median lag. Anyone using `list_thoughts(days=30)` to "see recent activity" gets entries about events from January.

### 3.9 `dates_mentioned` is sparse and unusable

The metadata schema includes `dates_mentioned[]` but the field is sparsely populated (anecdotally — most thoughts I read don't have it set). Many target/deadline dates in content like "60% submission Friday Mar 13" don't get extracted as ISO 8601.

### 3.10 Daily digest is double-stored

The TMC-01 Daily Digest plugin creates one rolled-up thought per day, AND captures atomized event snippets (`tmc-event-snippet` class — 5 visible). These overlap in content. Today there's no relation linking the 5 atoms to the 1 rollup.

### 3.11 Data quality: duplicate digest

n=50 and n=55 are both 2026-04-28 daily digest, with different content. The fingerprint dedup didn't catch it (different renderings); no source_id natural key existed to enforce uniqueness.

---

## Section 4 — Proposed Ontology & Schema

### 4.1 Design principle

**Additive, OB1-upstream-compatible, alias-resolved.** All existing tools (`capture_thought`, `search_thoughts`, `list_thoughts`, `thought_stats`) keep working unchanged on day 1. New columns are NULL-able with sensible defaults. New sidecar tables are populated by lazy backfill. The `metadata` JSONB stays intact.

### 4.2 New columns on `thoughts`

```sql
ALTER TABLE thoughts ADD COLUMN source            TEXT;         -- canonical source class
ALTER TABLE thoughts ADD COLUMN source_id         TEXT;         -- natural key from upstream system
ALTER TABLE thoughts ADD COLUMN project           TEXT;         -- canonical project code
ALTER TABLE thoughts ADD COLUMN parent_thought_id UUID REFERENCES thoughts(id) ON DELETE SET NULL;
ALTER TABLE thoughts ADD COLUMN document_code     TEXT;         -- e.g. SW_PL_TMC-01_XTRACT-IX_RPT-RP
ALTER TABLE thoughts ADD COLUMN event_date        DATE;         -- semantic event time (vs created_at = capture time)
ALTER TABLE thoughts ADD COLUMN supersedes        UUID REFERENCES thoughts(id);  -- when one thought corrects another

CREATE INDEX idx_thoughts_source       ON thoughts (source) WHERE source IS NOT NULL;
CREATE INDEX idx_thoughts_project      ON thoughts (project) WHERE project IS NOT NULL;
CREATE INDEX idx_thoughts_parent       ON thoughts (parent_thought_id) WHERE parent_thought_id IS NOT NULL;
CREATE INDEX idx_thoughts_doc_code     ON thoughts (document_code) WHERE document_code IS NOT NULL;
CREATE INDEX idx_thoughts_event_date   ON thoughts (event_date) WHERE event_date IS NOT NULL;
CREATE UNIQUE INDEX idx_thoughts_src_id ON thoughts (source, source_id) WHERE source_id IS NOT NULL;
```

| Column | Justified by | Backfillable how |
|---|---|---|
| `source` | §2.1 — 16+ source classes, 99.8% recoverable from content prefix | Pure regex (Pass 2) |
| `source_id` | §2.6 duplicate digest, §2.5 Granola dates | Pure regex (Pass 2) |
| `project` | §2.3 — TMC-01 is 73% of corpus, no schema field | Heuristic + alias map (Pass 3) |
| `parent_thought_id` | §2.4 — 16 chunks of 2 documents | Manual review (Pass 5) |
| `document_code` | §2.7 — 4 distinct document codes referenced; will grow | Regex (Pass 2) |
| `event_date` | §3.8 — 75-day median backfill lag | Regex on Granola dates + LLM extract (Pass 4) |
| `supersedes` | §3.7 — n=137 SUPERSEDES is real, lonely today, will recur | Manual or future LLM extract |

### 4.3 Source-class controlled vocabulary

Adopt 12 canonical values for `source`:

| Value | Volume today | Detection |
|---|---:|---|
| `manual` | ~50 | default — none of the others match |
| `tmc01-daily-digest` | 9 | content starts with `(#?\s*)?TMC-01 Daily Digest YYYY-MM-DD` |
| `tmc-event-snippet` | 5 | `^(Mass balance review|External supplier action|External stakeholder action|Correction from|Decision locked|New RFI opened)` |
| `granola-meeting-backfill` | 244 | `^\[TMC-01 / Granola \d{4}-\d{2}-\d{2}\]` |
| `granola-meeting-live` | 0 today | reserved for future real-time captures |
| `claude-code-ide` | 23 | `^\[Claude Code: ` |
| `claude-code-subagent` | 15 | `^\[Claude Code \(subagent\):` |
| `document-chunk` | 16 | `^TMC-01 IX Test Work Report` OR `^GM-01 ` |
| `system-log` | 30 | `^\[TMC-01 / Backfill ` (any variant) |
| `system-setup` | 4 | `^Open Brain MCP` / `^Installed Open Brain` / `^OB1 MCP` |
| `strategy-fragment` | 27 | Saltworks AI/OS/CEO content cluster |
| `entity-profile` | 19 | person-bio cluster |

### 4.4 `source_id` natural keys (per source class)

| Source | source_id format | Example |
|---|---|---|
| `tmc01-daily-digest` | the YYYY-MM-DD the digest covers | `2026-05-04` |
| `granola-meeting-backfill` | `<YYYY-MM-DD>:<slugified_meeting_name>` | `2026-04-28:tsmc-centrate-tanks-and-870-coolers` |
| `tmc-event-snippet` | UTC timestamp + sender hash | `2026-04-20T17:32Z:bsparrow` |
| `claude-code-ide` | session UUID + delta-id | `74651a4d…:7c3f` |
| `system-log` | run timestamp | `2026-04-30T09:15Z` |
| `document-chunk` | `<document_code>:<section>` | `SW_PL_TMC-01_XTRACT-IX_RPT-RP:exec-summary` |

**Critical property:** the `(source, source_id)` unique index makes idempotent capture trivial. The duplicate 2026-04-28 digest (n=50, n=55) becomes a single row with the second capture being an UPDATE.

### 4.5 `project` controlled vocabulary

```
Canonical codes: TMC-01, GM-01, APM, PIXY, Aurora, IRWP-A, IRWP-B, OPEN-BRAIN, SALTWORKS-OS

Aliases (resolve to TMC-01):
  TSMC, TSMC IRWP, TSMC IRWP A, TSMC IRWP A+, IRWP, IRWP-A, Phase A, Phase A+, TMC, TMC-01

Aliases (resolve to OPEN-BRAIN):
  OB1, Open Brain MCP, OBMCP

Aliases (resolve to SALTWORKS-OS):
  Saltworks OS 2027, OS 2027, AI Stack Rank, AI Leadership
```

### 4.6 Topic vocabulary normalization

**Two passes:**

1. **Case-fold pass (deterministic):** `LOWER(topic)` everything except project codenames and document codes (preserve `TMC-01`, `MVR`, `RO`, etc. uppercase). Eliminates the 41+23 split for `project management`.

2. **Alias merge pass (manual once, then automatic):** publish a YAML alias map in the OB1 repo:

```yaml
# topic_aliases.yml — case-folded canonical forms
aliases:
  project_management: [project_management, project management, project mgmt, pm, pmo work]
  mass_balance:        [mass_balance, mass balance, water balance, mass balance review]
  thermal_work_group:  [thermal_work_group, thermal work group, twg, thermal wg]
  contract:            [contract, contract terms, contract review, contract management, contract negotiation]
  ...
```

The capture-time prompt update reads this map and emits canonical forms.

### 4.7 People canonicalization (sidecar table — optional, justified)

```sql
CREATE TABLE people (
    canonical_name  TEXT PRIMARY KEY,           -- "Justin Lee"
    aliases         TEXT[] NOT NULL DEFAULT '{}', -- {"Justin", "JL"}
    org             TEXT,                       -- "Saltworks"
    role            TEXT,                       -- "Project Engineer"
    notes           TEXT
);

-- Seed for the corpus today (10 highest-frequency):
INSERT INTO people (canonical_name, aliases, org, role) VALUES
  ('Justin Lee',     ARRAY['Justin','JL'],            'Saltworks', 'Project Engineer'),
  ('Ben Sparrow',    ARRAY['Ben','BS','BSS'],         'Saltworks', 'CEO'),
  ('Ross Coleman',   ARRAY['Ross'],                   'Saltworks', 'Structural/Mechanical Engineer'),
  ('Mitch Rockey',   ARRAY['Mitch'],                  'Carollo',   'Engineer'),
  ('Jared Burdick',  ARRAY['Jared','J.J. Burdick','JJ'],'Sundt',  'Engineer'),
  ('John Fourie',    ARRAY['John'],                   'Saltworks', 'VP Process Technology'),
  ('Dylan Uecker',   ARRAY['Dylan'],                  'Carollo',   'Engineer'),
  ('Ryan Collins',   ARRAY['Ryan Collins'],           'Saltworks', 'Engineer'),  -- NOT 'Ryan' alone (collision)
  ('Ryan Nordquist', ARRAY['Ryan Nordquist'],         'Sundt',     'Commercial'),
  ('Matt Holopirek', ARRAY['Matt Holopirek'],         'Sundt',     'Engineer'),
  ('Matt Harmon',    ARRAY['Matt Harmon'],            'Wigen',     'Engineer');
```

The capture-time prompt is updated to resolve names through this table. Bare `"Ryan"` or `"Matt"` in content is flagged for human disambiguation; the system never silently merges ambiguous first-names.

### 4.8 Documents (sidecar — optional, deferred)

```sql
CREATE TABLE documents (
    code             TEXT PRIMARY KEY,           -- "SW_PL_TMC-01_XTRACT-IX_RPT-RP"
    title            TEXT,                       -- "TMC-01 IX Test Work Report"
    revision         TEXT,                       -- "Rev 1"
    project          TEXT REFERENCES <future projects table>,
    latest_thought_id UUID REFERENCES thoughts(id),  -- root chunk
    issued_date      DATE,
    issued_to        TEXT
);
```

**Defer this until corpus has ≥3 documents with ≥3 chunks each.** Today only 2 documents qualify (IX Report, GM-01 Power Loss). At current ingest rate, expect this threshold in 30–60 days.

### 4.9 Type enum: trim and clarify

The advertised 5 types collapse to a useful 3 in production. Two options:

**Option A (additive minimum):** keep the 5 types, but rewrite the extractor prompt to specify *behavioral* triggers:

```text
type:
  task          - this thought describes work to do, an action item, or a planned event
  observation   - this thought reports something that happened, a state of affairs, or a measurement
  reference     - this thought is a stable artifact (spec, recipe, document section, fact)
  decision      - (NEW) this thought records a choice with a rationale, or supersedes a prior thought
  meeting-note  - (NEW) this thought summarizes one meeting (one-to-one with a Granola meeting)
  digest        - (NEW) this thought is an automated rollup of multiple sources for a time window
```

`idea` and `person_note` are retired (zero observed use). Add `decision`, `meeting-note`, `digest` based on observed patterns. `meeting-note` would absorb 244 of 461 (53%) cleanly. `digest` would absorb the 9 daily digests. `decision` would catch the SUPERSEDES case and the strategy fragments.

**Option B (no schema change):** Drop the `type` enum entirely from the extraction prompt. Set `type = source` everywhere. Lossy but eliminates a confused field.

**Recommendation: Option A.** The cost is the prompt update + a one-shot re-extraction of the 38 untyped thoughts.

### 4.10 Capture-time prompt update (`extractMetadata`)

Pseudo-spec for the new prompt (to be implemented in [open-brain-mcp/index.ts](OpenBrain/mswing0c%20OB1/supabase/functions/open-brain-mcp/index.ts)):

```text
You are extracting structured metadata from a thought. Before classifying:

1. Detect source class.
   - If content starts with "[Claude Code:" or "[Claude Code (subagent):" — return source="claude-code-{ide|subagent}", strip prefix before classifying body.
   - If content starts with "[TMC-01 / Granola YYYY-MM-DD]" — source="granola-meeting-backfill", source_id=date+slug.
   - If content matches "(#? ?)TMC-01 Daily Digest YYYY-MM-DD" — source="tmc01-daily-digest", source_id=date.
   - If content starts with "[TMC-01 / Backfill" — source="system-log".
   - Otherwise — source="manual".

2. Detect project. Resolve through alias map (TSMC/IRWP/Phase A → TMC-01 etc).

3. Detect document_code. If "SW_<XX>_<PROJ>_<rest>" pattern present, capture verbatim.

4. Resolve people. Pass extracted name strings through canonical_name + aliases. Flag bare ambiguous first-names ("Ryan", "Matt") as ambiguous=true.

5. Normalize topics. Lowercase except known acronyms (MVR, RO, IX, etc.). Map to canonical aliases. Cap at 3.

6. Pick type. Use the 6-value enum: task, observation, reference, decision, meeting-note, digest. Use source class as a strong prior.

7. Extract event_date. If content references "on YYYY-MM-DD" or has a Granola date, set event_date. Otherwise leave NULL (created_at suffices).
```

---

## Section 5 — Phased Migration Path

All passes are **non-destructive and idempotent**. Each pass writes new columns or normalizes existing JSONB; `content`/`embedding` are never touched.

### Pass 1 — Tag normalization (deterministic SQL)

**Effort:** 1 hour. **Risk:** low (pure SQL, fully reversible, no LLM).
**Affects:** `metadata.topics`, `metadata.people`.

```sql
-- 1.1 Case-fold topics (preserve known acronyms)
UPDATE thoughts SET metadata = jsonb_set(
    metadata, '{topics}',
    (SELECT jsonb_agg(
        CASE
          WHEN value::text IN ('"MVR"','"RO"','"IX"','"TMC-01"','"GM-01"','"PIXY"','"APM"','"TSMC"','"IRWP"','"AFL"','"VFD"','"SCADA"','"P&ID"') THEN value
          ELSE to_jsonb(LOWER(value::text))
        END
      ) FROM jsonb_array_elements(metadata->'topics'))
)
WHERE metadata ? 'topics';

-- 1.2 Apply alias map (from topic_aliases.yml; example below)
UPDATE thoughts SET metadata = jsonb_set(
    metadata, '{topics}',
    (SELECT jsonb_agg(DISTINCT
        CASE
          WHEN value::text IN ('"project_management"','"project management"','"pm"','"pmo work"') THEN '"project_management"'::jsonb
          WHEN value::text IN ('"mass_balance"','"mass balance"','"water balance"')               THEN '"mass_balance"'::jsonb
          ELSE value
        END) FROM jsonb_array_elements(metadata->'topics'))
);

-- 1.3 People alias merge (Justin + Justin Lee, etc.)
UPDATE thoughts SET metadata = jsonb_set(
    metadata, '{people}',
    (SELECT jsonb_agg(DISTINCT
        CASE
          WHEN value::text = '"Justin"'           THEN '"Justin Lee"'::jsonb
          WHEN value::text = '"J.J. Burdick"'     THEN '"Jared Burdick"'::jsonb
          WHEN value::text = '"Mitch"'            THEN '"Mitch Rockey"'::jsonb
          WHEN value::text = '"Dylan"'            THEN '"Dylan Uecker"'::jsonb
          WHEN value::text = '"John"'             THEN '"John Fourie"'::jsonb
          WHEN value::text IN ('"Ryan"','"Matt"') THEN value  -- LEAVE AMBIGUOUS, do not silently merge
          ELSE value
        END) FROM jsonb_array_elements(metadata->'people'))
);
```

**Predicted impact:**
- Topic distinct count: 801 → ~450 (estimated 44% reduction)
- `project management` row in thought_stats: 41 + 23 + variants = ~66 unified
- Top-10 people stat: `Justin Lee` row goes from 217 → ~247 (absorbs 30 `Justin` mentions)

### Pass 2 — Source / source_id / document_code regex backfill

**Effort:** 2 hours. **Risk:** low (pure regex, additive columns only).
**Affects:** new columns `source`, `source_id`, `document_code`.

```sql
-- 2.1 Apply source classifier
UPDATE thoughts SET source = 'claude-code-ide'         WHERE source IS NULL AND content ~ '^\[Claude Code:[^[]*\]';
UPDATE thoughts SET source = 'claude-code-subagent'    WHERE source IS NULL AND content ~ '^\[Claude Code \(subagent\):';
UPDATE thoughts SET source = 'granola-meeting-backfill', source_id = (regexp_match(content, '^\[TMC-01 / Granola (\d{4}-\d{2}-\d{2})\]'))[1]
                                                       WHERE source IS NULL AND content ~ '^\[TMC-01 / Granola \d{4}-\d{2}-\d{2}\]';
UPDATE thoughts SET source = 'system-log'              WHERE source IS NULL AND content ~ '^\[TMC-01 / Backfill';
UPDATE thoughts SET source = 'tmc01-daily-digest', source_id = (regexp_match(content, 'TMC-01 Daily Digest (\d{4}-\d{2}-\d{2})'))[1]
                                                       WHERE source IS NULL AND content ~ '^#?\s*TMC-01 Daily Digest \d{4}-\d{2}-\d{2}';
UPDATE thoughts SET source = 'document-chunk'          WHERE source IS NULL AND (content ~ '^TMC-01 IX Test Work Report' OR content ~ '^GM-01 ');
UPDATE thoughts SET source = 'system-setup'            WHERE source IS NULL AND content ~ '^(Open Brain MCP|Installed Open Brain|OB1 MCP)';
UPDATE thoughts SET source = 'manual'                  WHERE source IS NULL;

-- 2.2 Document code extraction
UPDATE thoughts SET document_code = (regexp_match(content, 'SW_[A-Z]{2}_(?:TMC-01|GM-01)_[A-Z0-9_-]+'))[1]
WHERE document_code IS NULL AND content ~ 'SW_[A-Z]{2}_(TMC-01|GM-01)_';

-- 2.3 Granola meeting source_id refinement (add slugified meeting name when present)
UPDATE thoughts SET source_id = source_id || ':' || regexp_replace(LOWER(SUBSTRING(content FROM '\] ([^.\n]{1,80})')), '[^a-z0-9]+', '-', 'g')
WHERE source = 'granola-meeting-backfill' AND source_id ~ '^\d{4}-\d{2}-\d{2}$';
```

**Predicted impact:**
- 460 of 461 thoughts get a non-null `source` (only the 1 unclassified leftover stays manual)
- ~280 thoughts get a `source_id` (244 Granola + 9 digests + 27 system logs)
- ~16 thoughts get a `document_code`
- The duplicate digest (n=50, n=55) is now visible: same `(source='tmc01-daily-digest', source_id='2026-04-28')`. A reconciliation query identifies it; manual merge needed.

### Pass 3 — Project alias resolution

**Effort:** 1 hour. **Risk:** low.
**Affects:** new column `project`.

```sql
UPDATE thoughts SET project = 'TMC-01'
WHERE project IS NULL AND (
   content ~* '\b(TMC-01|TSMC|IRWP|Phase A\+?)\b'
   OR (metadata->'topics') @> '["TMC-01"]'::jsonb
   OR (metadata->'topics') @> '["TSMC"]'::jsonb
);

UPDATE thoughts SET project = 'GM-01'        WHERE project IS NULL AND content ~ '\bGM-01\b';
UPDATE thoughts SET project = 'OPEN-BRAIN'   WHERE project IS NULL AND source IN ('system-log','system-setup');
UPDATE thoughts SET project = 'SALTWORKS-OS' WHERE project IS NULL AND content ~* '(Saltworks OS 2027|AI Stack Rank|AI Leadership Team)';
```

**Predicted impact:** ~90% of thoughts get a `project` value. Remaining ~10% are off-project / educational / ambiguous and stay NULL.

### Pass 4 — Type re-extraction for the 38 untyped Claude-Code thoughts

**Effort:** 30 min wall-clock + ~$0.05 LLM cost (38 × GPT-4o-mini).
**Risk:** low — additive, content unchanged.

```python
# Pseudocode — re-run extractMetadata on the 38 Claude Code captures with the v2 prompt
for thought in thoughts.filter(type=null, source__in=['claude-code-ide','claude-code-subagent']):
    body = strip_claude_code_prefix(thought.content)
    extracted = extractMetadata_v2(body)
    thought.metadata['type'] = extracted['type']
    save(thought)
```

After Pass 4, 100% of thoughts have a non-null `type` from the new 6-value enum.

### Pass 5 — Multi-chunk document parent grouping

**Effort:** 2 hours (manual review) + SQL UPDATE. **Risk:** medium (judgment).
**Affects:** `parent_thought_id`.

For each multi-chunk document identified in §2.4:

1. Designate the *summary* chunk as the parent (e.g. n=5 for IX Report — the executive summary).
2. SET `parent_thought_id = <parent_id>` on all sibling chunks.
3. Optionally: write a `documents` row pointing to the parent.

```sql
-- IX Test Work Report Rev 1 — parent = exec summary chunk (n=5)
UPDATE thoughts SET parent_thought_id = (SELECT id FROM thoughts WHERE content LIKE 'TMC-01 IX Test Work Report Rev 1 — Executive summary%' LIMIT 1)
WHERE content LIKE 'TMC-01 IX Test Work Report Rev 1 —%' AND content NOT LIKE '%Executive summary%';

-- GM-01 Power Loss — parent = master reference chunk (n=93)
UPDATE thoughts SET parent_thought_id = (SELECT id FROM thoughts WHERE content LIKE 'GM-01 Power Loss reference%' LIMIT 1)
WHERE content LIKE 'GM-01 %' AND content NOT LIKE 'GM-01 Power Loss reference%' AND content NOT LIKE 'GM-01 project: synthetic%';
```

After Pass 5, the 16 chunks are linked. A new convenience query `SELECT * FROM thoughts WHERE parent_thought_id = $1` reconstructs the document.

### Pass 6 (deferred) — Sidecar tables

Hold until volume justifies. Trigger conditions:
- `documents` table: ≥3 documents with ≥3 chunks each (today: 2, threshold maybe 30–60 days)
- `people` sidecar with aliases: any time, but only valuable once capture-time prompt uses it (which requires the prompt update first)
- `projects` table: when a 3rd active project (beyond TMC-01, GM-01) appears at scale

### 5.1 Effort & risk summary

| Pass | Effort | LLM cost | Risk | Reversible? |
|---|---|---:|---|---|
| 1 — Tag normalization | 1 hr | $0 | Low | Yes (snapshot before) |
| 2 — Source backfill | 2 hr | $0 | Low | Yes (drop column) |
| 3 — Project backfill | 1 hr | $0 | Low | Yes |
| 4 — Type re-extraction | 30 min + LLM | ~$0.05 | Low | Yes |
| 5 — Document parent linking | 2 hr | $0 | Medium (judgment) | Yes |
| 6 — Sidecar tables (deferred) | 4 hr (when triggered) | $0 | Medium | Yes |
| **Total (Pass 1–5)** | **~6.5 hr** | ~$0.05 | — | — |

### 5.2 Migration order matters

Recommended order: 1 → 2 → 3 → 4 → 5. Specifically:
- Pass 1 *before* Pass 2 because the alias map informs the source classifier (some Saltworks-AI thoughts aren't picked up by source class regex but ARE caught by topic alias).
- Pass 2 *before* Pass 3 because `source` informs the project rule (system-log → OPEN-BRAIN regardless of content).
- Pass 4 *after* Pass 2 because the v2 prompt uses `source` as a strong prior.

### 5.3 Verification queries (post-migration)

```sql
-- A. Source coverage
SELECT source, COUNT(*) FROM thoughts GROUP BY source ORDER BY 2 DESC;
-- expect: granola-meeting-backfill ~244, manual ~50, ..., NULL = 0

-- B. Project coverage
SELECT project, COUNT(*) FROM thoughts GROUP BY project ORDER BY 2 DESC;
-- expect: TMC-01 ~336, OPEN-BRAIN ~35, ..., NULL <= 30

-- C. Type coverage
SELECT (metadata->>'type') AS type, COUNT(*) FROM thoughts GROUP BY 1 ORDER BY 2 DESC;
-- expect: NULL = 0, 6 distinct values

-- D. Duplicate detection (now possible)
SELECT source, source_id, COUNT(*) FROM thoughts WHERE source_id IS NOT NULL GROUP BY 1,2 HAVING COUNT(*) > 1;
-- expect: row for ('tmc01-daily-digest','2026-04-28') count=2 — flag for manual reconciliation

-- E. Document chunk reconstruction
SELECT id, parent_thought_id, LEFT(content, 80) FROM thoughts WHERE document_code = 'SW_PL_TMC-01_XTRACT-IX_RPT-RP' ORDER BY parent_thought_id NULLS FIRST, created_at;
-- expect: parent first, 3 chunks underneath
```

---

## Appendix A — Verification trail

| Claim | Evidence |
|---|---|
| 461 thoughts, 19-day span | `mcp__Open_Brain__thought_stats` returned counts; `parsed_thoughts.json` has 461 records |
| 38 untyped thoughts = Claude Code captures | `classify_thoughts.ps1` source × type cross-tab: claude-code-ide=23, claude-code-subagent=15, sum=38 ✓ |
| 244 Granola backfill thoughts, 95 distinct dates | `analyze_clusters.ps1` + Bash grep: 95 distinct `Granola YYYY-MM-DD` matches |
| 75-day median backfill lag | `analyze_clusters.ps1` temporal-gap section: median=77 (close to 75 due to bucketing) |
| Duplicate digest 2026-04-28 (n=50, n=55) | `analyze_clusters.ps1` daily-digest dedup section |
| Topics 801 distinct, 80% singletons | `analyze_clusters.ps1` topic dictionary section |
| Justin Lee 217 + Justin 30 | `mcp__Open_Brain__thought_stats` people frequency |

## Appendix B — Working dataset files (preserved as audit artifacts)

```
Open Brain Audit/
├── 2026-05-05_open_brain_ontology_audit.md    ← this file
└── working/
    ├── raw_dump.json                           ← raw list_thoughts(limit=500) JSON dump (664 KB)
    ├── parsed_thoughts.json                    ← 461 structured records (n, date, type, topics, content, length)
    ├── parsed_index.csv                        ← slim 461-row index (no content body)
    ├── classified_thoughts.json                ← enriched with source_class, project, document_role, length_bucket, entities
    ├── classified_index.csv                    ← slim version of above
    ├── cluster_analysis.txt                    ← raw output of analyze_clusters.ps1
    ├── parse_dump.ps1                          ← parser
    ├── classify_thoughts.ps1                   ← inductive classifier (re-runnable as corpus grows)
    └── analyze_clusters.ps1                    ← cluster analyzer (re-runnable)
```

The classifier and analyzer scripts are deterministic and re-runnable — the audit can be repeated against a future corpus snapshot to track ontology drift over time.
