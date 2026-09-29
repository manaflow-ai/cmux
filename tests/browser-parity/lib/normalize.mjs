// Normalizes backend-specific identifiers so goldens compare representation,
// not ephemeral IDs. Only values that differ per run are rewritten: fixture
// origins and ports, browser target IDs, and window IDs.

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
  // Chromium DevTools target IDs and Aside tab IDs.
  out = out.replace(/\b[0-9A-F]{32}\b/g, "<TARGET>");
  return out;
}

export function diffEmits(golden, actual) {
  const problems = [];
  const max = Math.max(golden.length, actual.length);
  for (let i = 0; i < max; i++) {
    const g = golden[i];
    const a = actual[i];
    if (!a) {
      problems.push(`missing value #${i} "${g.k}"`);
      continue;
    }
    if (!g) {
      problems.push(`extra value #${i} "${a.k}": ${preview(a.v)}`);
      continue;
    }
    if (g.k !== a.k) {
      problems.push(`value #${i}: expected key "${g.k}", got "${a.k}" (${preview(a.v)})`);
      continue;
    }
    const gs = JSON.stringify(g.v);
    const as = JSON.stringify(a.v);
    if (gs !== as) problems.push(`"${g.k}" differs:\n${textDiff(g.v, a.v)}`);
  }
  return problems;
}

function preview(v) {
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s.length > 160 ? s.slice(0, 160) + "…" : s;
}

// Line diff for multi-line snapshot text; JSON preview for other values.
function textDiff(expected, actual) {
  if (typeof expected !== "string" || typeof actual !== "string") {
    return `    expected ${preview(expected)}\n    actual   ${preview(actual)}`;
  }
  const e = expected.split("\n");
  const a = actual.split("\n");
  const lines = [];
  const n = Math.max(e.length, a.length);
  for (let i = 0; i < n && lines.length < 24; i++) {
    if (e[i] === a[i]) continue;
    if (e[i] !== undefined) lines.push(`    - ${e[i]}`);
    if (a[i] !== undefined) lines.push(`    + ${a[i]}`);
  }
  return lines.join("\n");
}
