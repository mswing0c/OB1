#!/usr/bin/env python3
"""
Open Brain — Claude Session Importer

Walks Claude Code (`~/.claude/projects/`) and Cowork
(`%APPDATA%\\Roaming\\Claude\\local-agent-mode-sessions\\`) JSONL session files,
filters trivial ones, summarizes each into 1-3 distilled thoughts via LLM,
and loads them into your Open Brain instance.

Designed for a 7-day backfill plus a recurring daily sync via Windows Task
Scheduler. Sessions are deduplicated by `sessionId`, so re-running the script
is safe.

Usage:
    python import-claude-sessions.py --days 7 [options]

Ingestion mode:
    Default:              Supabase direct insert (requires SUPABASE_URL,
                          SUPABASE_SERVICE_ROLE_KEY, OPENROUTER_API_KEY)

Options:
    --days N               Only sessions whose JSONL was modified within N days (default 7)
    --source claude-code|cowork|both    Which source(s) to import (default: both)
    --dry-run              Parse, filter, summarize, but don't ingest
    --limit N              Max sessions to process (0 = unlimited)
    --model openrouter     LLM backend: openrouter (default) or ollama
    --ollama-model NAME    Ollama model name (default: qwen3)
    --raw                  Skip summarization, ingest user messages directly
    --verbose              Show full summaries during processing
    --report FILE          Write a markdown report of everything imported

Environment variables:
    SUPABASE_URL                Supabase project URL
    SUPABASE_SERVICE_ROLE_KEY   Supabase service role key
    OPENROUTER_API_KEY          OpenRouter API key (summarization + embeddings)
    CLAUDE_CODE_SESSIONS_DIR    Override Claude Code sessions root
    COWORK_SESSIONS_DIR         Override Cowork sessions root
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ─── Configuration ───────────────────────────────────────────────────────────

SYNC_LOG_PATH = Path(__file__).parent / "claude-session-sync-log.json"

OPENROUTER_BASE = "https://openrouter.ai/api/v1"
OLLAMA_BASE = "http://localhost:11434"

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")

DEFAULT_CLAUDE_CODE_DIR = Path.home() / ".claude" / "projects"
DEFAULT_COWORK_DIR = (
    Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming")))
    / "Claude"
    / "local-agent-mode-sessions"
)
CLAUDE_CODE_SESSIONS_DIR = Path(os.environ.get("CLAUDE_CODE_SESSIONS_DIR", str(DEFAULT_CLAUDE_CODE_DIR)))
COWORK_SESSIONS_DIR = Path(os.environ.get("COWORK_SESSIONS_DIR", str(DEFAULT_COWORK_DIR)))

# Filtering thresholds
MIN_TOTAL_MESSAGES = 4
MIN_USER_WORDS = 20
SKIP_TITLE_PATTERNS = re.compile(
    r"do not remember|forget this|don't remember|ignore this"
    r"|^/(init|clear|help|compact|exit|status)\b"
    r"|^test\s*$|^hello\s*$|^hi\s*$|^ping\s*$"
    r"|limerick|haiku|poem |joke |riddle",
    re.IGNORECASE,
)

# Deterministic type classification for imported session thoughts.
# Summaries are mandated first-person ("I decided.../I learned...") by the
# SUMMARIZATION_PROMPT below, so the first verb reliably signals the type.
# This mirrors the open-brain-mcp normalizeMetadata() guard and the Pass 4.1
# migration verb list. Without it, this importer's direct inserts land untyped
# (the cause of the 2026-05 "untyped rows" QC regression — these thoughts never
# pass through the MCP extractMetadata path).
DECISION_VERBS = re.compile(
    r"\bI (decided|chose|implemented|created|recommends?|recommended|added"
    r"|built|wrote|set up|structured|generated|made|introduced)\b",
    re.IGNORECASE,
)


def infer_type(content):
    """Return 'decision' for action-verb thoughts, else 'observation'.

    Matches the deterministic scheme Pass 4 used for the historical backfill, so
    importer output stays consistent with both the live MCP guard and prior data.
    """
    return "decision" if DECISION_VERBS.search(content) else "observation"


SUMMARIZATION_PROMPT = """\
You are distilling a Claude Code or Cowork session into standalone thoughts \
for a personal knowledge base. The session is a developer working with Claude \
on coding, planning, or research tasks. Be HIGHLY SELECTIVE — only extract \
knowledge that would be valuable to retrieve months or years from now.

CAPTURE these (1-3 thoughts max):
- Architectural decisions and the reasoning behind them
- Bugs diagnosed with their root causes (so future-you doesn't re-debug)
- Project context: what was being built, for whom, and why
- Non-obvious gotchas about libraries, APIs, configs, or environments
- Conventions / patterns chosen for the codebase
- Lessons learned, mistakes acknowledged, preferences clarified
- People mentioned with context (who they are, relationship, what was discussed)
- Decisions about tooling, dependencies, or services

SKIP these entirely (return empty):
- Routine coding help with no lasting decision (formatting, syntax, one-off fixes)
- Failed exploration with no conclusion
- Generic Q&A or factual lookups
- Pure command reference ("how do I run X")
- Sessions that were short or aborted

Each thought must be:
- A clear, standalone statement (makes sense without the conversation)
- Written in first person ("I decided...", "I learned...", "We agreed...")
- Anchored with names, repo paths, file paths, or project context when available
- 1-3 sentences

Return JSON: {"thoughts": ["thought1", "thought2"]}
If the session has nothing worth capturing, return {"thoughts": []}
Err on the side of returning empty — less is more."""

# ─── Sync Log ────────────────────────────────────────────────────────────────


def load_sync_log():
    """Load sync log from disk. Returns dict with ingested_ids and last_sync."""
    try:
        with open(SYNC_LOG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"ingested_ids": {}, "last_sync": ""}


def save_sync_log(log):
    """Save sync log to disk."""
    with open(SYNC_LOG_PATH, "w") as f:
        json.dump(log, f, indent=2)


# ─── HTTP Helpers ────────────────────────────────────────────────────────────

try:
    import requests
except ImportError:
    print("Missing dependency: requests")
    print("Install with: pip install requests")
    sys.exit(1)


def http_post_with_retry(url, headers, body, retries=2):
    """POST with exponential backoff retry on transient failures."""
    for attempt in range(retries + 1):
        try:
            resp = requests.post(url, headers=headers, json=body, timeout=30)
            if resp.status_code >= 500 and attempt < retries:
                time.sleep(1 * (attempt + 1))
                continue
            return resp
        except requests.RequestException:
            if attempt < retries:
                time.sleep(1 * (attempt + 1))
                continue
            raise
    return None  # unreachable


# ─── Claude Session Discovery & Parsing ──────────────────────────────────────


def discover_sessions(sources, days):
    """Return a list of (jsonl_path, source_label) tuples for sessions modified within N days.

    Walks both Claude Code and Cowork session trees. Each *.jsonl file is treated
    as one session. Subagent files (under `subagents/` subfolder) are included
    but tagged distinctly in metadata downstream.
    """
    cutoff = time.time() - (days * 86400)
    found = []

    if "claude-code" in sources and CLAUDE_CODE_SESSIONS_DIR.is_dir():
        for jsonl in CLAUDE_CODE_SESSIONS_DIR.rglob("*.jsonl"):
            try:
                if jsonl.stat().st_mtime >= cutoff:
                    found.append((jsonl, "claude-code"))
            except OSError:
                continue
    elif "claude-code" in sources:
        print(f"  Note: Claude Code sessions dir not found at {CLAUDE_CODE_SESSIONS_DIR}")

    if "cowork" in sources and COWORK_SESSIONS_DIR.is_dir():
        for jsonl in COWORK_SESSIONS_DIR.rglob("*.jsonl"):
            try:
                if jsonl.stat().st_mtime >= cutoff:
                    found.append((jsonl, "cowork"))
            except OSError:
                continue
    elif "cowork" in sources:
        print(f"  Note: Cowork sessions dir not found at {COWORK_SESSIONS_DIR}")

    # Skip audit logs — they're metadata, not transcripts
    found = [(p, s) for p, s in found if p.name != "audit.jsonl"]
    return found


def extract_text_from_content(content):
    """Pull human-readable text out of a Claude message.content payload.

    Claude's `message.content` is either:
      - a string (typical for user prompts)
      - a list of typed blocks: {type: text|thinking|tool_use|tool_result, ...}

    We keep `text` blocks. We drop `thinking` (assistant chain-of-thought —
    huge and not useful for summarization) and `tool_use`/`tool_result`
    (noisy machine-readable payloads).
    """
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            text = block.get("text", "")
            if isinstance(text, str) and text.strip():
                parts.append(text.strip())
    return "\n".join(parts)


def parse_session(jsonl_path, source):
    """Parse a Claude Code / Cowork JSONL into a normalized session dict.

    Returns:
        dict with keys: session_id, messages (list of {role, text, timestamp}),
        started_at, ended_at, cwd, version, git_branch, title, is_subagent
    """
    messages = []
    session_id = None
    cwd = None
    version = None
    git_branch = None
    started_at = None
    ended_at = None

    try:
        with open(jsonl_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if not session_id:
                    session_id = row.get("sessionId")
                if not cwd:
                    cwd = row.get("cwd")
                if not version:
                    version = row.get("version")
                if not git_branch:
                    git_branch = row.get("gitBranch")

                ts = row.get("timestamp")
                if ts:
                    if not started_at:
                        started_at = ts
                    ended_at = ts

                row_type = row.get("type")
                if row_type not in ("user", "assistant"):
                    continue

                msg = row.get("message") or {}
                role = msg.get("role") or row_type
                text = extract_text_from_content(msg.get("content"))

                # For user messages that are pure tool_result, text will be "" — skip.
                # For real user prompts (string content), text will have substance.
                if not text:
                    continue

                messages.append({
                    "role": role,
                    "text": text,
                    "timestamp": ts,
                    "is_tool_result": (
                        role == "user"
                        and isinstance(msg.get("content"), list)
                        and any(
                            isinstance(b, dict) and b.get("type") == "tool_result"
                            for b in msg.get("content", [])
                        )
                    ),
                })
    except OSError as e:
        print(f"  Warning: could not read {jsonl_path}: {e}")
        return None

    # Fall back to filename UUID if no sessionId was found in any row
    if not session_id:
        session_id = jsonl_path.stem

    is_subagent = "subagents" in jsonl_path.parts or jsonl_path.name.startswith("agent-")

    # Dedup key: subagents inherit the parent's sessionId in their rows, so
    # using sessionId alone would collapse all subagents into one. The file
    # stem is unique per JSONL (parent UUID for main sessions, agent-XXXXX
    # for subagents) and is the right identity for dedup.
    dedup_key = jsonl_path.stem

    # Title = first non-empty user message that isn't a tool_result, truncated.
    title = "(untitled session)"
    for m in messages:
        if m["role"] == "user" and not m["is_tool_result"]:
            t = m["text"].splitlines()[0] if m["text"] else ""
            if t:
                title = t[:120]
                break

    return {
        "session_id": session_id,
        "dedup_key": dedup_key,
        "messages": messages,
        "started_at": started_at,
        "ended_at": ended_at,
        "cwd": cwd,
        "version": version,
        "git_branch": git_branch,
        "title": title,
        "is_subagent": is_subagent,
        "source": source,
        "path": str(jsonl_path),
    }


def extract_user_text(messages):
    """Concatenated text of real user messages (excluding tool_results)."""
    parts = []
    for m in messages:
        if m["role"] == "user" and not m["is_tool_result"] and m["text"]:
            parts.append(m["text"])
    return "\n---\n".join(parts)


def extract_full_transcript(messages, max_chars=12000):
    """Build a compact role-tagged transcript for the summarizer.

    Tool results are skipped; assistant thinking is already filtered out
    by extract_text_from_content. We cap to max_chars to control LLM cost.
    """
    parts = []
    used = 0
    for m in messages:
        if m["is_tool_result"]:
            continue
        if not m["text"]:
            continue
        prefix = "USER:" if m["role"] == "user" else "ASSISTANT:"
        chunk = f"{prefix} {m['text']}"
        if used + len(chunk) > max_chars:
            parts.append(f"{prefix} [...truncated]")
            break
        parts.append(chunk)
        used += len(chunk) + 1
    return "\n\n".join(parts)


def count_messages(messages):
    """Count messages (excluding pure tool_result rows)."""
    return sum(1 for m in messages if m["text"] and not m["is_tool_result"])


# ─── Filtering ──────────────────────────────────────────────────────────────


def should_skip(session, user_text, message_count, sync_log):
    """Return a skip reason string, or None if the session should be processed."""
    if session["dedup_key"] in sync_log["ingested_ids"]:
        return "already_imported"

    if message_count < MIN_TOTAL_MESSAGES:
        return "too_few_messages"

    title = session["title"] or ""
    if SKIP_TITLE_PATTERNS.search(title):
        return "skip_title"

    word_count = len(user_text.split())
    if word_count < MIN_USER_WORDS:
        return "too_little_text"

    return None


# ─── LLM Summarization ──────────────────────────────────────────────────────


def summarize_openrouter(session, transcript):
    """Summarize a session into thoughts using OpenRouter (gpt-4o-mini)."""
    if not OPENROUTER_API_KEY:
        print("Error: OPENROUTER_API_KEY environment variable required for summarization.")
        sys.exit(1)

    date_str = (session["started_at"] or "")[:10] or "unknown"
    title = session["title"]
    cwd = session["cwd"] or ""
    source = session["source"]

    truncated = transcript[:12000]

    resp = http_post_with_retry(
        f"{OPENROUTER_BASE}/chat/completions",
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
        },
        body={
            "model": "openai/gpt-4o-mini",
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": SUMMARIZATION_PROMPT},
                {
                    "role": "user",
                    "content": (
                        f"Source: {source}\n"
                        f"Session title: {title}\n"
                        f"Date: {date_str}\n"
                        f"Working dir: {cwd}\n\n"
                        f"Transcript:\n{truncated}"
                    ),
                },
            ],
            "temperature": 0,
        },
    )

    if not resp or resp.status_code != 200:
        status = resp.status_code if resp else "no response"
        print(f"   Warning: Summarization failed ({status}), skipping session.")
        return []

    try:
        data = resp.json()
        result = json.loads(data["choices"][0]["message"]["content"])
        thoughts = result.get("thoughts", [])
        return [t for t in thoughts if isinstance(t, str) and t.strip()]
    except (KeyError, json.JSONDecodeError, IndexError) as e:
        print(f"   Warning: Failed to parse summarization response: {e}")
        return []


def summarize_ollama(session, transcript, model_name="qwen3"):
    """Summarize using a local Ollama model."""
    date_str = (session["started_at"] or "")[:10] or "unknown"
    truncated = transcript[:12000]

    prompt = (
        f"{SUMMARIZATION_PROMPT}\n\n"
        f"Source: {session['source']}\n"
        f"Session title: {session['title']}\n"
        f"Date: {date_str}\n\n"
        f"Transcript:\n{truncated}"
    )

    try:
        resp = requests.post(
            f"{OLLAMA_BASE}/api/generate",
            json={"model": model_name, "prompt": prompt, "stream": False, "format": "json"},
            timeout=180,
        )
    except requests.RequestException as e:
        print(f"   Warning: Ollama request failed: {e}")
        return []

    if resp.status_code != 200:
        print(f"   Warning: Ollama returned {resp.status_code}")
        return []

    try:
        raw = resp.json().get("response", "")
        result = json.loads(raw)
        thoughts = result.get("thoughts", [])
        return [t for t in thoughts if isinstance(t, str) and t.strip()]
    except (json.JSONDecodeError, KeyError) as e:
        print(f"   Warning: Failed to parse Ollama response: {e}")
        return []


def summarize(session, transcript, args):
    """Dispatch to the configured backend."""
    if args.model == "ollama":
        return summarize_ollama(session, transcript, args.ollama_model)
    return summarize_openrouter(session, transcript)


# ─── Embedding & Ingestion ──────────────────────────────────────────────────


def generate_embedding(text):
    """Generate a 1536-dim embedding via OpenRouter (text-embedding-3-small)."""
    truncated = text[:8000]

    resp = http_post_with_retry(
        f"{OPENROUTER_BASE}/embeddings",
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
        },
        body={"model": "openai/text-embedding-3-small", "input": truncated},
    )

    if not resp or resp.status_code != 200:
        status = resp.status_code if resp else "no response"
        print(f"   Warning: Embedding generation failed ({status})")
        return None

    try:
        return resp.json()["data"][0]["embedding"]
    except (KeyError, IndexError) as e:
        print(f"   Warning: Failed to parse embedding response: {e}")
        return None


def ingest_thought_supabase(content, metadata_dict):
    """Insert a thought into Supabase with a generated embedding."""
    embedding = generate_embedding(content)
    if not embedding:
        return {"ok": False, "error": "Failed to generate embedding"}

    resp = http_post_with_retry(
        f"{SUPABASE_URL}/rest/v1/thoughts",
        headers={
            "Content-Type": "application/json",
            "apikey": SUPABASE_SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
            "Prefer": "return=minimal",
        },
        body={"content": content, "embedding": embedding, "metadata": metadata_dict},
    )

    if not resp:
        return {"ok": False, "error": "No response from Supabase"}
    if resp.status_code not in (200, 201):
        try:
            error_detail = resp.json()
        except ValueError:
            error_detail = resp.text
        return {"ok": False, "error": f"HTTP {resp.status_code}: {error_detail}"}
    return {"ok": True}


# ─── CLI ─────────────────────────────────────────────────────────────────────


def parse_args():
    parser = argparse.ArgumentParser(
        description="Import Claude Code and Cowork sessions into Open Brain",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  python import-claude-sessions.py --days 7 --dry-run --limit 5
  python import-claude-sessions.py --days 7 --source claude-code
  python import-claude-sessions.py --days 2 --source both
  python import-claude-sessions.py --days 30 --report report.md
  python import-claude-sessions.py --days 7 --model ollama --ollama-model qwen3""",
    )
    parser.add_argument("--days", type=int, default=7, help="Sessions modified within N days (default: 7)")
    parser.add_argument("--source", choices=["claude-code", "cowork", "both"], default="both")
    parser.add_argument("--dry-run", action="store_true", help="Parse and summarize but don't ingest")
    parser.add_argument("--limit", type=int, default=0, help="Max sessions to process (0 = unlimited)")
    parser.add_argument("--model", choices=["openrouter", "ollama"], default="openrouter")
    parser.add_argument("--ollama-model", default="qwen3")
    parser.add_argument("--raw", action="store_true", help="Skip summarization, ingest user messages directly")
    parser.add_argument("--verbose", action="store_true", help="Show full summaries during processing")
    parser.add_argument("--report", type=str, metavar="FILE", help="Write a markdown report")
    return parser.parse_args()


# ─── Main ────────────────────────────────────────────────────────────────────


def main():
    # Windows consoles default to cp1252; force UTF-8 so our box-drawing chars
    # and any non-ASCII session content don't crash print().
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")

    args = parse_args()

    if not args.dry_run:
        if not SUPABASE_URL:
            print("Error: SUPABASE_URL environment variable required.")
            sys.exit(1)
        if not SUPABASE_SERVICE_ROLE_KEY:
            print("Error: SUPABASE_SERVICE_ROLE_KEY environment variable required.")
            sys.exit(1)
        if not OPENROUTER_API_KEY:
            print("Error: OPENROUTER_API_KEY required for embedding generation.")
            sys.exit(1)

    if not args.raw and args.model == "openrouter" and not OPENROUTER_API_KEY:
        print("Error: OPENROUTER_API_KEY required for summarization.")
        print("Use --raw to skip summarization, or --model ollama for local inference.")
        sys.exit(1)

    sources = ["claude-code", "cowork"] if args.source == "both" else [args.source]

    print(f"\nDiscovering Claude sessions modified in the last {args.days} day(s)...")
    print(f"  Claude Code dir: {CLAUDE_CODE_SESSIONS_DIR}")
    print(f"  Cowork dir:      {COWORK_SESSIONS_DIR}")
    discovered = discover_sessions(sources, args.days)
    print(f"Found {len(discovered)} candidate session file(s).\n")

    sync_log = load_sync_log()

    mode = "DRY RUN" if args.dry_run else "LIVE"
    summarize_mode = "raw (no summarization)" if args.raw else args.model
    if args.model == "ollama" and not args.raw:
        summarize_mode += f" ({args.ollama_model})"
    print(f"  Mode:        {mode}")
    print(f"  Summarizer:  {summarize_mode}")
    print(f"  Source(s):   {', '.join(sources)}")
    if args.limit:
        print(f"  Limit:       {args.limit}")
    print()

    total = len(discovered)
    already_imported = 0
    parse_failed = 0
    filtered = 0
    filter_reasons = {}
    processed = 0
    thoughts_generated = 0
    ingested = 0
    errors = 0
    total_user_words = 0
    report_entries = []

    # Sort by mtime (oldest first) for stable, resumable runs
    discovered.sort(key=lambda x: x[0].stat().st_mtime)

    for jsonl_path, source in discovered:
        if args.limit and processed >= args.limit:
            break

        session = parse_session(jsonl_path, source)
        if session is None:
            parse_failed += 1
            continue

        user_text = extract_user_text(session["messages"])
        message_count = count_messages(session["messages"])

        skip_reason = should_skip(session, user_text, message_count, sync_log)
        if skip_reason:
            if skip_reason == "already_imported":
                already_imported += 1
            else:
                filtered += 1
                filter_reasons[skip_reason] = filter_reasons.get(skip_reason, 0) + 1
            continue

        processed += 1
        word_count = len(user_text.split())
        total_user_words += word_count

        title = session["title"]
        date_str = (session["started_at"] or "")[:10] or "unknown"
        source_label = "Cowork" if source == "cowork" else "Claude Code"
        if session["is_subagent"]:
            source_label += " (subagent)"

        print(f"{processed}. [{source_label}] {title}")
        print(f"   {message_count} messages | {word_count} user words | {date_str} | {session['session_id'][:8]}")

        if args.raw:
            thoughts = [user_text]
        else:
            transcript = extract_full_transcript(session["messages"])
            thoughts = summarize(session, transcript, args)

        thoughts_generated += len(thoughts)

        if not thoughts:
            print("   -> No thoughts extracted (empty summary)")
            if not args.dry_run:
                sync_log["ingested_ids"][session["dedup_key"]] = datetime.now(timezone.utc).isoformat()
                save_sync_log(sync_log)
            print()
            continue

        if args.verbose or args.dry_run:
            for i, thought in enumerate(thoughts, 1):
                preview = thought if len(thought) <= 200 else thought[:200] + "..."
                print(f"   Thought {i}: {preview}")

        if args.report:
            report_entries.append({
                "title": title,
                "source": source_label,
                "date": date_str,
                "messages": message_count,
                "user_words": word_count,
                "thoughts": thoughts,
                "session_id": session["session_id"],
            })

        if args.dry_run:
            print()
            continue

        metadata = {
            "source": source,
            "session_id": session["session_id"],
            "dedup_key": session["dedup_key"],
            "title": title,
            "started_at": session["started_at"],
            "ended_at": session["ended_at"],
            "message_count": message_count,
            "cwd": session["cwd"],
            "claude_version": session["version"],
            "git_branch": session["git_branch"],
            "is_subagent": session["is_subagent"],
        }

        all_ok = True
        for i, thought in enumerate(thoughts):
            content = f"[{source_label}: {title} | {date_str}] {thought}"
            # Assign a deterministic type per thought so importer rows are never
            # untyped (the session telemetry metadata above carries no type).
            thought_metadata = {**metadata, "type": infer_type(content)}
            result = ingest_thought_supabase(content, thought_metadata)
            if result.get("ok"):
                ingested += 1
                print(f"   -> Thought {i + 1} ingested")
            else:
                errors += 1
                all_ok = False
                print(f"   -> ERROR (thought {i + 1}): {result.get('error', 'unknown')}")
            time.sleep(0.2)

        if all_ok:
            sync_log["ingested_ids"][session["dedup_key"]] = datetime.now(timezone.utc).isoformat()
            sync_log["last_sync"] = datetime.now(timezone.utc).isoformat()
            save_sync_log(sync_log)

        print()

    # ─── Summary ────────────────────────────────────────────────────────────

    print("─" * 60)
    print("Summary:")
    print(f"  Sessions found:         {total}")
    if parse_failed > 0:
        print(f"  Parse failures:         {parse_failed}")
    if already_imported > 0:
        print(f"  Already imported:       {already_imported} (skipped)")
    if filtered > 0:
        reasons = ", ".join(f"{v} {k}" for k, v in sorted(filter_reasons.items(), key=lambda x: -x[1]))
        print(f"  Filtered (trivial):     {filtered} ({reasons})")
    print(f"  Processed:              {processed}")
    print(f"  Total user words:       {total_user_words:,}")
    print(f"  Thoughts generated:     {thoughts_generated}")
    if not args.dry_run:
        print(f"  Ingested:               {ingested}")
        print(f"  Errors:                 {errors}")

    # Cost estimate (matches ChatGPT recipe formula, scaled for longer Claude transcripts)
    if not args.raw and processed > 0:
        # Claude transcripts are typically ~3x longer than ChatGPT user-only text
        est_input_tokens = processed * 2500
        est_output_tokens = processed * 200
        summarize_cost = (est_input_tokens * 0.15 / 1_000_000) + (est_output_tokens * 0.60 / 1_000_000)
    else:
        summarize_cost = 0
    embedding_cost = thoughts_generated * 100 * 0.02 / 1_000_000
    total_cost = summarize_cost + embedding_cost
    print(f"  Est. API cost:          ${total_cost:.4f}")
    if summarize_cost > 0:
        print(f"    Summarization:        ${summarize_cost:.4f}")
    if embedding_cost > 0:
        print(f"    Embeddings:           ${embedding_cost:.4f}")
    print("─" * 60)

    if args.report and report_entries:
        _write_report(args.report, report_entries, {
            "total": total,
            "already_imported": already_imported,
            "filtered": filtered,
            "filter_reasons": filter_reasons,
            "processed": processed,
            "thoughts_generated": thoughts_generated,
            "ingested": ingested,
            "errors": errors,
            "total_user_words": total_user_words,
            "dry_run": args.dry_run,
        })


def _write_report(filepath, entries, stats):
    """Write a markdown report of imported sessions."""
    with open(filepath, "w", encoding="utf-8") as f:
        mode = "DRY RUN" if stats["dry_run"] else "LIVE"
        f.write(f"# Claude Session Import Report ({mode})\n\n")
        f.write(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}\n\n")

        f.write("## Stats\n\n")
        f.write("| Metric | Value |\n|--------|-------|\n")
        f.write(f"| Sessions found | {stats['total']} |\n")
        f.write(f"| Already imported | {stats['already_imported']} |\n")
        f.write(f"| Filtered (trivial) | {stats['filtered']} |\n")
        f.write(f"| Processed | {stats['processed']} |\n")
        f.write(f"| Thoughts generated | {stats['thoughts_generated']} |\n")
        if not stats["dry_run"]:
            f.write(f"| Ingested | {stats['ingested']} |\n")
            f.write(f"| Errors | {stats['errors']} |\n")
        f.write(f"| Total user words | {stats['total_user_words']:,} |\n\n")

        f.write("## Sessions\n\n")
        for entry in entries:
            f.write(f"### [{entry['source']}] {entry['title']} ({entry['date']})\n\n")
            f.write(f"_{entry['messages']} messages, {entry['user_words']} user words, session_id: `{entry['session_id'][:8]}`_\n\n")
            for i, thought in enumerate(entry["thoughts"], 1):
                f.write(f"{i}. {thought}\n")
            f.write("\n")

    print(f"\nReport written to {filepath}")


if __name__ == "__main__":
    main()
