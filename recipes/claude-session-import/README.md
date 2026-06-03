# Claude Session Import

> Continuously feed your Claude Code and Cowork sessions into Open Brain as curated, searchable thoughts.

## What It Does

Walks your local Claude Code (`~/.claude/projects/`) and Cowork (`%APPDATA%\Roaming\Claude\local-agent-mode-sessions\`) JSONL session files, filters trivial sessions (one-liners, slash-command pings, aborted runs), uses an LLM to distill each remaining session into 1–3 standalone thoughts, and loads them into your Open Brain with vector embeddings and metadata. The result: every meaningful coding/planning session you've had with Claude becomes semantically searchable knowledge.

Designed for a **one-time 7-day backfill** plus a **recurring daily sync** via Windows Task Scheduler. Sessions are deduplicated by JSONL file stem, so the daily sync is safe to overlap.

## What It Does NOT Do

- **Web `claude.ai` chats** are cloud-only — there's no programmatic API. To capture those, manually export from `claude.ai → Settings → Privacy → Export Data` and process the resulting zip with the [chatgpt-conversation-import](../chatgpt-conversation-import/) recipe (the format is similar).
- **Cross-device sessions**: this script only sees the local machine. If you use Claude Code on multiple devices, run the recipe on each.
- **Tool inputs/outputs**: the parser drops `tool_use` and `tool_result` blocks so the LLM summarizes only human-readable text. If you need verbatim tool data, that's a future flag.

## Prerequisites

- Working Open Brain setup ([guide](../../docs/01-getting-started.md))
- Claude Code and/or Claude Cowork installed locally with sessions in the default paths
- Python 3.10+ (Windows: `py -3.12` works fine)
- Your Supabase project URL and service role key (from your credential tracker)
- OpenRouter API key (for LLM summarization and embeddings)

## Credential Tracker

```text
CLAUDE SESSION IMPORT -- CREDENTIAL TRACKER
--------------------------------------

FROM YOUR OPEN BRAIN SETUP
  Supabase Project URL:  ____________
  Supabase Secret key:   ____________
  OpenRouter API key:    ____________

OPTIONAL OVERRIDES (only if your installs are non-standard)
  CLAUDE_CODE_SESSIONS_DIR:  ____________
  COWORK_SESSIONS_DIR:       ____________

--------------------------------------
```

## Steps

### 1. Install dependencies

```bash
cd recipes/claude-session-import
pip install -r requirements.txt
```

This installs `requests` — the only external dependency.

### 2. Set environment variables

Copy `.env.example` to `.env` and fill in your values, then load them:

**bash / WSL:**
```bash
export $(cat .env | xargs)
```

**PowerShell:**
```powershell
Get-Content .env | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
  $k, $v = $_ -split '=', 2
  [Environment]::SetEnvironmentVariable($k, $v, 'Process')
}
```

(The included `run-daily-sync.ps1` does this automatically.)

### 3. Dry run first

```bash
python import-claude-sessions.py --days 7 --dry-run --limit 5 --verbose
```

This walks your session dirs, parses 5 sessions, summarizes them, and prints the proposed thoughts — without writing to your database. Review the output to see what would be imported.

To skip LLM cost during dry runs:

```bash
python import-claude-sessions.py --days 7 --dry-run --raw --limit 10
```

### 4. Run the 7-day backfill

```bash
python import-claude-sessions.py --days 7
```

The script will:
1. Walk `~/.claude/projects/` (Claude Code) and `%APPDATA%\Roaming\Claude\local-agent-mode-sessions\` (Cowork) for `*.jsonl` files modified in the last 7 days.
2. Parse each into a normalized transcript (drops `thinking`, `tool_use`, `tool_result` blocks).
3. Filter trivial sessions (< 4 messages, < 20 user words, slash-command-only titles).
4. Summarize each remaining session into 1–3 thoughts via `gpt-4o-mini` on OpenRouter.
5. Generate a 1536-dim embedding per thought.
6. Insert into your `thoughts` table with `metadata.source = "claude-code"` or `"cowork"`.
7. Record the file stem in `claude-session-sync-log.json` so re-runs skip it.

Progress prints to the console. Expected runtime: 1–3 minutes for a typical week of sessions.

### 5. Verify in your database

In Supabase Studio → Table Editor → `thoughts`, look for new rows with:
- `content`: prefixed with `[Claude Code: <title> | <date>]` or `[Cowork: <title> | <date>]`
- `metadata.source`: `"claude-code"` or `"cowork"`
- `metadata.session_id` / `metadata.dedup_key` / `metadata.cwd` / `metadata.is_subagent`
- `embedding`: 1536-dimension vector

### 6. Test a search

In any MCP-connected AI (Claude Desktop with `open-brain` MCP):

```
Search my brain for what I worked on in Claude Code over the last week
```

You should see the summarized thoughts come back, with their session metadata.

### 7. Set up daily sync (Windows Task Scheduler)

Use the included `run-daily-sync.ps1`. It loads `.env`, runs `python import-claude-sessions.py --days 2 --source both`, and appends to `claude-session-sync.log`.

Register the task (run from the recipe folder):

```powershell
$script = (Resolve-Path .\run-daily-sync.ps1).Path
schtasks /create /tn "OB1 Claude Session Sync" `
  /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`"" `
  /sc daily /st 06:00 /f
```

Test it manually:

```powershell
schtasks /run /tn "OB1 Claude Session Sync"
Get-Content .\claude-session-sync.log -Tail 30
```

The 2-day window plus session-stem dedup means a missed day or filesystem rotation timing won't cause data loss.

## Expected Outcome

After a backfill, your `thoughts` table contains distilled knowledge from every non-trivial Claude session in the last week. Each thought is a standalone statement (not a raw transcript) anchored with project context. Going forward, the daily sync keeps this current automatically.

Typical numbers from a 7-day backfill (heavy Claude Code user):

| Metric | Value |
|---|---|
| Sessions scanned | 30–80 |
| Filtered as trivial | ~40% (slash-commands, short pings) |
| Processed | 20–50 |
| Thoughts generated | 30–80 |
| Estimated API cost | < $0.01 |

Daily sync ingests typically 3–10 sessions per day at < $0.001/day.

## How It Works

### Pipeline

**Stage 1: Discovery** — Walks both source directories for `*.jsonl` files with mtime within `--days N`. Skips `audit.jsonl` files (metadata, not transcripts). Subagent files (`subagents/agent-*.jsonl`) are included as separate sessions.

**Stage 2: Parsing** — For each JSONL, reads line-by-line and groups `user`/`assistant` rows into a transcript. `message.content` is normalized:
- Strings (typical user prompts) — kept as-is
- Arrays of typed blocks — only `text` blocks are kept; `thinking`, `tool_use`, `tool_result` are dropped
- User messages that are pure tool_results are skipped (they're noise, not real user input)

**Stage 3: Filtering** — A session is skipped if any of:

| Filter | What it catches |
|---|---|
| Already imported | Sessions whose JSONL stem is in the sync log |
| Too few messages | < 4 messages of real text content |
| Too little user text | < 20 words across all user prompts |
| Title patterns | Slash-command-only sessions (`/init`, `/clear`, `/help`, etc.), test pings, do-not-remember markers |

**Stage 4: Summarization** — Surviving sessions go to `gpt-4o-mini` via OpenRouter with a developer-context prompt that emphasizes architectural decisions, debugging conclusions, project context, gotchas, and conventions. Returns 1–3 standalone thoughts (or empty if nothing is worth retaining).

**Stage 5: Embedding & Insertion** — Each thought gets a 1536-dim embedding (`text-embedding-3-small`) and is inserted into the `thoughts` table with full session metadata for later filtering or linking.

### Deduplication

The sync log (`claude-session-sync-log.json`) stores the JSONL **file stem** (not the in-row `sessionId`), because subagent JSONL files inherit their parent's `sessionId` and would otherwise collapse into a single dedup entry. The file stem is `{session-uuid}` for main sessions and `agent-{hash}` for subagents — uniquely one entry per JSONL.

### Why no MCP_ACCESS_KEY

Bulk imports write directly to Supabase using the service role key (same pattern as the ChatGPT and Gmail import recipes). The MCP_ACCESS_KEY is only relevant when calling the `open-brain` edge function — direct REST inserts bypass it entirely.

## Options Reference

| Flag | Description | Default |
|---|---|---|
| `--days N` | Sessions modified within N days | `7` |
| `--source SOURCE` | `claude-code`, `cowork`, or `both` | `both` |
| `--dry-run` | Parse + summarize, no DB writes | Off |
| `--limit N` | Max sessions to process (0 = unlimited) | `0` |
| `--model BACKEND` | `openrouter` or `ollama` | `openrouter` |
| `--ollama-model NAME` | Ollama model name | `qwen3` |
| `--raw` | Skip LLM, ingest user text as-is | Off |
| `--verbose` | Show full summaries during processing | Off |
| `--report FILE` | Write a markdown report of imports | None |

### Using a local LLM (free, private)

If you don't want to send transcripts to OpenRouter:

```bash
ollama pull qwen3
python import-claude-sessions.py --days 7 --model ollama --ollama-model qwen3
```

Note: embeddings still require OpenRouter (`text-embedding-3-small`) for direct Supabase insert. Only summarization runs locally.

## Cost Estimate

| Component | Model | Cost |
|---|---|---|
| Summarization | gpt-4o-mini | ~$0.15/1M input + $0.60/1M output |
| Embeddings | text-embedding-3-small | ~$0.02/1M tokens |

| Run type | Sessions | Est. cost |
|---|---|---|
| 7-day backfill | 30–80 | < $0.01 |
| Daily sync | 3–10/day | ~$0.001/day |
| 1 month of daily sync | ~150 | < $0.05 |

Even a year of daily syncs is well under $1.

## Troubleshooting

**Issue: `Missing dependency: requests`**
Solution: `pip install -r requirements.txt`. On Windows, the Microsoft Store's `python` alias may not have `requests` installed — use the full path to your real Python (e.g., `C:\Users\YOU\AppData\Local\Programs\Python\Python312\python.exe -m pip install requests`).

**Issue: `OPENROUTER_API_KEY required`**
Solution: Confirm your `.env` is loaded in the current shell. Env vars don't persist between terminals. Use the helper at the top of this README, or run via `run-daily-sync.ps1` which loads `.env` automatically.

**Issue: Subagent sessions all look like duplicates of one parent session**
Solution: The script dedups by JSONL file stem, not by the in-row `sessionId`. Subagents share a `sessionId` with their parent but have unique file names (`agent-XXXXX.jsonl`). If you see this, you're likely on an older version — pull the latest.

**Issue: `Sessions dir not found` warning**
Solution: Either Claude Code or Cowork isn't installed at the default path, or you've never run them. Use `--source claude-code` or `--source cowork` to import only what you have, or set `CLAUDE_CODE_SESSIONS_DIR` / `COWORK_SESSIONS_DIR` env vars to point at your install.

**Issue: Most sessions return "No thoughts extracted"**
Solution: This is expected behavior. The LLM is deliberately selective — it returns empty for routine coding help with no lasting decision. Use `--raw` if you want every session ingested without filtering, or `--verbose` to see what's being kept vs. skipped.

**Issue: Some sessions are missing**
Solution: Sessions with < 4 messages or < 20 user words are filtered. Slash-command-only sessions (`/init`, `/clear`, etc.) are also filtered. Run with `--dry-run --verbose` to see filter reasons. Adjust `MIN_TOTAL_MESSAGES` / `MIN_USER_WORDS` constants in the script if your threshold differs.

**Issue: `UnicodeEncodeError` in Windows console**
Solution: Already handled — the script reconfigures stdout to UTF-8 at startup. If you still see it, you may be on Python < 3.7. Upgrade Python.

**Issue: Want to start fresh after a bad import**
Solution: Delete `claude-session-sync-log.json` and the relevant `thoughts` rows in Supabase (filter by `metadata.source IN ('claude-code', 'cowork')`), then re-run.

**Issue: Daily sync isn't picking up new sessions**
Solution: Check that the scheduled task is running: `schtasks /query /tn "OB1 Claude Session Sync"`. Inspect `claude-session-sync.log` for errors. The 2-day window means a session under 48 hours old should always be eligible.
