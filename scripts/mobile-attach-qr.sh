#!/usr/bin/env bash
set -euo pipefail

TAG="${CMUX_TAG:-swmob}"
TTL_SECONDS="3600"
ROUTE_ID=""
ROUTE_KIND="tailscale"
OUT_DIR=""
OPEN_HTML="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="$2"
      shift 2
      ;;
    --ttl-seconds)
      TTL_SECONDS="$2"
      shift 2
      ;;
    --route-id)
      ROUTE_ID="$2"
      ROUTE_KIND=""
      shift 2
      ;;
    --route-kind)
      ROUTE_KIND="$2"
      ROUTE_ID=""
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --open)
      OPEN_HTML="1"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
OUT_DIR="${OUT_DIR:-${TMP_ROOT%/}/cmux-mobile-attach-qr-$TAG}"
umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

PARAMS="$(
  TTL_SECONDS="$TTL_SECONDS" ROUTE_ID="$ROUTE_ID" ROUTE_KIND="$ROUTE_KIND" python3 - <<'PY'
import json
import os

params = {
    "ttl_seconds": int(os.environ["TTL_SECONDS"]),
    # General-pairing QR grants Mac-wide access. Per-workspace deep links
    # use a different RPC path so they can stay scoped.
    "scope": "mac",
}
route_id = os.environ.get("ROUTE_ID", "").strip()
route_kind = os.environ.get("ROUTE_KIND", "").strip()
if route_id:
    params["route_id"] = route_id
if route_kind:
    params["route_kind"] = route_kind
print(json.dumps(params, separators=(",", ":")))
PY
)"

RAW_JSON="$OUT_DIR/attach-ticket.raw.json"
HTML_PATH="$OUT_DIR/index.html"

RAW_JSON_TMP="$(mktemp "$OUT_DIR/attach-ticket.raw.json.XXXXXX")"
trap 'rm -f "$RAW_JSON_TMP"' EXIT
CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" rpc mobile.attach_ticket.create "$PARAMS" > "$RAW_JSON_TMP"
chmod 600 "$RAW_JSON_TMP"
mv "$RAW_JSON_TMP" "$RAW_JSON"

REPO_ROOT="$REPO_ROOT" RAW_JSON="$RAW_JSON" HTML_PATH="$HTML_PATH" ROUTE_ID="$ROUTE_ID" ROUTE_KIND="$ROUTE_KIND" node --input-type=module <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);

const repoRoot = process.env.REPO_ROOT;
const rawPath = process.env.RAW_JSON;
const htmlPath = process.env.HTML_PATH;
const routeID = (process.env.ROUTE_ID || "").trim();
const routeKind = (process.env.ROUTE_KIND || "").trim();

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

async function main() {
const { buildAttachURL } = await import(
  pathToFileURL(path.join(repoRoot, "scripts", "lib", "attach-url.mjs")).href
);

const rawPayload = JSON.parse(fs.readFileSync(rawPath, "utf8"));
// Shared encode recipe: filter routes, base64url-encode the ticket, build the
// cmux-ios://attach URL. Same module dev-setup.sh uses for headless minting.
const { attachURL, routes, payload } = buildAttachURL(rawPayload, { routeID, routeKind });
payload.attach_url = attachURL;

let qrSVG = "";
try {
  const qrcodePath = path.join(repoRoot, "web", "node_modules", "qrcode");
  const QRCode = require(qrcodePath);
  qrSVG = await QRCode.toString(payload.attach_url, {
    type: "svg",
    errorCorrectionLevel: "M",
    margin: 3,
    width: 1024,
  });
} catch (error) {
  qrSVG = `<pre class="fallback">${escapeHTML(payload.attach_url)}</pre>`;
}

const routeRows = routes.map((route) => {
  const endpoint = route.endpoint || {};
  const address = endpoint.type === "host_port"
    ? `${endpoint.host}:${endpoint.port}`
    : JSON.stringify(endpoint);
  return `<tr><td>${escapeHTML(route.id)}</td><td>${escapeHTML(route.kind)}</td><td>${escapeHTML(address)}</td></tr>`;
}).join("");

const expiresAt = payload.expires_at || payload.ticket.expiresAt || "";
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux mobile pairing</title>
<style>
  :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #101111; color: #f5f5f5; }
  main { width: min(920px, calc(100vw - 48px)); display: grid; grid-template-columns: minmax(280px, 420px) 1fr; gap: 32px; align-items: center; }
  .qr { padding: 24px; background: white; border-radius: 18px; }
  .qr svg { display: block; width: 100%; height: auto; }
  h1 { margin: 0 0 12px; font-size: 34px; line-height: 1.08; }
  p { color: #b8b8b8; font-size: 17px; line-height: 1.4; }
  table { width: 100%; border-collapse: collapse; margin-top: 24px; font-size: 14px; }
  td, th { padding: 10px 0; border-bottom: 1px solid #343636; text-align: left; vertical-align: top; }
  code, .fallback { overflow-wrap: anywhere; white-space: pre-wrap; font-family: "SF Mono", Menlo, monospace; }
  .url { margin-top: 20px; color: #999; font-size: 12px; }
  @media (max-width: 760px) { main { grid-template-columns: 1fr; padding: 32px 0; } }
</style>
</head>
<body>
<main>
  <div class="qr">${qrSVG}</div>
  <section>
    <h1>Scan to pair cmux</h1>
    <p>Open cmux on iPhone, tap <strong>Scan QR Code</strong>, and scan this code. This ticket is route-filtered for the address below.</p>
    <table>
      <thead><tr><th>Route</th><th>Kind</th><th>Address</th></tr></thead>
      <tbody>${routeRows}</tbody>
    </table>
    <p>Expires: <code>${escapeHTML(expiresAt)}</code></p>
    <div class="url"><code>${escapeHTML(payload.attach_url)}</code></div>
  </section>
</main>
</body>
</html>`;

writePrivateFileSync(htmlPath, html);
writePrivateFileSync(path.join(path.dirname(htmlPath), "attach-ticket.filtered.json"), JSON.stringify(payload, null, 2));
console.log(htmlPath);
console.log(payload.attach_url);
}

function writePrivateFileSync(targetPath, contents) {
  const tmpPath = `${targetPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmpPath, contents, { mode: 0o600 });
  fs.renameSync(tmpPath, targetPath);
  fs.chmodSync(targetPath, 0o600);
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
NODE

if [[ "$OPEN_HTML" == "1" ]]; then
  open -a "Google Chrome" "$HTML_PATH"
fi
