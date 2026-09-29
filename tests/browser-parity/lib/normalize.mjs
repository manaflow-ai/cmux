// Normalizes values that differ per run so goldens compare behavior and
// format, not ephemeral identifiers: fixture origins and ports, tab target
// IDs, window IDs and temporary paths.
import os from "node:os";
import fs from "node:fs";

const TMP = [fs.realpathSync(os.tmpdir()), os.tmpdir(), "/private/tmp", "/tmp"]
  .map((p) => p.replace(/\/$/, ""))
  .sort((a, b) => b.length - a.length);

export function normalize(value, origins) {
  if (typeof value === "string") return normalizeString(value, origins);
  if (Array.isArray(value)) return value.map((v) => normalize(v, origins));
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (k === "windowId" && typeof v === "number") out[k] = "<WINDOW>";
      else out[k] = normalize(v, origins);
    }
    return out;
  }
  return value;
}

function normalizeString(s, origins) {
  let out = s;
  for (const [name, origin] of [["PRIMARY", origins.primary], ["PEER", origins.peer]]) {
    out = out.split(origin).join(name);
    out = out.split(encodeURIComponent(origin)).join(name);
    const port = new URL(origin).port;
    out = out.replace(new RegExp(`\\b${port}\\b`, "g"), `<${name}_PORT>`);
  }
  // Tab IDs (32 hex characters in both the dev driver and the oracle).
  out = out.replace(/\b[0-9A-Fa-f]{32}\b/g, "<TARGET>");
  for (const t of TMP) out = out.split(t + "/").join("<TMP>/");
  // Per-run directory names under the temporary directory.
  out = out.replace(/<TMP>\/(cmux-repl-|parity-oracle-|parity-)[A-Za-z0-9]+/g, "<TMP>/$1XXXX");
  out = out.replace(/<TMP>\/cmux-browser-repl\/[^/\s\]]+/g, "<TMP>/cmux-browser-repl/<SESSION>");
  return out;
}

// Compares expected and actual key/value maps; every expected key must be
// present and equal, and no unexpected key may appear.
export function diffValues(expected, actual) {
  const problems = [];
  for (const [k, v] of Object.entries(expected)) {
    if (!(k in actual)) problems.push(`missing "${k}"`);
    else if (JSON.stringify(v) !== JSON.stringify(actual[k])) problems.push(`"${k}" differs:\n${textDiff(v, actual[k])}`);
  }
  for (const [k, v] of Object.entries(actual)) {
    if (!(k in expected)) problems.push(`unexpected "${k}": ${preview(v)}`);
  }
  return problems;
}

function preview(v) {
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s.length > 300 ? s.slice(0, 300) + "…" : s;
}

function textDiff(expected, actual) {
  if (typeof expected !== "string" || typeof actual !== "string") {
    return `    expected ${preview(expected)}\n    actual   ${preview(actual)}`;
  }
  const e = expected.split("\n");
  const a = actual.split("\n");
  const lines = [];
  for (let i = 0; i < Math.max(e.length, a.length) && lines.length < 30; i++) {
    if (e[i] === a[i]) continue;
    if (e[i] !== undefined) lines.push(`    - ${e[i]}`);
    if (a[i] !== undefined) lines.push(`    + ${a[i]}`);
  }
  return lines.join("\n");
}
