// dsh-phone-proxy.mjs
// Phone gateway for DeepSeek Harness (LAN only).
//   backend : dsh web  127.0.0.1:20202   (loopback only, started by this script)
//   gateway : 0.0.0.0:80 and 0.0.0.0:8080 (every LAN adapter, one fixed access key)
//
// Browser side: open http://<lan-ip>/ or http://<lan-ip>:8080/ with ?k=<KEY> once.
//   /__ping  -> plain text liveness probe (no auth, tells you the network works)
// The gateway rewrites Host to loopback (passes dsh's Host fence + cookie
// authority), strips Origin/Referer, and injects the backend session cookie,
// so the phone never sees a dsh token and never needs /connect.
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execSync } from 'node:child_process';
import { startMdns } from './mdns-announce.mjs';

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const DSH_BIN = process.env.DSH_BIN ||
  'C:\\Users\\Administrator\\AppData\\Local\\Programs\\DeepSeek Harness\\resources\\app\\dsh\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js';
const PROFILE_DIR = path.join(DSH_HOME, 'profiles', 'web');
const BACK_HOST = '127.0.0.1';
const BACK_PORT = Number(process.env.DSH_BACK_PORT || 20202);
const PORTS = String(process.env.DSH_PHONE_PORTS || '80,8080')
  .split(',').map((s) => Number(s.trim())).filter((n) => Number.isInteger(n) && n > 0 && n < 65536);
const KEY_FILE = path.join(DSH_HOME, '.phone-key');
const LOG_DIR = path.join(DSH_HOME, 'logs');

if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

// ---------- access key ----------
let KEY;
try { KEY = fs.readFileSync(KEY_FILE, 'utf8').trim(); } catch { }
if (!KEY || KEY.length < 12) {
  KEY = crypto.randomBytes(12).toString('base64url');   // 16 chars
  fs.writeFileSync(KEY_FILE, KEY, { mode: 0o600 });
}

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

// ---------- kill leftovers on the backend port ----------
function killPort(port) {
  try {
    const out = execSync('netstat -ano -p tcp', { encoding: 'utf8', windowsHide: true });
    const pids = new Set();
    for (const line of out.split(/\r?\n/)) {
      const m = line.trim().match(/^TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)$/i);
      if (m && Number(m[1]) === port) pids.add(m[2]);
    }
    for (const pid of pids) {
      try { execSync(`taskkill /PID ${pid} /F`, { windowsHide: true, stdio: 'ignore' }); log('killed pid', pid, 'on port', port); } catch { }
    }
  } catch { }
}

// ---------- backend ----------
function startBackend() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [DSH_BIN, '--profile', 'web', '--host', BACK_HOST, '--port', String(BACK_PORT), '--no-open'], {
      cwd: PROFILE_DIR,
      env: { ...process.env, DSH_HOME, DSH_PROFILE: 'web', DSH_PROFILE_DIR: PROFILE_DIR },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    let buf = '';
    let done = false;
    const timer = setTimeout(() => { if (!done) { done = true; reject(new Error('backend start timeout')); } }, 120000);
    child.stdout.on('data', (d) => {
      buf += d.toString();
      process.stdout.write('[dsh] ' + d.toString());
      const m = buf.match(/http:\/\/\S+\?token=([A-Za-z0-9_-]+)/);
      if (m && !done) { done = true; clearTimeout(timer); resolve({ child, token: m[1] }); }
    });
    child.stderr.on('data', (d) => process.stdout.write('[dsh:err] ' + d.toString()));
    child.on('exit', (c) => {
      log('backend exited', c);
      if (!done) { done = true; clearTimeout(timer); reject(new Error('backend exited ' + c)); }
      else process.exit(1);
    });
  });
}

function fetchBackendCookie(token) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: BACK_HOST, port: BACK_PORT, method: 'GET',
      path: '/?token=' + encodeURIComponent(token),
      headers: { host: BACK_HOST + ':' + BACK_PORT },
    }, (res) => {
      res.resume();
      const sc = res.headers['set-cookie'];
      if (!sc || !sc.length) return reject(new Error('backend returned no set-cookie'));
      resolve(sc[0].split(';')[0]);
    });
    req.on('error', reject);
    req.end();
  });
}

// ---------- gateway ----------
function parseCookies(header) {
  const out = {};
  for (const seg of String(header || '').split(';')) {
    const at = seg.indexOf('=');
    if (at === -1) continue;
    out[seg.slice(0, at).trim()] = seg.slice(at + 1).trim();
  }
  return out;
}

const LOGIN_HTML = (key) => `<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>dsh phone</title>
<style>body{font:16px/1.6 -apple-system,system-ui,sans-serif;margin:0;padding:28px;background:#151517;color:#e8e8ea}
h1{font-size:18px;margin:0 0 14px}input{width:100%;box-sizing:border-box;padding:12px;border-radius:10px;border:1px solid #3a3a40;background:#1e1e22;color:#fff;font-size:16px}
button{margin-top:12px;width:100%;padding:12px;border:0;border-radius:10px;background:#4d6bfe;color:#fff;font-size:16px}
p{color:#9a9aa2;font-size:13px}code{background:#26262b;padding:2px 6px;border-radius:5px}</style>
<h1>dsh 手机接入</h1>
<form method="get" action="/"><input name="k" placeholder="access key" autofocus autocapitalize="off" autocorrect="off"><button>进入</button></form>
<p>网络已通（能看到这个框就说明手机和电脑在同一个局域网）。首次请用带 key 的链接，或手输密钥。</p>`;

function createGateway(backendCookie) {
  const server = http.createServer((req, res) => {
    let u;
    try { u = new URL(req.url, 'http://x'); } catch { res.writeHead(400).end(); return; }

    if (!/\.(js|css|svg|png|ico|woff2?|map|webmanifest)$/i.test(u.pathname)) {
      log('req   ' + (req.socket.remoteAddress || '?') + ' ' + req.method + ' ' + String(req.url).slice(0, 100) +
          ' host=' + (req.headers.host || '?'));
    }

    // unauthenticated liveness probe: proves the LAN path works
    if (u.pathname === '/__ping') {
      const fmt = u.searchParams.get('fmt');
      if (fmt === 'json' || String(req.headers.accept || '').includes('application/json')) {
        const body = {
          service: 'dsh-phone-gateway',
          name: os.hostname(),
          version: '1',
          os: 'windows',
          ports: PORTS,
          key: process.env.DSH_PING_HIDE_KEY === '1' ? '' : KEY,
        };
        res.writeHead(200, {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          'access-control-allow-origin': '*',
        });
        res.end(JSON.stringify(body));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
      res.end([
        'ok',
        'client=' + (req.socket.remoteAddress || '?'),
        'host=' + (req.headers.host || '?'),
        'port=' + (req.socket.localPort || '?'),
        'time=' + new Date().toISOString(),
        'ua=' + (req.headers['user-agent'] || '?'),
        '',
      ].join('\n'));
      return;
    }

    const k = u.searchParams.get('k');
    if (k === KEY) {
      res.writeHead(302, {
        'cache-control': 'no-store',
        'set-cookie': `dshphone=${KEY}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax`,
        location: './',
      });
      res.end();
      return;
    }
    if (parseCookies(req.headers.cookie).dshphone !== KEY) {
      res.writeHead(401, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(LOGIN_HTML(KEY));
      return;
    }

    const headers = { ...req.headers };
    delete headers.origin;
    delete headers.referer;
    delete headers['x-forwarded-for'];
    headers.host = BACK_HOST + ':' + BACK_PORT;
    headers.cookie = backendCookie;

    const up = http.request({
      host: BACK_HOST, port: BACK_PORT, method: req.method, path: req.url, headers,
    }, (r) => {
      const h = { ...r.headers };
      delete h['set-cookie'];
      res.writeHead(r.statusCode, h);
      r.pipe(res);
    });
    up.on('error', (e) => {
      log('upstream error', e.message);
      try { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('bad gateway: ' + e.message); } catch { }
    });
    req.pipe(up);
  });

  server.on('upgrade', (req, socket, head) => {
    if (parseCookies(req.headers.cookie).dshphone !== KEY) { socket.destroy(); return; }
    const up = net.connect(BACK_PORT, BACK_HOST, () => {
      const lines = [`${req.method} ${req.url} HTTP/1.1`];
      let hadCookie = false;
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        const name = req.rawHeaders[i];
        const value = req.rawHeaders[i + 1];
        const ln = name.toLowerCase();
        if (ln === 'host') lines.push(`Host: ${BACK_HOST}:${BACK_PORT}`);
        else if (ln === 'origin' || ln === 'referer') continue;
        else if (ln === 'cookie') { lines.push(`Cookie: ${backendCookie}`); hadCookie = true; }
        else lines.push(`${name}: ${value}`);
      }
      if (!hadCookie) lines.push(`Cookie: ${backendCookie}`);
      lines.push('', '');
      up.write(lines.join('\r\n'));
      if (head && head.length) up.write(head);
      up.pipe(socket);
      socket.pipe(up);
    });
    up.on('error', () => socket.destroy());
    socket.on('error', () => up.destroy());
    socket.on('close', () => up.destroy());
  });

  return server;
}

function lanAddresses() {
  const out = [];
  for (const [iface, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.address.startsWith('169.254.')) continue;
      out.push({ iface, address: a.address });
    }
  }
  return out;
}

// ---------- main ----------
(async () => {
  killPort(BACK_PORT);
  log('starting backend on', BACK_HOST + ':' + BACK_PORT);
  const { token } = await startBackend();
  log('backend up, exchanging launch token');
  const backendCookie = await fetchBackendCookie(token);
  log('session cookie acquired:', backendCookie.split('=')[0]);

  const bound = [];
  let pending = PORTS.length;
  for (const port of PORTS) {
    // one independent server per port: net.Server multi-listen is unreliable on Windows
    const srv = createGateway(backendCookie);
    srv.on('connection', (sock) => {
      log('conn  ' + (sock.remoteAddress || '?') + ':' + (sock.remotePort || 0) + ' -> :' + port);
      sock.on('close', () => log('close ' + (sock.remoteAddress || '?') + ' :' + port));
      sock.on('error', () => { });
    });
    srv.on('error', (e) => {
      log('port ' + port + ' unavailable: ' + e.message);
      if (--pending === 0) announce();
    });
    srv.listen(port, '0.0.0.0', () => {
      bound.push(port);
      log('gateway listening on 0.0.0.0:' + port);
      if (--pending === 0) announce();
    });
  }

  function announce() {
    const addrs = lanAddresses();
    const primary = bound.includes(80) ? 80 : bound[0];
    const suffix = primary === 80 ? '' : ':' + primary;
    console.log('');
    console.log('=== dsh phone gateway ready ===');
    console.log('access key =', KEY);
    console.log('ports      =', bound.join(','));
    for (const a of addrs) {
      console.log(`URL  [${a.iface}]  http://${a.address}${suffix}/?k=${KEY}`);
    }
    for (const port of bound) {
      if (port === primary) continue;
      for (const a of addrs) {
        console.log(`ALT  [${a.iface}]  http://${a.address}:${port}/?k=${KEY}`);
      }
    }
    for (const a of addrs) {
      console.log(`PING [${a.iface}]  http://${a.address}${suffix}/__ping`);
    }
    console.log('backend    =', `http://${BACK_HOST}:${BACK_PORT}`);
    try {
      startMdns({ port: primary, key: KEY, log });
      console.log('bonjour    =', `_dsh._tcp  (advertised on port ${primary})`);
    } catch (e) {
      console.log('bonjour    = unavailable (' + e.message + ')');
    }
    console.log('');
  }
})().catch((e) => { log('fatal', e.message); process.exit(1); });
