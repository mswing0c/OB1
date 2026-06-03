#!/usr/bin/env node
/**
 * Open Brain (OB1) MCP Bridge
 *
 * Wraps the remote Supabase Edge Function (HTTP transport) as a local stdio
 * MCP server, so Claude Desktop's stdio-only MCP client can talk to it.
 *
 * Flow:
 *   Claude Desktop ──stdio JSON-RPC──▶ this script ──HTTPS POST──▶ Supabase Edge Function
 *                  ◀─stdio JSON-RPC── this script ◀──HTTPS body── Supabase Edge Function
 *
 * No external npm dependencies — uses only Node built-ins (https, readline).
 * Compatible with Claude Desktop's bundled Node.js v24+.
 */

'use strict';

const https = require('https');
const readline = require('readline');

// ─── Configuration (Approach A: hard-coded) ──────────────────────────────────
const OB_URL = 'https://wwjjhiidtaxhcisicycr.supabase.co/functions/v1/open-brain-mcp';
const BRAIN_KEY = '4cfc7a7711fea54a89b29727891a0761b51273a995286cfe3552bf52a666deff';
// ─────────────────────────────────────────────────────────────────────────────

const urlObj = new URL(OB_URL);

// Per-process session ID assigned by the server (Streamable HTTP transport).
// Echoed back on every subsequent request via the Mcp-Session-Id header.
let sessionId = null;

/**
 * Send a single JSON-RPC message to OB1 and return the parsed response.
 * Handles both `application/json` and `text/event-stream` response bodies
 * (the OB1 server uses Hono's StreamableHTTPTransport which can return either).
 */
function sendToOB(message) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(message);
    const headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'Content-Length': Buffer.byteLength(body),
      'x-brain-key': BRAIN_KEY,
    };
    if (sessionId) headers['Mcp-Session-Id'] = sessionId;

    const req = https.request({
      hostname: urlObj.hostname,
      path: urlObj.pathname,
      method: 'POST',
      headers,
    }, (res) => {
      const newSessionId = res.headers['mcp-session-id'];
      if (newSessionId) sessionId = newSessionId;

      let data = '';
      res.on('data', (chunk) => { data += chunk.toString('utf8'); });
      res.on('end', () => {
        if (res.statusCode >= 400) {
          return reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 500)}`));
        }
        if (!data) return resolve(null); // Notification — no response expected.

        const ct = (res.headers['content-type'] || '').toLowerCase();
        if (ct.includes('text/event-stream')) {
          // Parse SSE: lines starting with "data: " carry the JSON payload.
          const events = data
            .split(/\r?\n/)
            .filter((l) => l.startsWith('data: '))
            .map((l) => l.slice(6));
          if (events.length === 0) return resolve(null);
          // Take the last data event (matches StreamableHTTPTransport response shape).
          try {
            return resolve(JSON.parse(events[events.length - 1]));
          } catch (e) {
            return reject(new Error(`SSE parse error: ${e.message} — raw: ${events[events.length - 1]}`));
          }
        }
        // Plain JSON body.
        try {
          return resolve(JSON.parse(data));
        } catch (e) {
          return reject(new Error(`JSON parse error: ${e.message} — raw: ${data.slice(0, 500)}`));
        }
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

/**
 * Build a JSON-RPC error response for a given request.
 * Used when the upstream HTTP call fails — Claude Desktop expects a reply
 * for any message that had an `id` field (i.e. a request, not a notification).
 */
function makeErrorResponse(id, err) {
  return {
    jsonrpc: '2.0',
    id,
    error: {
      code: -32603, // Internal error
      message: `open-brain bridge: ${err.message}`,
    },
  };
}

// ─── Main loop ───────────────────────────────────────────────────────────────
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false,
});

rl.on('line', async (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;

  let message;
  try {
    message = JSON.parse(trimmed);
  } catch (e) {
    process.stderr.write(`[open-brain] Bad JSON on stdin: ${e.message}\n`);
    return;
  }

  try {
    const response = await sendToOB(message);
    if (response !== null) {
      process.stdout.write(JSON.stringify(response) + '\n');
    }
    // Notifications (no `id`) get no response — that's correct per JSON-RPC 2.0.
  } catch (err) {
    process.stderr.write(`[open-brain] ${err.message}\n`);
    if (message && message.id !== undefined) {
      process.stdout.write(JSON.stringify(makeErrorResponse(message.id, err)) + '\n');
    }
  }
});

rl.on('close', () => process.exit(0));

// Catch unhandled rejections — never silently die.
process.on('unhandledRejection', (err) => {
  process.stderr.write(`[open-brain] Unhandled rejection: ${err && err.message ? err.message : err}\n`);
});
