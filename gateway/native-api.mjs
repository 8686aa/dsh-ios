// native-api.mjs — read dsh sessions and drive the agent from a plain HTTP API.
// Designed for the DSHPhone iOS app: no WebSocket RPC, no browser, only JSON.
//
//   GET  /native/sessions               -> [{id,title,cwd,createdAt,turns}]
//   GET  /native/session/<id>/messages  -> [{kind,text,reasoning,tool,...}]
//   POST /native/ask {sessionId?,text}  -> NDJSON stream of run events
//
// Session storage on disk:  ~/.dsh/sessions/<workspace>/<session-id>/session.v4.jsonl.zstd
// The file is a sequence of independent zstd frames, so decoding walks frame magics.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { spawn } from 'node:child_process';

const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

/** Decode a multi-frame zstd file into its UTF-8 JSONL text. */
export function decodeZstdFile(file) {
  const buf = fs.readFileSync(file);
  const parts = [];
  let off = 0;
  while (off < buf.length) {
    const start = buf.indexOf(ZSTD_MAGIC, off);
    if (start < 0) break;
    const next = buf.indexOf(ZSTD_MAGIC, start + 4);
    const end = next < 0 ? buf.length : next;
    try {
      parts.push(zlib.zstdDecompressSync(buf.subarray(start, end)));
    } catch {
      // a frame still being appended by a live session: skip it
    }
    off = end;
  }
  return Buffer.concat(parts).toString('utf8');
}

/** Decode only the first `maxBytes` of a multi-frame zstd file (fast session summaries). */
export function decodeZstdPrefix(file, maxBytes = 256 * 1024) {
  const fd = fs.openSync(file, 'r');
  const buf = Buffer.alloc(maxBytes);
  let n = 0;
  try { n = fs.readSync(fd, buf, 0, maxBytes, 0); } finally { fs.closeSync(fd); }
  const slice = buf.subarray(0, n);
  const parts = [];
  let off = 0;
  while (off < slice.length) {
    const start = slice.indexOf(ZSTD_MAGIC, off);
    if (start < 0) break;
    const next = slice.indexOf(ZSTD_MAGIC, start + 4);
    const end = next < 0 ? slice.length : next;
    try {
      parts.push(zlib.zstdDecompressSync(slice.subarray(start, end)));
    } catch {
      break;   // truncated tail frame
    }
    off = end;
  }
  return Buffer.concat(parts).toString('utf8');
}

const summaryCache = new Map();   // file -> { mtimeMs, data }

function readSummary(file, sessionId) {
  let text = '';
  try { text = decodeZstdPrefix(file); } catch { /* unreadable */ }
  const info = { id: sessionId, title: '', cwd: '', createdAt: 0 };
  let firstUser = '';
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (e.type === 'session') {
      info.id = e.id || sessionId;
      info.cwd = e.cwd || '';
      info.createdAt = e.createdAt || 0;
    } else if (e.type === 'session/title' && e.data && e.data.title) {
      info.title = String(e.data.title);
    } else if (!firstUser && e.type === 'user/message') {
      firstUser = textOf(e.data && e.data.content).replace(/\s+/g, ' ').trim().slice(0, 60);
    }
  }
  if (!info.title) info.title = firstUser || '(新会话)';
  return info;
}

/**
 * Every session on disk, newest first.
 * Scans ~/.dsh/sessions/<workspace>/<session-id>/session.v4.jsonl.zstd and
 * decodes only the leading frames, so a 55 MB store lists in well under a second.
 */
export function listSessions(dshHome) {
  const root = path.join(dshHome, 'sessions');
  let workspaces = [];
  try {
    workspaces = fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory());
  } catch {
    return [];
  }

  const out = [];
  for (const ws of workspaces) {
    let sessions = [];
    try {
      sessions = fs.readdirSync(path.join(root, ws.name), { withFileTypes: true }).filter((d) => d.isDirectory());
    } catch { continue; }

    for (const s of sessions) {
      if (!s.name.startsWith('session-')) continue;
      const file = path.join(root, ws.name, s.name, 'session.v4.jsonl.zstd');
      let st;
      try { st = fs.statSync(file); } catch { continue; }
      if (st.size === 0) continue;

      const cached = summaryCache.get(file);
      let info;
      if (cached && cached.mtimeMs === st.mtimeMs) {
        info = cached.data;
      } else {
        info = readSummary(file, s.name);
        summaryCache.set(file, { mtimeMs: st.mtimeMs, data: info });
      }
      out.push({
        ...info,
        workspace: ws.name,
        bytes: st.size,
        updatedAt: st.mtimeMs,
      });
    }
  }
  out.sort((a, b) => b.updatedAt - a.updatedAt);
  return out;
}

/** Resolve <session-id> to its .zstd file by scanning the workspace dirs. */
export function findSessionFile(dshHome, id) {
  const root = path.join(dshHome, 'sessions');
  let dirs = [];
  try {
    dirs = fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory());
  } catch {
    return null;
  }
  for (const d of dirs) {
    const candidate = path.join(root, d.name, id, 'session.v4.jsonl.zstd');
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

const textOf = (content) =>
  (content || [])
    .filter((c) => c && c.type === 'text' && typeof c.text === 'string')
    .map((c) => c.text)
    .join('');

const reasoningOf = (content) =>
  (content || [])
    .filter((c) => c && c.type === 'reasoning' && typeof c.text === 'string')
    .map((c) => c.text)
    .join('');

/** Turn raw session events into a flat, renderable message list. */
export function normalizeMessages(jsonlText, { maxToolChars = 6000 } = {}) {
  const out = [];
  const toolIndex = new Map();
  for (const line of jsonlText.split('\n')) {
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    const d = e.data || {};
    switch (e.type) {
      case 'user/message': {
        const text = textOf(d.content);
        if (text.trim()) out.push({ kind: 'user', text, time: e.time || 0, id: d.id || '' });
        break;
      }
      case 'assistant/message': {
        const content = d.message?.content || [];
        const text = textOf(content);
        const reasoning = reasoningOf(content);
        if (text.trim() || reasoning.trim()) {
          out.push({
            kind: 'assistant',
            text,
            reasoning,
            turn: d.turn ?? 0,
            step: d.step ?? 0,
            time: e.time || 0,
          });
        }
        break;
      }
      case 'tool/call': {
        const item = {
          kind: 'tool',
          callId: d.callId || '',
          name: d.name || 'tool',
          args: typeof d.arguments === 'string' ? d.arguments : JSON.stringify(d.arguments ?? ''), 
          result: null,
          turn: d.turn ?? 0,
          step: d.step ?? 0,
          time: e.time || 0,
          status: 'running',
        };
        toolIndex.set(item.callId, item);
        out.push(item);
        break;
      }
      case 'tool/result': {
        const callId = d.toolCallId || d.message?.source?.callId || '';
        const text = textOf(d.message?.content);
        const hit = toolIndex.get(callId);
        const trimmed = text.length > maxToolChars ? text.slice(0, maxToolChars) + '\n… (truncated)' : text;
        if (hit) { hit.result = trimmed; hit.status = 'done'; }
        else out.push({ kind: 'tool', callId, name: 'tool', args: '', result: trimmed, time: e.time || 0, status: 'done' });
        break;
      }
      case 'turn/end': {
        out.push({ kind: 'turn_end', turn: d.turn ?? 0, reason: d.reason?.kind || 'completed', time: e.time || 0 });
        break;
      }
      default:
        break;
    }
  }
  return out;
}

/** Read and normalize one session's messages. */
export function readMessages(dshHome, id) {
  const file = findSessionFile(dshHome, id);
  if (!file) return null;
  const text = decodeZstdFile(file);
  const meta = (() => {
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      try {
        const e = JSON.parse(line);
        if (e.type === 'session') return { id: e.id, cwd: e.cwd, createdAt: e.createdAt };
      } catch { /* ignore */ }
    }
    return { id, cwd: '', createdAt: 0 };
  })();
  return { ...meta, messages: normalizeMessages(text) };
}

/** Pull DEEPSEEK_API_KEY (or any provider key) out of the credentials store. */
export function readCredentialRefs(dshHome) {
  const file = path.join(dshHome, '.credentials.yaml');
  const refs = {};
  let raw = '';
  try { raw = fs.readFileSync(file, 'utf8'); } catch { return refs; }
  let inRefs = false;
  for (const line of raw.split(/\r?\n/)) {
    if (/^refs:\s*$/.test(line)) { inRefs = true; continue; }
    if (/^\S/.test(line)) { inRefs = false; continue; }
    if (!inRefs) continue;
    const m = line.match(/^\s+([A-Za-z0-9_]+)\s*:\s*(.+?)\s*$/);
    if (m) refs[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return refs;
}

/**
 * Run one agent turn for a session and stream normalized events.
 * Calls onEvent({type, ...}) as data arrives, then onEnd({code}).
 */
export function ask({ dshHome, dshBin, nodeBin, sessionId, text, onEvent, onEnd }) {
  const refs = readCredentialRefs(dshHome);
  const env = { ...process.env, DSH_HOME: dshHome };
  if (refs.DEEPSEEK_API_KEY) env.DEEPSEEK_API_KEY = refs.DEEPSEEK_API_KEY;
  for (const [k, v] of Object.entries(refs)) {
    if (/^[A-Z0-9_]+$/.test(k) && k !== 'DEEPSEEK_API_KEY') env[k] = v;
  }

  const args = [dshBin, 'headless', '--json'];
  if (sessionId) args.push('--session-id', sessionId);
  args.push(text);

  const child = spawn(nodeBin, args, {
    cwd: dshHome,
    env,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let buf = '';
  let stderr = '';
  const newSessionId = () => sessionId || null;

  child.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      let evt;
      try { evt = JSON.parse(line); } catch { continue; }
      switch (evt.type) {
        case 'session':
          onEvent({ type: 'session', sessionId: evt.sessionId, cwd: evt.cwd });
          break;
        case 'status':
          onEvent({ type: 'status', phase: evt.phase, turn: evt.turn, step: evt.step, reason: evt.reason });
          break;
        case 'final':
          onEvent({ type: 'final', text: evt.text ?? '' });
          break;
        default:
          onEvent({ type: evt.type || 'event', data: evt });
      }
    }
  });

  child.stderr.on('data', (chunk) => {
    const s = chunk.toString('utf8');
    stderr += s;
    for (const line of s.split('\n')) {
      if (line.trim()) onEvent({ type: 'log', text: line.trim().slice(0, 600) });
    }
  });

  child.on('exit', (code) => {
    const tail = buf.trim();
    if (tail) {
      try { onEvent({ type: 'raw', data: JSON.parse(tail) }); } catch { onEvent({ type: 'log', text: tail.slice(0, 600) }); }
    }
    onEnd({ code: code ?? -1, sessionId: newSessionId(), stderr: stderr.slice(-2000) });
  });

  child.on('error', (e) => {
    onEvent({ type: 'log', text: 'spawn failed: ' + e.message });
    onEnd({ code: -1, sessionId: newSessionId(), stderr: e.message });
  });

  return () => { try { child.kill(); } catch { /* ignore */ } };
}
