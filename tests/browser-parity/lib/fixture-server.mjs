// Serves tests/browser-parity/fixtures on two loopback origins so scenarios can
// exercise cross-origin iframes. Every page reads the peer origin from the
// `peer` query parameter or from /origins.json.
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import dns from "node:dns/promises";
import { fileURLToPath } from "node:url";

const fixturesDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "fixtures");

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
};

function handler(origins) {
  return async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const send = (status, type, body, headers = {}) => {
      res.writeHead(status, { "content-type": type, "cache-control": "no-store", ...headers });
      res.end(body);
    };
    // Browsers request a favicon on their own; answer it so console output
    // does not depend on the engine's favicon policy.
    if (url.pathname === "/favicon.ico") return send(204, "image/x-icon", "");
    if (url.pathname === "/origins.json") return send(200, "application/json", JSON.stringify(origins));
    if (url.pathname === "/download.txt") {
      return send(200, "text/plain", "parity download body\n", { "content-disposition": 'attachment; filename="parity-download.txt"' });
    }
    if (url.pathname === "/slow") {
      await new Promise((r) => setTimeout(r, Number(url.searchParams.get("ms") ?? 1500)));
      return send(200, "text/html; charset=utf-8", "<!doctype html><title>Slow</title><h1>Slow page loaded</h1>");
    }
    if (url.pathname === "/echo" && req.method === "POST") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const body = Buffer.concat(chunks);
      return send(200, "application/json", JSON.stringify({ bytes: body.length, type: req.headers["content-type"] ?? null }));
    }
    if (url.pathname === "/echo-cookie") {
      return send(200, "application/json", JSON.stringify({ cookie: req.headers.cookie ?? null }));
    }
    if (url.pathname === "/api/data") {
      return send(200, "application/json", JSON.stringify({ ok: true, q: url.searchParams.get("q") }));
    }
    if (url.pathname === "/set-cookie") {
      return send(200, "text/html; charset=utf-8", "<!doctype html><title>Cookie</title><p>cookie set</p>", {
        "set-cookie": "parity=1; Path=/; SameSite=Lax",
      });
    }
    const rel = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const file = path.join(fixturesDir, path.normalize(rel));
    if (!file.startsWith(fixturesDir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      return send(404, "text/html; charset=utf-8", "<!doctype html><title>Not found</title><h1>404</h1>");
    }
    send(200, contentTypes[path.extname(file)] ?? "application/octet-stream", fs.readFileSync(file));
  };
}

// Each origin is also an HTTP CONNECT proxy to the fixture hosts (and only
// to them), so `session.configure({ proxy: { server: PRIMARY } })` works.
const PROXY_HOSTS = /^(localhost|127\.0\.0\.1|(?:[\w-]+\.)?lvh\.me)$/;

function proxyTunnels(server, tunnels) {
  server.on("connect", (req, client, head) => {
    const at = req.url.lastIndexOf(":");
    const host = req.url.slice(0, at);
    const port = Number(req.url.slice(at + 1));
    client.on("error", () => {});
    if (!PROXY_HOSTS.test(host) || !port) {
      client.end("HTTP/1.1 403 Forbidden\r\n\r\n");
      return;
    }
    const upstream = net.connect(port, host.endsWith("lvh.me") ? "127.0.0.1" : host, () => {
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length) upstream.write(head);
      upstream.pipe(client);
      client.pipe(upstream);
    });
    upstream.on("error", () => client.destroy());
    for (const socket of [client, upstream]) {
      tunnels.add(socket);
      socket.on("close", () => tunnels.delete(socket));
    }
  });
}

export async function startFixtureServers({ primaryPort = 0, peerPort = 0 } = {}) {
  const origins = {};
  const tunnels = new Set();
  const listen = (port, host = "127.0.0.1") =>
    new Promise((resolve) => {
      const server = http.createServer(handler(origins));
      proxyTunnels(server, tunnels);
      server.listen(port, host, () => resolve(server));
    });
  const primary = await listen(primaryPort);
  const peer = await listen(peerPort);
  // A plain-http origin with a public hostname that resolves to loopback
  // (lvh.me). cmux prompts before loading http from hosts outside its
  // localhost and private-network allowlist, so this origin exercises that gate.
  const insecureHost = await dns.lookup("lvh.me").then((r) => (r.address === "127.0.0.1" ? "lvh.me" : null), () => null);
  // Two distinct hostnames make the peer a different site, not just a
  // different port, so cookies and frame isolation behave as they do on the web.
  origins.primary = `http://localhost:${primary.address().port}`;
  origins.peer = `http://127.0.0.1:${peer.address().port}`;
  origins.insecure = insecureHost ? `http://${insecureHost}:${primary.address().port}` : null;
  return {
    origins,
    close: () => {
      for (const socket of tunnels) socket.destroy();
      return Promise.all([primary, peer].map((s) => new Promise((r) => s.close(r))));
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { origins } = await startFixtureServers({
    primaryPort: Number(process.env.PARITY_PRIMARY_PORT ?? 8765),
    peerPort: Number(process.env.PARITY_PEER_PORT ?? 8766),
  });
  console.log(JSON.stringify(origins));
}
