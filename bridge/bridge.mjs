// OpenAI-compatible bridge over `opencode serve` v2 (routes under /api, basic auth,
// prompt + poll instead of a single POST that returns the reply).
// Adapted from raksix/opencode-free-bridge (written for the pre-/api release).
//
// env: OPENCODE_UPSTREAM (default 127.0.0.1:4600), OPENCODE_PASSWORD, PORT (default 5577)

import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PW_FILE = join(HERE, 'serve_password');

// opencode 2.x ignores OPENCODE_SERVER_PASSWORD and prints a random password at
// startup, so run-serve.sh captures it into serve_password. Read it per request:
// the bridge may start before serve, and serve's password changes on every restart.
function password() {
  if (process.env.OPENCODE_PASSWORD) return process.env.OPENCODE_PASSWORD;
  if (existsSync(PW_FILE)) return readFileSync(PW_FILE, 'utf8').trim();
  return '';
}

const UPSTREAM = process.env.OPENCODE_UPSTREAM || 'http://127.0.0.1:4600';
const PORT = parseInt(process.env.PORT || '5577', 10);
const POLL_MS = 500;
const TIMEOUT_MS = parseInt(process.env.BRIDGE_TIMEOUT_MS || '300000', 10);

const H = () => ({
  authorization: 'Basic ' + Buffer.from('opencode:' + password()).toString('base64'),
  'content-type': 'application/json',
});

const sessions = new Map();          // model -> sessionId
const sessionLocks = new Map();      // model -> Promise
let freeModelIds = [];

async function oc(path, opts = {}) {
  const res = await fetch(UPSTREAM + path, { ...opts, headers: H() });
  const text = await res.text();
  if (!res.ok) {
    // serve restarts rotate the password, which 401s every call and invalidates the
    // cached session; drop it so the next attempt starts clean instead of looping.
    if (res.status === 401) sessions.clear();
    throw new Error(`${opts.method || 'GET'} ${path} -> ${res.status}: ${text.slice(0, 200)}`);
  }
  return text ? JSON.parse(text) : null;
}

async function refreshModels() {
  const d = await oc('/api/model');
  freeModelIds = (d.data || [])
    .map((m) => m.id)
    .filter((id) => id.includes('free'));
  return freeModelIds;
}

// opencode pins a model onto a session; a session whose model has since been
// delisted fails permanently. Key the cache by model so each gets its own session.
async function getSession(modelId) {
  if (sessions.has(modelId)) return sessions.get(modelId);
  if (sessionLocks.has(modelId)) return sessionLocks.get(modelId);
  const p = (async () => {
    const d = await oc('/api/session', { method: 'POST', body: '{}' });
    sessions.set(modelId, d.data.id);
    return d.data.id;
  })();
  sessionLocks.set(modelId, p);
  try { return await p; } finally { sessionLocks.delete(modelId); }
}

function setModel(sid, modelId) {
  return oc(`/api/session/${sid}/model`, {
    method: 'POST',
    // v2 composes the id from providerID+modelID; supplying a pre-joined id doubles
    // the prefix and the server reports `Model unavailable: opencode/opencode/<id>`.
    body: JSON.stringify({ model: { providerID: 'opencode', modelID: modelId, id: modelId } }),
  });
}

function prompt(sid, text) {
  return oc(`/api/session/${sid}/prompt`, { method: 'POST', body: JSON.stringify({ text }) });
}

function messages(sid) {
  return oc(`/api/session/${sid}/message`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// v2 has no one-shot reply: post the prompt, then poll until this turn's assistant
// message appears alongside a settled idle marker.
async function complete(sid, modelId, text) {
  // Index by id, not array position: opencode inserts this turn's messages anywhere in
  // the list, so slicing by prior length can miss them and hang until the timeout.
  const seen = new Set(((await messages(sid)).data || []).map((m) => m.id));
  await setModel(sid, modelId);
  await prompt(sid, text);

  // A delisted model fails this way; drop the session so the next call retries on a
  // fresh one instead of replaying the same poisoned session forever.
  const abandon = () => sessions.delete(modelId);

  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_MS);
    const rows = (await messages(sid)).data || [];
    const fresh = rows.filter((m) => m.id && !seen.has(m.id));
    const idle = fresh.filter((m) => m.type === 'idle').pop();
    if (idle && idle.outcome !== 'succeeded') {
      abandon();
      throw new Error(`opencode turn failed: ${JSON.stringify(idle.error || {})}`);
    }
    const asst = fresh.filter((m) => m.type === 'assistant').pop();
    if (asst && idle && idle.outcome === 'succeeded') {
      const content = (asst.content || [])
        .filter((c) => c.type === 'text')
        .map((c) => c.text)
        .join('');
      return { content, cost: asst.cost ?? 0, tokens: asst.tokens || {}, model: modelId };
    }
  }
  throw new Error(`timeout after ${TIMEOUT_MS}ms waiting for ${modelId}`);
}

// Flatten OpenAI messages into one text prompt: v2 /prompt takes a single string.
function flatten(messages) {
  const parts = [];
  for (const m of messages || []) {
    const role = m.role || 'user';
    let c = m.content;
    if (Array.isArray(c)) c = c.map((p) => (typeof p === 'string' ? p : p.text || '')).join('');
    if (c) parts.push(`[${role}]\n${c}`);
  }
  return parts.join('\n\n');
}

function json(res, code, obj) {
  const b = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(b) });
  res.end(b);
}

const sse = (res, o) => res.write(`data: ${typeof o === 'string' ? o : JSON.stringify(o)}\n\n`);

async function chatCompletions(req, res) {
  let raw = '';
  for await (const c of req) raw += c;
  let body;
  try { body = JSON.parse(raw); } catch { return json(res, 400, { error: { message: 'invalid json' } }); }

  const requested = String(body.model || '').replace(/^opencode\//, '');
  if (!freeModelIds.length) await refreshModels();
  if (!freeModelIds.includes(requested)) {
    return json(res, 404, { error: { message: `unknown model '${body.model}'. free models: ${freeModelIds.join(', ')}` } });
  }

  const text = flatten(body.messages);
  const stream = !!body.stream;
  const cid = `chatcmpl-${Date.now()}`;
  const created = Math.floor(Date.now() / 1000);

  try {
    const sid = await getSession(requested);
    if (stream) {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache', Connection: 'keep-alive', 'X-Accel-Buffering': 'no',
      });
      sse(res, { id: cid, object: 'chat.completion.chunk', created, model: requested,
                 choices: [{ index: 0, delta: { role: 'assistant' }, finish_reason: null }] });
    }
    const out = await complete(sid, requested, text);
    const t = out.tokens || {};
    const usage = { prompt_tokens: t.input || 0, completion_tokens: t.output || 0, total_tokens: t.total || (t.input || 0) + (t.output || 0) };

    if (stream) {
      for (const chunk of out.content.match(/.{1,40}/gs) || []) {
        sse(res, { id: cid, object: 'chat.completion.chunk', created, model: requested,
                   choices: [{ index: 0, delta: { content: chunk }, finish_reason: null }] });
      }
      sse(res, { id: cid, object: 'chat.completion.chunk', created, model: requested,
                 choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage });
      sse(res, '[DONE]');
      res.end();
    } else {
      json(res, 200, {
        id: cid, object: 'chat.completion', created, model: requested,
        choices: [{ index: 0, message: { role: 'assistant', content: out.content }, finish_reason: 'stop' }],
        usage,
      });
    }
  } catch (e) {
    const msg = String(e.message || e);
    if (stream) { sse(res, { error: { message: msg } }); sse(res, '[DONE]'); res.end(); }
    else json(res, 502, { error: { message: msg } });
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  if (url.pathname === '/healthz') return json(res, 200, { ok: true, upstream: UPSTREAM, free: freeModelIds.length });
  if (url.pathname === '/v1/models') {
    try { if (!freeModelIds.length) await refreshModels(); }
    catch (e) { return json(res, 502, { error: { message: String(e.message || e) } }); }
    return json(res, 200, { object: 'list', data: freeModelIds.map((id) => ({ id, object: 'model', created: 1700000000, owned_by: 'opencode-free', free: true })) });
  }
  if (url.pathname === '/v1/chat/completions' && req.method === 'POST') return chatCompletions(req, res);
  json(res, 404, { error: { message: 'not found' } });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`bridge on http://127.0.0.1:${PORT} -> ${UPSTREAM}`);
  refreshModels().then((m) => console.log(`free models: ${m.length} -> ${m.join(', ')}`)).catch((e) => console.error('discovery:', e.message));
});
