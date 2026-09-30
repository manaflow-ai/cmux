// Differential harness core: case loading, dialect expansion, outcome
// normalization and verdicts. Shared by run.mjs, the ChatGPT runner and
// unit/diff.test.mjs, so a verdict is always recomputed from recorded
// evidence, never read back from a file.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const here = path.dirname(fileURLToPath(import.meta.url));
export const MARK = "@@DIFF@@";
export const REFERENCES = ["aside", "chatgpt"];
export const CMUX_BACKENDS = ["cmux", "cmux-dev"];
export const VERDICTS = ["same", "cmux-better", "cmux-worse", "not-applicable", "out-of-scope", "not-run"];

// ---------------------------------------------------------------------------
// Cases

export async function loadCases() {
  const dir = path.join(here, "cases");
  const cases = [];
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".mjs")).sort()) {
    const mod = await import(pathToFileURL(path.join(dir, f)).href);
    for (const c of mod.default) cases.push({ ...c, file: f });
  }
  const ids = new Set();
  for (const c of cases) {
    if (ids.has(c.id)) throw new Error(`duplicate case id ${c.id}`);
    ids.add(c.id);
    validateCase(c);
  }
  return cases;
}

function validateCase(c) {
  const where = `${c.file}:${c.id}`;
  if (!/^[a-z0-9][\w.:-]*$/i.test(c.id)) throw new Error(`${where}: bad id`);
  if (!Array.isArray(c.members) && !c.edge) throw new Error(`${where}: needs members or edge`);
  for (const m of c.members ?? []) if (!/^(aside|chatgpt):\S+$/.test(m)) throw new Error(`${where}: member "${m}" must be aside:X or chatgpt:X`);
  if (!c.custom && dialectSource(c, "cmux") == null) throw new Error(`${where}: no cmux code`);
  for (const ref of REFERENCES) {
    const has = c.custom ? !!c.custom[ref] : dialectSource(c, ref) != null;
    const why = c.na?.[ref] ?? c.scope?.[ref];
    if (!has && !why) throw new Error(`${where}: ${ref} has no code and no not-applicable/out-of-scope reason`);
  }
  for (const [ref, b] of Object.entries(c.better ?? {})) {
    if (!REFERENCES.includes(ref) || typeof b.check !== "function" || !(b.reason?.length > 15)) throw new Error(`${where}: better.${ref} needs { check(cmux, ref), reason }`);
  }
}

// `code` is shared by the three dialects; `cmux`, `aside` and `chatgpt`
// override it. null means the reference cannot express the task.
export function dialectSource(c, dialect) {
  const d = dialect === "cmux-dev" ? "cmux" : dialect;
  // A reference the case is out of scope for does not run it.
  if (c.scope?.[d]) return null;
  if (Object.prototype.hasOwnProperty.call(c, d)) return c[d];
  return c.code ?? null;
}

const PAGE = { cmux: "page", aside: "page", chatgpt: "t.playwright" };

export function expand(src, dialect) {
  const d = dialect === "cmux-dev" ? "cmux" : dialect;
  return src
    .replaceAll("$LOG", `(await ${PAGE[d]}.evaluate(() => JSON.parse(document.body.dataset.log || "[]")))`)
    .replace(/\$T\(([^)]*)\)/g, (_, n) => (d === "chatgpt" ? `{ timeoutMs: ${n} }` : `{ timeout: ${n} }`))
    .replace(/\$TO\b/g, d === "chatgpt" ? "timeoutMs" : "timeout")
    .replaceAll("$P", PAGE[d]);
}

// The prelude every dialect gets: origins, E() to capture an error as a
// value, ms() to time a call, sleep().
export function prelude(origins) {
  return [
    `const ORIGINS = ${JSON.stringify(origins)};`,
    "const U = (p, o = 'primary') => ORIGINS[o] + p;",
    "const small = (v) => { try { const s = JSON.stringify(v); return s === undefined || s.length > 2000 ? { type: Object.prototype.toString.call(v) } : v; } catch { return { type: Object.prototype.toString.call(v) }; } };",
    "const E = async (f) => { try { const v = await f(); return v === undefined ? { ok: true } : { ok: true, value: small(v) }; } catch (e) { return { error: String((e && e.message) || e).slice(0, 600), name: (e && e.name) || null }; } };",
    "const ms = async (f) => { const t0 = Date.now(); const r = await E(f); return { ms: Date.now() - t0, ...r }; };",
    "const pause = (n) => new Promise((r) => setTimeout(r, n));",
    // Format and pixel size of PNG or JPEG bytes (Uint8Array, Buffer or array).
    "const imgInfo = (b) => { b = Array.from(b.subarray ? b.subarray(0, 65536) : b.slice(0, 65536)); const u32 = (i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0; if (b[0] === 0x89 && b[1] === 0x50) return { format: 'png', width: u32(16), height: u32(20) }; if (b[0] === 0xff && b[1] === 0xd8) { for (let i = 2; i + 9 < b.length;) { if (b[i] !== 0xff) break; const m = b[i + 1], len = (b[i + 2] << 8) | b[i + 3]; if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { format: 'jpeg', width: (b[i + 7] << 8) | b[i + 8], height: (b[i + 5] << 8) | b[i + 6] }; i += 2 + len; } return { format: 'jpeg' }; } return { format: 'unknown', first: b.slice(0, 4) }; };",
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Outcome normalization

export function normalizeStrings(v, origins) {
  const reps = Object.entries(origins ?? {})
    .filter(([, o]) => o)
    .sort((a, b) => b[1].length - a[1].length);
  const s = (x) => {
    for (const [k, o] of reps) x = x.split(o).join(`<${k}>`);
    for (const [k, o] of reps) {
      const hostPort = o.replace(/^\w+:\/\//, "");
      x = x.split(hostPort).join(`<${k}-host>`);
    }
    return x;
  };
  const walk = (x) => {
    if (typeof x === "string") return s(x);
    if (Array.isArray(x)) return x.map(walk);
    if (x && typeof x === "object") return Object.fromEntries(Object.entries(x).map(([k, y]) => [k, walk(y)]));
    return x;
  };
  return walk(v);
}

// Error text to a class that means the same across implementations. Order
// matters: the most specific cue wins.
const ERROR_CLASSES = [
  // An argument check names what it expected; it wins over words like
  // "timeout" or "detached" that the argument itself may contain.
  ["invalid-arg", /\bexpected\b[^\n]*\bgot\b|expected one of|must be (a|an|one of)|is not a valid selector|while parsing|Unexpected token|not a date|Unknown key|unknown modifier/i],
  ["absent", /is not a function|is not defined|Cannot read propert(y|ies) of undefined|undefined is not an object|not supported|does not support|unsupported|Capability is not available/i],
  ["strict", /strict mode violation|resolved to [2-9]\d* elements/i],
  ["intercepted", /intercepts pointer events|intercepted|is covered|obscured|receives the click|would receive the click/i],
  ["stale", /\bstale\b|detached|not attached|no longer attached/i],
  ["not-visible", /not visible|is hidden|element is not displayed|resolved to hidden/i],
  ["disabled", /not enabled|is disabled|element is disabled/i],
  ["not-editable", /not editable|readonly|read-only/i],
  ["dialog", /dialog is open|blocked by (a|the) (javascript )?dialog/i],
  ["auth", /\b401\b|authenticat/i],
  ["tls", /certificate|SSL|TLS|ERR_CERT|secure connection/i],
  ["dns", /ERR_NAME_NOT_RESOLVED|server with the specified hostname could not be found|NSURLErrorCannotFindHost|cannot find host|could not resolve|getaddrinfo/i],
  ["refused", /ERR_CONNECTION_REFUSED|Could not connect|NSURLErrorCannotConnectToHost|connection refused|ECONNREFUSED/i],
  ["redirects", /too many (HTTP )?redirects|ERR_TOO_MANY_REDIRECTS|redirect loop|HTTPTooManyRedirects|redirected too many times/i],
  ["aborted", /ERR_ABORTED|interrupted by another navigation|navigation (was )?(cancel|abort)|NSURLErrorCancelled|frame load interrupted/i],
  ["crashed", /Target crashed|page crashed|web content process (terminated|crashed)/i],
  ["closed", /has been closed|already handled|tab (was |is )?closed|No open tab|Target closed|page is closed|No tab with id|Tab not found/i],
  ["no-element", /ENOENT|no such file/i],
  ["denied", /EACCES|permission denied|outside the REPL/i],
  ["invalid-arg", /Not a checkbox or radio button|Cannot (un)?check|is not a <select>|not an <input>|Malformed value|Non-input element|not an HTMLInputElement|Node is not an/i],
  ["no-element", /did not find some options|no_matches|"matchCount":0|resolved to 0 elements|no element|does not exist|not found|waiting for (locator|selector|getBy)|waiting on \w+ for selector|waiting for "[^"]+" to be/i],
  ["timeout", /timeout|timed out|deadline/i],
  ["invalid-arg", /requires|invalid|expected|must be|not a valid|unknown (key|option|event|role)|TypeError|RangeError|SyntaxError|received an? /i],
];
export function classifyError(msg) {
  const m = String(msg ?? "");
  for (const [cls, re] of ERROR_CLASSES) if (re.test(m)) return cls;
  return "other";
}
const SPECIFIC = new Set(["denied", "invalid-arg", "crashed", "strict", "intercepted", "stale", "not-visible", "disabled", "not-editable", "dialog", "auth", "tls", "dns", "refused", "redirects", "aborted", "closed", "no-element"]);
export const isSpecific = (cls) => SPECIFIC.has(cls);

// The shared "better" rule for error variants: for every key the outcomes
// agree, or cmux fails with a specific error class (it names the failed
// check, or rejects an invalid argument) where the reference fails
// generically or silently accepts the input.
export const errorsBetter = {
  reason: "cmux reports the failing check or the invalid argument (a specific error) where the reference fails generically or silently accepts it",
  check: (c, r, h = {}) => (h.keys ?? Object.keys(c)).every((k) => {
    const a = c[k] && c[k].error;
    const b = r[k] && r[k].error;
    if (a === undefined) return stable(looseErrors(comparable(c[k]))) === stable(looseErrors(comparable(r[k])));
    const ca = classifyError(a);
    // A generic cmux failure is only as good as the same generic failure.
    if (!isSpecific(ca)) return b !== undefined && classifyError(b) === ca;
    // A specific cmux failure is at least as good as any reference outcome
    // only where the case expects cmux to fail (an invalid or impossible
    // input); a reference that succeeds where cmux was meant to succeed wins.
    const want = h.expect && h.expect[k];
    return !(want && typeof want === "object" && want.error === undefined) && (b !== undefined || !want || typeof want.error === "string");
  }),
};

export function timingClass(n) {
  if (typeof n !== "number") return n;
  if (n < 1000) return "instant";
  if (n < 5000) return "short";
  if (n < 15000) return "long";
  return "very-long";
}

// Comparable form: errors become their class, times their class, and `_`
// keys (raw evidence) are dropped.
export function comparable(v, key = "") {
  if (v && typeof v === "object" && !Array.isArray(v)) {
    if (typeof v.error === "string") {
      const out = { error: classifyError(v.error) };
      if (typeof v.ms === "number") out.ms = timingClass(v.ms);
      return out;
    }
    const out = {};
    for (const [k, x] of Object.entries(v)) {
      if (k.startsWith("_")) continue;
      out[k] = comparable(x, k);
    }
    return out;
  }
  if (Array.isArray(v)) return v.map((x) => comparable(x));
  if ((key === "ms" || /Ms$/.test(key)) && typeof v === "number") return timingClass(v);
  return v;
}

// Two failures that each name a specific reason are the same outcome (both
// reject, each saying why); the exact class may differ between engines.
export function looseErrors(v) {
  if (Array.isArray(v)) return v.map(looseErrors);
  if (v && typeof v === "object") {
    if (typeof v.error === "string") return { ...v, error: isSpecific(v.error) ? "specific" : v.error };
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, looseErrors(x)]));
  }
  return v;
}

export function project(value, keys) {
  if (!keys || !value || typeof value !== "object") return value;
  return Object.fromEntries(keys.map((k) => [k, value[k]]));
}

export function stable(v) {
  if (Array.isArray(v)) return `[${v.map(stable).join(",")}]`;
  if (v && typeof v === "object") return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stable(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

export function differences(a, b, prefix = "") {
  if (stable(a) === stable(b)) return [];
  if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
    const out = [];
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) out.push(...differences(a[k], b[k], prefix ? `${prefix}.${k}` : k));
    return out;
  }
  return [`${prefix || "value"}: cmux ${JSON.stringify(a)} vs ref ${JSON.stringify(b)}`.slice(0, 300)];
}

// ---------------------------------------------------------------------------
// Verdicts

// `expect` is what cmux must produce regardless of the references
// (correctness); a mismatch is a failure even when a reference agrees.
export function checkExpect(c, cmuxValue) {
  if (!c.expect) return [];
  const got = comparable(cmuxValue ?? {});
  // Expectations name error classes and time classes directly.
  const want = c.expect;
  // An expected object names only the fields that matter (an error class
  // without its time, say); arrays and values must match exactly.
  const matches = (g, w) => (w && typeof w === "object" && !Array.isArray(w) ? !!g && typeof g === "object" && Object.entries(w).every(([k, v]) => matches(g[k], v)) : stable(g) === stable(w));
  const problems = [];
  for (const [k, v] of Object.entries(want)) if (!matches(got[k], v)) problems.push(`expect ${k}: got ${JSON.stringify(got[k])}, want ${JSON.stringify(v)}`.slice(0, 300));
  return problems;
}

export function verdictFor(c, ref, cmuxRes, refRes) {
  const scope = c.scope?.[ref];
  const hasRef = c.custom ? !!c.custom[ref] : dialectSource(c, ref) != null;
  if (!hasRef) return scope ? { verdict: "out-of-scope", reason: scope } : { verdict: "not-applicable", reason: c.na?.[ref] };
  if (!cmuxRes) return { verdict: "not-run", reason: "no cmux result" };
  if (!refRes) return { verdict: "not-run", reason: `no ${ref} result` };
  if (cmuxRes.uncaught) return { verdict: "cmux-worse", reason: `cmux uncaught: ${cmuxRes.uncaught}`.slice(0, 300) };
  const expectProblems = checkExpect(c, cmuxRes.value);
  if (expectProblems.length) return { verdict: "cmux-worse", reason: expectProblems.join("; ") };
  // Cases capture expected failures with E(); an uncaught reference error is
  // a broken run, not evidence either way.
  if (refRes.uncaught) return { verdict: "not-run", reason: `${ref} run failed: ${refRes.uncaught}`.slice(0, 300) };
  const keys = Array.isArray(c.compare) ? c.compare : c.compare?.[ref];
  const a = project(comparable(cmuxRes.value), keys);
  const b = project(comparable(refRes.value), keys);
  if (stable(looseErrors(a)) === stable(looseErrors(b))) return { verdict: "same" };
  const better = c.better?.[ref];
  if (better) {
    let ok = false;
    try {
      ok = !!better.check(cmuxRes.value ?? {}, refRes.value ?? {}, { comparable, classifyError, isSpecific, keys, expect: c.expect });
    } catch {
      ok = false;
    }
    if (ok) return { verdict: "cmux-better", reason: better.reason };
  }
  return { verdict: "cmux-worse", reason: differences(a, b).join("; ") };
}

// Results: results/<backend>.json { meta, cases: { id: { value, uncaught, ms } } }.
export function readResults(backend) {
  const f = path.join(here, "results", `${backend}.json`);
  return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : { meta: {}, cases: {} };
}

export function writeResults(backend, data) {
  fs.mkdirSync(path.join(here, "results"), { recursive: true });
  fs.writeFileSync(path.join(here, "results", `${backend}.json`), JSON.stringify(data, null, 1) + "\n");
}

// The cmux evidence for verdicts: the app's result when it ran the case,
// else the dev driver's. `appOnly` cases need the app.
export function cmuxResultFor(c, app, dev) {
  if (app.cases[c.id]) return { res: app.cases[c.id], backend: "cmux" };
  if (c.appOnly) return { res: null, backend: "cmux" };
  return { res: dev.cases[c.id] ?? null, backend: "cmux-dev" };
}

export function allVerdicts(cases, results) {
  const out = [];
  for (const c of cases) {
    const { res, backend } = cmuxResultFor(c, results.cmux, results["cmux-dev"]);
    const row = { id: c.id, file: c.file, members: c.members ?? [], edge: c.edge ?? null, cmuxBackend: backend, refs: {} };
    for (const ref of REFERENCES) row.refs[ref] = verdictFor(c, ref, res, results[ref].cases[c.id]);
    // cmux must meet the case's expectation whatever the references do.
    row.cmuxProblems = !res ? ["not run"] : res.uncaught ? [`uncaught: ${res.uncaught}`.slice(0, 300)] : checkExpect(c, res.value);
    out.push(row);
  }
  return out;
}
