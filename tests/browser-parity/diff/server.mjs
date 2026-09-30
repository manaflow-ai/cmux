// Fixture server for the differential harness (tests/browser-parity/diff).
//
// One HTTP server on 127.0.0.1:PORT is the primary origin every backend uses
// (ChatGPT's approved scope is exactly that origin). The same server under
// `localhost:PORT` is a second site for cross-origin frames and cookie
// isolation. An HTTPS server with a throwaway self-signed certificate and a
// port that refuses connections serve the TLS and connection edge cases.
// Nothing here reaches the network.
import http from "node:http";
import https from "node:https";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixturesDir = path.join(here, "fixtures");
const parityFixtures = path.join(here, "..", "fixtures");

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".json": "application/json", ".css": "text/css" };

// Digest auth (RFC 7616, MD5, qop=auth) for user "parity", password "secret".
const REALM = "parity";
const md5 = (s) => crypto.createHash("md5").update(s).digest("hex");
function digestOk(header, method) {
  if (!header || !header.startsWith("Digest ")) return false;
  const f = {};
  for (const m of header.slice(7).matchAll(/(\w+)=(?:"([^"]*)"|([^,\s]*))/g)) f[m[1]] = m[2] ?? m[3];
  if (f.username !== "parity") return false;
  const ha1 = md5(`parity:${REALM}:secret`);
  const ha2 = md5(`${method}:${f.uri}`);
  const expect = f.qop ? md5(`${ha1}:${f.nonce}:${f.nc}:${f.cnonce}:${f.qop}:${ha2}`) : md5(`${ha1}:${f.nonce}:${ha2}`);
  return expect === f.response;
}

// Minimal RFC 6455 echo: text frames up to 64 KiB, server frames unmasked.
function websocketEcho(req, socket) {
  const accept = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const frame = (text) => {
    const payload = Buffer.from(text);
    const head = payload.length < 126 ? Buffer.from([0x81, payload.length]) : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 255]);
    return Buffer.concat([head, payload]);
  };
  let buf = Buffer.alloc(0);
  socket.on("data", (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 2) {
      const op = buf[0] & 0x0f;
      let len = buf[1] & 0x7f;
      let at = 2;
      if (len === 126) {
        len = buf.readUInt16BE(2);
        at = 4;
      }
      const masked = buf[1] & 0x80;
      if (buf.length < at + (masked ? 4 : 0) + len) return;
      const mask = masked ? buf.subarray(at, at + 4) : null;
      at += masked ? 4 : 0;
      const data = Buffer.from(buf.subarray(at, at + len));
      if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
      buf = buf.subarray(at + len);
      if (op === 8) return socket.end(Buffer.from([0x88, 0]));
      if (op === 1) socket.write(frame(`echo:${data.toString()}`));
    }
  });
  socket.on("error", () => {});
}

function selfSignedCert() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "brepl-diff-tls-"));
  const key = path.join(dir, "key.pem");
  const cert = path.join(dir, "cert.pem");
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", key, "-out", cert], { stdio: "ignore" });
  const out = { key: fs.readFileSync(key), cert: fs.readFileSync(cert) };
  fs.rmSync(dir, { recursive: true, force: true });
  return out;
}

function handler(ctx) {
  return async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const p = url.pathname;
    const send = (status, type, body, headers = {}) => {
      res.writeHead(status, { "content-type": type, "cache-control": "no-store", ...headers });
      res.end(body);
    };
    const html = (status, title, body, headers) => send(status, TYPES[".html"], `<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><title>${title}</title>${body}`, headers);
    ctx.hits.push(`${req.method} ${p}`);
    if (p === "/favicon.ico") return send(204, "image/x-icon", "");
    if (p === "/auth/basic") {
      const ok = req.headers.authorization === `Basic ${Buffer.from("parity:secret").toString("base64")}`;
      if (!ok) return html(401, "Unauthorized", "<h1>401 basic</h1>", { "www-authenticate": `Basic realm="${REALM}"` });
      return html(200, "Authed", "<h1>Authed as parity</h1>");
    }
    if (p === "/auth/digest") {
      if (!digestOk(req.headers.authorization, req.method)) {
        const nonce = crypto.randomBytes(8).toString("hex");
        return html(401, "Unauthorized", "<h1>401 digest</h1>", { "www-authenticate": `Digest realm="${REALM}", qop="auth", nonce="${nonce}", algorithm=MD5` });
      }
      return html(200, "Authed", "<h1>Digest authed as parity</h1>");
    }
    if (p === "/status/404") return html(404, "Missing", "<h1>Not here</h1>");
    if (p === "/status/500") return html(500, "Broken", "<h1>Server error</h1>");
    if (p === "/redirect-loop") return send(302, "text/plain", "", { location: "/redirect-loop" });
    if (p === "/redirect") return send(302, "text/plain", "", { location: url.searchParams.get("to") || "/diff/next.html" });
    if (p === "/slow") {
      await new Promise((r) => setTimeout(r, Number(url.searchParams.get("ms") ?? 2000)));
      return html(200, "Slow", "<h1>Slow page loaded</h1>");
    }
    if (p === "/hang") {
      // Headers and a heading arrive, the body never ends: load never fires.
      res.writeHead(200, { "content-type": TYPES[".html"], "cache-control": "no-store" });
      res.write('<!doctype html><meta charset="utf-8"><title>Hanging</title><h1>Partial content</h1><button id="b" onclick="this.textContent=\'pressed\'">Press</button>');
      ctx.hanging.add(res);
      req.on("close", () => ctx.hanging.delete(res));
      return;
    }
    if (p === "/download/cd") {
      return send(200, "application/octet-stream", `cd body ${url.searchParams.get("n") || ""}\n`, { "content-disposition": `attachment; filename="cd-${url.searchParams.get("n") || "file"}.txt"` });
    }
    if (p === "/download/slow") {
      await new Promise((r) => setTimeout(r, Number(url.searchParams.get("ms") ?? 800)));
      return send(200, "application/octet-stream", `slow body ${url.searchParams.get("n")}\n`, { "content-disposition": `attachment; filename="slow-${url.searchParams.get("n")}.txt"` });
    }
    if (p === "/download/post" && req.method === "POST") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const form = new URLSearchParams(Buffer.concat(chunks).toString());
      return send(200, "text/csv", `name,value\nq,${form.get("q")}\n`, { "content-disposition": 'attachment; filename="posted.csv"' });
    }
    if (p === "/cookies/set") {
      return html(200, "Cookies set", "<h1>cookies set</h1><script>document.cookie='js_cookie=1; path=/'</script>", {
        "set-cookie": [
          "plain=1; Path=/",
          "http_only=1; Path=/; HttpOnly",
          "secure_flag=1; Path=/; Secure",
          "strict=1; Path=/; SameSite=Strict",
          "lax=1; Path=/; SameSite=Lax",
          "none_secure=1; Path=/; SameSite=None; Secure",
        ],
      });
    }
    if (p === "/cookies/set-domain") {
      const domain = req.headers.host.replace(/:\d+$/, "").split(".").slice(-2).join(".");
      return html(200, "Domain cookie", "<h1>domain cookie set</h1>", { "set-cookie": [`dom=1; Domain=${domain}; Path=/`, "host_only=1; Path=/"] });
    }
    if (p === "/cookies/echo") {
      const names = (req.headers.cookie || "").split(/;\s*/).filter(Boolean).map((c) => c.split("=")[0]).sort();
      if (url.searchParams.has("html")) return html(200, "Cookie echo", `<pre id="names">${JSON.stringify({ host: req.headers.host.replace(/:\d+$/, ""), names })}</pre>`);
      return send(200, "application/json", JSON.stringify({ host: req.headers.host.replace(/:\d+$/, ""), names }), { "access-control-allow-origin": "*" });
    }
    if (p === "/sw.js") return send(200, TYPES[".js"], "self.addEventListener('fetch', (e) => { if (new URL(e.request.url).pathname === '/sw-intercepted') e.respondWith(new Response('from service worker', { headers: { 'content-type': 'text/plain' } })); }); self.addEventListener('install', () => self.skipWaiting()); self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));");
    if (p === "/sw-intercepted") return send(200, "text/plain", "from network");
    if (p === "/api/echo") return send(200, "application/json", JSON.stringify({ q: url.searchParams.get("q"), method: req.method }));
    if (p === "/hits") return send(200, "application/json", JSON.stringify(ctx.hits.slice(-200)));
    if (p === "/big") {
      const n = Math.min(Number(url.searchParams.get("n") ?? 3000), 20000);
      const rows = Array.from({ length: n }, (_, i) => `<li><a href="#r${i}">Row ${i}</a> <button data-i="${i}" onclick="document.getElementById('picked').textContent='picked ${i}'">Pick ${i}</button></li>`).join("");
      return html(200, "Big page", `<h1>Big</h1><p id="picked">none</p><ul>${rows}</ul>`);
    }
    // Static fixtures: /diff/*.html from diff/fixtures, the rest from ../fixtures.
    const rel = p === "/" ? "index.html" : p.slice(1);
    const base = rel.startsWith("diff/") ? fixturesDir : parityFixtures;
    const file = path.join(base, path.normalize(rel.replace(/^diff\//, "")));
    if (!file.startsWith(base) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) return html(404, "Not found", "<h1>404</h1>");
    const extra = {};
    if (file.endsWith("sandbox-inner.html")) extra["content-security-policy"] = "sandbox allow-scripts";
    send(200, TYPES[path.extname(file)] ?? "application/octet-stream", fs.readFileSync(file), extra);
  };
}

// A free port with nothing listening: connections to it are refused.
async function refusedPort() {
  const s = net.createServer();
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  const port = s.address().port;
  await new Promise((r) => s.close(r));
  return port;
}

export async function startDiffServer({ port = 0, tlsPort = 0 } = {}) {
  const ctx = { hits: [], hanging: new Set() };
  const onUpgrade = (req, socket) => (new URL(req.url, "http://x").pathname === "/ws" ? websocketEcho(req, socket) : socket.destroy());
  const server = http.createServer(handler(ctx));
  server.on("upgrade", onUpgrade);
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  // localhost resolves to ::1 first in some engines; answer there too.
  const v6 = http.createServer(handler(ctx));
  v6.on("upgrade", onUpgrade);
  await new Promise((r) => v6.listen(server.address().port, "::1", r).on("error", () => r()));
  const tls = https.createServer(selfSignedCert(), handler(ctx));
  await new Promise((r) => tls.listen(tlsPort, "127.0.0.1", r));
  const p = server.address().port;
  const origins = {
    primary: `http://127.0.0.1:${p}`,
    peer: `http://localhost:${p}`,
    tls: `https://127.0.0.1:${tls.address().port}`,
    refused: `http://127.0.0.1:${await refusedPort()}`,
    // A subdomain pair under one registrable domain for cookie scope; lvh.me
    // and its subdomains resolve to 127.0.0.1.
    sub: `http://a.lvh.me:${p}`,
    subPeer: `http://b.lvh.me:${p}`,
    dns: "http://parity-does-not-exist.invalid",
  };
  return {
    origins,
    hits: ctx.hits,
    close: async () => {
      for (const r of ctx.hanging) r.destroy();
      await Promise.all([server, v6, tls].map((s) => new Promise((r) => (s.listening ? s.close(r) : r()))));
      for (const s of [server, v6, tls]) s.closeAllConnections?.();
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const s = await startDiffServer({ port: Number(process.env.DIFF_PORT ?? 0) });
  console.log(JSON.stringify(s.origins));
}
