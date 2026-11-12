// mdns-announce.mjs — zero-dependency mDNS/Bonjour responder for the dsh gateway.
// Announces:
//   PTR  _dsh._tcp.local            -> <instance>
//   SRV  <instance>                 -> <host>.local:<port>
//   TXT  <instance>                 key=..., name=..., ver=...
//   A    <host>.local               every non-loopback IPv4
// No npm package, no external process. Safe to fail: the iOS app also sweeps the /24.
import dgram from 'node:dgram';
import os from 'node:os';

const GROUP = '224.0.0.251';
const MDNS_PORT = 5353;
const T_A = 1, T_PTR = 12, T_TXT = 16, T_SRV = 33, T_ANY = 255;
const CLASS_IN = 1;
const CACHE_FLUSH = 0x8000;

function sanitizeLabel(s) {
  const cleaned = String(s || '').replace(/[^A-Za-z0-9-]/g, '-').replace(/^-+|-+$/g, '');
  return cleaned.slice(0, 40) || 'dsh';
}

function encodeName(name) {
  const out = [];
  for (const part of name.split('.').filter(Boolean)) {
    const b = Buffer.from(part, 'utf8');
    out.push(Buffer.from([b.length]), b);
  }
  out.push(Buffer.from([0]));
  return Buffer.concat(out);
}

function readName(buf, offset) {
  const labels = [];
  let off = offset;
  let guard = 0;
  while (off < buf.length && guard++ < 64) {
    const len = buf[off];
    if (len === 0) { off += 1; break; }
    if ((len & 0xc0) === 0xc0) { off += 2; break; }   // compression pointer: stop here
    labels.push(buf.slice(off + 1, off + 1 + len).toString('utf8'));
    off += 1 + len;
  }
  return { name: labels.join('.').toLowerCase(), next: off };
}

function rr(name, type, ttl, rdata, flush = false) {
  const head = Buffer.alloc(10);
  head.writeUInt16BE(type, 0);
  head.writeUInt16BE(CLASS_IN | (flush ? CACHE_FLUSH : 0), 2);
  head.writeUInt32BE(ttl, 4);
  head.writeUInt16BE(rdata.length, 8);
  return Buffer.concat([encodeName(name), head, rdata]);
}

function srvRdata(port, target) {
  const b = Buffer.alloc(6);
  b.writeUInt16BE(0, 0);
  b.writeUInt16BE(0, 2);
  b.writeUInt16BE(port, 4);
  return Buffer.concat([b, encodeName(target)]);
}

function txtRdata(pairs) {
  const bufs = [];
  for (const [k, v] of Object.entries(pairs)) {
    const s = Buffer.from(`${k}=${v ?? ''}`, 'utf8');
    if (s.length > 255) continue;
    bufs.push(Buffer.from([s.length]), s);
  }
  return Buffer.concat(bufs);
}

function ipv4ToBuf(ip) {
  return Buffer.from(ip.split('.').map((n) => Number(n) & 0xff));
}

function buildAnnouncement({ instance, service, host, port, ips, txt, ttl }) {
  const records = [
    rr(service, T_PTR, ttl, encodeName(instance)),
    rr(instance, T_SRV, ttl, srvRdata(port, host), true),
    rr(instance, T_TXT, ttl, txtRdata(txt), true),
  ];
  for (const ip of ips) records.push(rr(host, T_A, ttl, ipv4ToBuf(ip), true));

  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0);          // id
  header.writeUInt16BE(0x8400, 2);     // QR + AA
  header.writeUInt16BE(0, 4);          // qdcount
  header.writeUInt16BE(records.length, 6);
  header.writeUInt16BE(0, 8);
  header.writeUInt16BE(0, 10);
  return Buffer.concat([header, ...records]);
}

function questionNames(buf) {
  if (buf.length < 12) return [];
  const qd = buf.readUInt16BE(4);
  let off = 12;
  const out = [];
  for (let i = 0; i < qd && off < buf.length; i++) {
    const { name, next } = readName(buf, off);
    if (next + 4 > buf.length) break;
    out.push({ name, type: buf.readUInt16BE(next) });
    off = next + 4;
  }
  return out;
}

export function localIPv4s() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.address.startsWith('169.254.')) continue;
      out.push(a.address);
    }
  }
  return out;
}

/**
 * Start announcing. Returns { stop } or null when mDNS is unavailable.
 * @param {{ port:number, key?:string, name?:string, log?:(...a:any[])=>void }} opts
 */
export function startMdns(opts) {
  const log = opts.log || (() => { });
  const hostLabel = sanitizeLabel(os.hostname());
  const service = '_dsh._tcp.local';
  const host = `${hostLabel}.local`;
  const instance = `${hostLabel}-${opts.port}.${service}`;
  const txt = {
    key: opts.key || '',
    name: os.hostname(),
    ver: '1',
    path: '/',
  };

  let sock;
  try {
    sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  } catch (e) {
    log('mdns: socket creation failed', e.message);
    return null;
  }

  let closed = false;
  let timer = null;
  let lastAnswer = 0;

  const payload = () => buildAnnouncement({
    instance, service, host,
    port: opts.port,
    ips: localIPv4s(),
    txt,
    ttl: 120,
  });

  const multicast = (buf) => {
    if (closed) return;
    // Windows routes multicast out the default interface only; emit once per NIC
    // so a phone on the Wi-Fi subnet still hears a gateway whose default route is Ethernet.
    const ifaces = localIPv4s();
    if (ifaces.length === 0) {
      try { sock.send(buf, 0, buf.length, MDNS_PORT, GROUP); } catch { }
      return;
    }
    for (const ip of ifaces) {
      try {
        sock.setMulticastInterface(ip);
        sock.send(buf, 0, buf.length, MDNS_PORT, GROUP);
      } catch { }
    }
  };

  sock.on('error', (e) => {
    log('mdns: error', e.message);
    try { sock.close(); } catch { }
    closed = true;
    if (timer) clearInterval(timer);
  });

  sock.on('message', (msg) => {
    if (closed) return;
    const qs = questionNames(msg);
    const wants = qs.some((q) =>
      q.name === service || q.name === instance || q.name === host ||
      q.name === '' /* ANY */ || q.type === T_ANY);
    if (!wants) return;
    const now = Date.now();
    if (now - lastAnswer < 400) return;       // rate limit replies
    lastAnswer = now;
    multicast(payload());
  });

  sock.bind(MDNS_PORT, () => {
    try {
      sock.addMembership(GROUP);
      sock.setMulticastTTL(255);
      sock.setMulticastLoopback(true);
    } catch (e) {
      log('mdns: membership failed', e.message);
    }
    log(`mdns: announcing ${instance} -> ${host}:${opts.port} [${localIPv4s().join(', ')}]`);
    payload() && multicast(payload());
    setTimeout(() => multicast(payload()), 1200);
    timer = setInterval(() => multicast(payload()), 60_000);
    if (timer.unref) timer.unref();
  });

  return {
    stop() {
      closed = true;
      if (timer) clearInterval(timer);
      try { sock.dropMembership(GROUP); } catch { }
      try { sock.close(); } catch { }
    },
  };
}
