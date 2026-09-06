#!/usr/bin/env node
// Local stand-in for the Freestyle TLS egress edge, for verifying the coderouter
// model plane end to end on one machine: it terminates TLS with a private CA,
// OVERWRITES the two edge headers (`x-coderouter-route-token`, `x-cmux-vm-id`)
// on every request like the real edge does, and re-originates to a coderouter
// origin (a local `bun dev`, a tunnel, or a preview). Real agent CLIs (codex,
// claude, pi, curl) then run against it with placeholder keys, exactly as a
// Cloud machine would, and the origin's routing, VM binding, and usage ledger
// can be checked without a VM.
//
//   node scripts/coderouter/local-edge.mjs --origin http://127.0.0.1:4682 \
//     --route-token crt_... --vm-id <cloud_vms.id> [--port 8443] [--no-inject] \
//     [--origin-header name=value] [--state-dir <dir>]
//
// It prints the `export` lines a client shell needs (CA bundle for Node, rustls,
// and curl; base URLs; placeholder keys). `--no-inject` forwards without the
// headers to prove the placeholder alone is not a credential.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import { tmpdir } from "node:os";
import path from "node:path";

const ROUTE_TOKEN_HEADER = "x-coderouter-route-token";
const VM_ID_HEADER = "x-cmux-vm-id";
const PLACEHOLDER = "cmux-vm-edge-placeholder";

const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(`${name} needs a value`);
  return value;
}
function options(name) {
  const values = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === name && args[i + 1] !== undefined) values.push(args[i + 1]);
  }
  return values;
}

const originText = option("--origin", "http://127.0.0.1:3777");
const origin = new URL(originText);
const inject = !args.includes("--no-inject");
const routeToken = option("--route-token", process.env.CMUX_LOCAL_EDGE_ROUTE_TOKEN ?? "");
const vmId = option("--vm-id", process.env.CMUX_LOCAL_EDGE_VM_ID ?? "");
const port = Number(option("--port", "8443"));
const stateDir = option("--state-dir", path.join(tmpdir(), "cmux-local-edge"));
// --dump-dir writes each /v1 request and response body (bodies only, never the
// injected headers) so a client's exact wire shape can be compared against the
// origin's answer when a leg fails.
const dumpDir = option("--dump-dir", "");
if (dumpDir) mkdirSync(dumpDir, { recursive: true, mode: 0o700 });
const extraOriginHeaders = Object.fromEntries(
  options("--origin-header").map((pair) => {
    const eq = pair.indexOf("=");
    if (eq <= 0) throw new Error(`--origin-header expects name=value, got ${pair}`);
    return [pair.slice(0, eq).toLowerCase(), pair.slice(eq + 1)];
  }),
);
if (inject && (!routeToken || !vmId)) {
  console.error("--route-token and --vm-id are required unless --no-inject is set");
  process.exit(2);
}
if (inject && !/^crt_[A-Za-z0-9._-]+$/.test(routeToken)) {
  console.error("--route-token must be a crt_ route token");
  process.exit(2);
}

// One private CA and one leaf for 127.0.0.1 / localhost, reused across runs so
// clients can keep a CA bundle path. openssl is present on macOS and the devbox.
mkdirSync(stateDir, { recursive: true, mode: 0o700 });
const caKey = path.join(stateDir, "ca.key");
const caCert = path.join(stateDir, "ca.crt");
const leafKey = path.join(stateDir, "edge.key");
const leafCert = path.join(stateDir, "edge.crt");
if (!existsSync(caCert) || !existsSync(leafCert)) {
  const openssl = (...a) => execFileSync("openssl", a, { stdio: ["ignore", "ignore", "inherit"] });
  openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
    "-keyout", caKey, "-out", caCert, "-days", "3650", "-subj", "/CN=cmux local edge CA",
    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign");
  const csr = path.join(stateDir, "edge.csr");
  const ext = path.join(stateDir, "edge.ext");
  writeFileSync(ext, [
    "basicConstraints=CA:FALSE",
    "keyUsage=digitalSignature,keyEncipherment",
    "extendedKeyUsage=serverAuth",
    "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1",
  ].join("\n") + "\n");
  openssl("req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
    "-keyout", leafKey, "-out", csr, "-subj", "/CN=cmux local edge");
  openssl("x509", "-req", "-in", csr, "-CA", caCert, "-CAkey", caKey, "-CAcreateserial",
    "-out", leafCert, "-days", "825", "-extfile", ext);
}

const originAgent = origin.protocol === "https:" ? https : http;
let requestCounter = 0;

const server = https.createServer({ key: readFileSync(leafKey), cert: readFileSync(leafCert) }, (req, res) => {
  const id = (requestCounter += 1);
  const startedAt = Date.now();
  const headers = { ...req.headers };
  // The guest never legitimately sends these; a value here is a forgery attempt
  // that the real edge replaces. Record it, then overwrite (or strip).
  const forgedToken = headers[ROUTE_TOKEN_HEADER];
  const forgedVmId = headers[VM_ID_HEADER];
  delete headers[ROUTE_TOKEN_HEADER];
  delete headers[VM_ID_HEADER];
  if (inject) {
    headers[ROUTE_TOKEN_HEADER] = routeToken;
    headers[VM_ID_HEADER] = vmId;
  }
  headers.host = origin.host;
  Object.assign(headers, extraOriginHeaders);
  delete headers.connection;

  const dumpBase = dumpDir && req.url.startsWith("/v1/") ? path.join(dumpDir, `${String(id).padStart(4, "0")}-${req.method}-${req.url.replace(/[^a-z0-9]+/gi, "_").slice(0, 40)}`) : "";
  const reqChunks = [];
  const resChunks = [];
  if (dumpBase) req.on("data", (chunk) => reqChunks.push(chunk));
  const upstream = originAgent.request(
    {
      protocol: origin.protocol,
      hostname: origin.hostname,
      port: origin.port || (origin.protocol === "https:" ? 443 : 80),
      method: req.method,
      path: req.url,
      headers,
    },
    (upstreamRes) => {
      const responseHeaders = { ...upstreamRes.headers };
      delete responseHeaders.connection;
      res.writeHead(upstreamRes.statusCode ?? 502, responseHeaders);
      if (dumpBase) upstreamRes.on("data", (chunk) => resChunks.push(chunk));
      upstreamRes.pipe(res);
      upstreamRes.on("end", () => {
        if (dumpBase) {
          const requestHeaders = { ...req.headers };
          delete requestHeaders[ROUTE_TOKEN_HEADER];
          delete requestHeaders["authorization"];
          delete requestHeaders["x-api-key"];
          writeFileSync(`${dumpBase}.req.json`, JSON.stringify({ headers: requestHeaders, body: Buffer.concat(reqChunks).toString("utf8") }, null, 2));
          writeFileSync(`${dumpBase}.res.txt`, `HTTP ${upstreamRes.statusCode}\n${JSON.stringify(upstreamRes.headers)}\n\n${Buffer.concat(resChunks).toString("utf8")}`);
        }
        const forged = forgedToken || forgedVmId ? ` forged-headers-overwritten(token=${forgedToken ? "yes" : "no"},vm=${forgedVmId ? "yes" : "no"})` : "";
        const agent = (req.headers["user-agent"] ?? "").toString().slice(0, 40);
        console.error(`[edge] #${id} ${req.method} ${req.url} -> ${upstreamRes.statusCode} ${Date.now() - startedAt}ms ua="${agent}"${forged}`);
      });
    },
  );
  upstream.on("error", (error) => {
    console.error(`[edge] #${id} ${req.method} ${req.url} -> origin error ${error.message}`);
    if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "local_edge_origin_unreachable", message: error.message }));
  });
  req.pipe(upstream);
});

server.listen(port, "127.0.0.1", () => {
  const base = `https://127.0.0.1:${port}`;
  console.error(`[edge] listening on ${base} -> ${origin.origin} (${inject ? `injecting ${VM_ID_HEADER}=${vmId}` : "NOT injecting"})`);
  console.log(`export SSL_CERT_FILE=${caCert} NODE_EXTRA_CA_CERTS=${caCert} CURL_CA_BUNDLE=${caCert}`);
  console.log(`export OPENAI_BASE_URL=${base}/v1 OPENAI_API_KEY=${PLACEHOLDER}`);
  console.log(`export ANTHROPIC_BASE_URL=${base} ANTHROPIC_API_KEY=${PLACEHOLDER}`);
  console.log(`export CMUX_CODEROUTER_URL=${base}${vmId ? ` CMUX_VM_ID=${vmId}` : ""}`);
});
