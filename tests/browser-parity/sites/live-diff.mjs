#!/usr/bin/env node
// Live differential check of the site tools: the same read in reference A
// (its REPL, one-shot, its own signed-in profile) and in cmux
// (`cmux browser repl --session live-diff` on a tagged app), compared by
// privacy-preserving summaries only.
//
//   PARITY_CMUX_CLI=<tagged cmux CLI> CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock \
//     node tests/browser-parity/sites/live-diff.mjs signed-in
//   ... live-diff.mjs run [--ops gmail,slack.history] [--runs N] [--write-doc]
//
// Privacy: each REPL reduces a result to counts, ids, key names and lengths
// before it prints; this process hashes the ids (sha256, 10 hex) at once and
// keeps raw ids in memory only to pass one side's first item to the next
// operation. Nothing prints or stores message bodies, emails, names or
// document text; error text is cut to its first line with addresses and
// numbers masked. Reads only: no draft is confirmed, nothing is sent.
// Results go to tests/browser-parity/sites/live-results/ (gitignored).
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { referenceACli } from "../lib/references.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../../..");
const resultsDir = path.join(here, "live-results");
const docPath = path.join(repoRoot, "docs/browser-repl/site-tools.md");
const CLI = process.env.PARITY_CMUX_CLI || "cmux";
const UID = Number(process.env.LIVE_GOOGLE_UID || 0);
const SESSION = process.env.LIVE_SESSION || "live-diff";

const hash = (v) => crypto.createHash("sha256").update(String(v)).digest("hex").slice(0, 10);
const redact = (s) =>
  String(s || "")
    .split("\n")[0]
    .replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, "<email>")
    .replace(/https?:\/\/\S+/g, "<url>")
    .replace(/\b[\w-]{20,}\b/g, "<id>")
    .slice(0, 160);

function exec(cmd, argv, { input, timeoutMs = 240000, env } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, out, err });
    });
    if (input !== undefined) child.stdin.end(input);
    else child.stdin.end();
  });
}

// REPL code: evaluate `expr`, reduce it with `extract`, print one marked line.
// LIVE_RELOAD_SITES=<dir>: load sites/*.js from a checkout first (to try
// fixes on a running tag without a rebuild).
const reload = process.env.LIVE_RELOAD_SITES
  ? (() => {
      const dir = path.resolve(process.env.LIVE_RELOAD_SITES);
      const m = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
      return m.repl.filter((f) => f.startsWith("sites/")).map((f) => `(0, eval)(${JSON.stringify(fs.readFileSync(path.join(dir, f), "utf8"))});`).join("\n");
    })()
  : "";
const program = (expr, extract, forCmux = true) => `${forCmux ? reload : ""}
const __t0 = Date.now();
let __out;
try {
  const __v = await (async () => (${expr}))();
  __out = Object.assign({ ok: true }, (${extract})(__v));
} catch (e) {
  __out = { ok: false, error: String((e && e.message) || e), code: (e && e.code) || null };
}
__out.ms = Date.now() - __t0;
console.log("__LIVE__" + JSON.stringify(__out));
`;

function parse(r) {
  const line = (r.out + "\n" + r.err).split("\n").find((l) => l.includes("__LIVE__"));
  if (!line) return { ok: false, error: redact(r.err || r.out || `exit ${r.code}`), code: "no_result", ms: null };
  return JSON.parse(line.slice(line.indexOf("__LIVE__") + 8));
}

async function runCmux(expr, extract) {
  return parse(await exec(CLI, ["browser", "repl", "--session", SESSION, "--timeout", "180000", "--eval", "-"], { input: program(expr, extract), timeoutMs: 200000 }));
}
async function runReferenceA(expr, extract) {
  if (!expr) return { ok: false, code: "no_tool", error: "Reference A has no tool for this read", ms: null };
  return parse(await exec(referenceACli(), ["repl", program(expr, extract, false)], { timeoutMs: 200000 }));
}

// Summary reducers, as source for both REPLs. Each returns
// { count, ids, titleLens, shape, textLen } from fields named by the op.
const list = (arrayExpr, idExpr, titleExpr = "null") => `(v) => {
  const a = (${arrayExpr}) || [];
  return { count: a.length, ids: a.map((x) => ${idExpr}).map((x) => (x === undefined || x === null ? null : String(x))), titleLens: a.map((x) => { const t = ${titleExpr}; return typeof t === "string" ? t.length : null; }), shape: a[0] && typeof a[0] === "object" ? Object.keys(a[0]).sort() : [] };
}`;
const text = (textExpr, extra = "{}") => `(v) => { const t = ${textExpr}; return Object.assign({ textLen: typeof t === "string" ? t.length : null, lines: typeof t === "string" ? t.split("\\n").filter(Boolean).length : null }, ${extra}); }`;

// Context carried between operations (raw ids, memory only).
const ctx = {};
const q = (s) => JSON.stringify(s);

const OPS = [
  // Google
  { op: "googleAccounts.list", cmux: "sites.googleAccounts.list()", "reference-a": "googleAccounts.list()", cx: list("v", "x.email", "x.name"), ax: list("v", "x.email", "x.name") },
  { op: "gmail.inbox", cap: 50, cmux: `sites.gmail.inbox({ uid: ${UID}, limit: 50 })`, "reference-a": `gmail.getInbox(${UID})`, cx: list("v", "x.threadId", "x.subject"), ax: list("v.results", "x.threadId", "x.subject"), keep: (c) => (ctx.threadIds = c) },
  { op: "gmail.search is:unread", cap: 50, cmux: `sites.gmail.search("is:unread", { uid: ${UID}, limit: 50 })`, "reference-a": `gmail.search(${UID}, "is:unread")`, cx: list("v", "x.threadId", "x.subject"), ax: list("v.results", "x.threadId", "x.subject") },
  {
    op: "gmail.thread",
    needs: () => ctx.threadIds && ctx.threadIds[0],
    cmux: () => `sites.gmail.thread(${q(ctx.threadIds[0])}, { uid: ${UID} })`,
    "reference-a": () => `gmail.getThread(${UID}, ${q(ctx.threadIds[0])})`,
    cx: list("v.messages", "x.messageId", "x.body"),
    ax: list("v.messages", "x.messageId", "x.body"),
  },
  {
    op: "gmail.attachments (metadata)",
    needs: () => ctx.threadIds && ctx.threadIds.length,
    cmux: () => `(async () => { for (const id of ${q((ctx.threadIds || []).slice(0, 10))}) { const t = await sites.gmail.thread(id, { uid: ${UID} }); const a = t.messages.flatMap((m) => m.attachments); if (a.length) return a; } return []; })()`,
    "reference-a": () => `(async () => { for (const id of ${q((ctx.threadIds || []).slice(0, 10))}) { const t = await gmail.getThread(${UID}, id); const a = t.messages.flatMap((m) => m.attachments || []); if (a.length) return a; } return []; })()`,
    cx: list("v", "x.name", "x.name"),
    ax: list("v", "x.filename", "x.filename"),
  },
  { op: "googleCalendar.events (next 10)", cmux: `sites.googleCalendar.events({ view: "agenda", limit: 10, uid: ${UID} })`, "reference-a": null, cx: list("v", "x.id", "x.title") },
  { op: "googleDrive.recent", cmux: `sites.googleDrive.recent({ uid: ${UID}, limit: 50 })`, "reference-a": null, cx: list("v", "(x.type || '') + '|' + x.id", "x.title"), keep: (c) => {
    ctx.driveIds = c;
    // A Doc, Sheet and Slides file from Recent when history had none.
    const kinds = { "Google Docs": "document", "Google Sheets": "spreadsheets", "Google Slides": "presentation" };
    for (const entry of c) {
      const [type, id] = String(entry).split("|");
      const kind = kinds[type];
      if (kind && !ctx.files[kind]) ctx.files[kind] = `https://docs.google.com/${kind}/d/${id}/edit`;
    }
  } },
  {
    op: "googleDrive.search (own Sheets, Slides)",
    cmux: `Promise.all([sites.googleDrive.search("type:spreadsheet owner:me", { uid: ${UID}, limit: 5 }), sites.googleDrive.search("type:presentation owner:me", { uid: ${UID}, limit: 5 })]).then(([a, b]) => a.concat(b))`,
    "reference-a": null,
    cx: list("v", "(x.type || '') + '|' + x.id", "x.title"),
    keep: (c) => {
      const kinds = { "Google Docs": "document", "Google Sheets": "spreadsheets", "Google Slides": "presentation" };
      for (const entry of c) {
        const [type, id] = String(entry).split("|");
        if (kinds[type] && !ctx.files[kinds[type]]) ctx.files[kinds[type]] = `https://docs.google.com/${kinds[type]}/d/${id}/edit`;
      }
    },
  },
  ...["document", "spreadsheets", "presentation"].map((kind) => ({
    op: `google ${kind} read`,
    needs: () => ctx.files && ctx.files[kind],
    cmux: () => (kind === "document" ? `sites.googleDocs.read(${q(ctx.files[kind])})` : kind === "spreadsheets" ? `sites.googleSheets.read(${q(ctx.files[kind])})` : `sites.googleSlides.read(${q(ctx.files[kind])})`),
    "reference-a": () => (kind === "document" ? `googleDocs.getDocumentText(${q(ctx.files[kind])})` : kind === "spreadsheets" ? `googleSheets.readSheet(${q(ctx.files[kind])})` : null),
    cx: kind === "spreadsheets" ? `(v) => ({ count: v.rows.flat().filter((c) => c !== "").length })` : text("v.text"),
    ax: kind === "spreadsheets" ? `(v) => ({ count: (v.cells || []).filter((c) => c.value !== undefined && c.value !== "").length })` : text("v"),
  })),
  { op: "googleSearch.search", cmux: `sites.googleSearch.search("webkit content world", { limit: 10 })`, "reference-a": `googleSearch.search("webkit content world", { limit: 10 })`, cx: list("v", "x.url", "x.title"), ax: list("v", "x.url", "x.title") },
  // Slack
  { op: "slack.workspaces", cmux: "sites.slack.workspaces()", "reference-a": "slack.listWorkspaces()", cx: list("v", "x.teamId", "x.name"), ax: list("v.filter((w) => w.status === 'joined')", "x.teamId", "x.name"), keep: (c) => (ctx.teams = c) },
  {
    op: "slack.channels",
    needs: () => ctx.teams && ctx.teams[0],
    cmux: () => `sites.slack.channels(${q(ctx.teams[0])}, { limit: 200 })`,
    "reference-a": () => `(await slack.getClient(${q(ctx.teams[0])})).users.conversations({ types: "public_channel,private_channel", exclude_archived: true, limit: 200 })`,
    cx: list("v.channels", "x.id", "x.name"),
    ax: list("v.channels", "x.id", "x.name"),
    keep: (c) => (ctx.channels = c),
  },
  {
    op: "slack.history (last 20)",
    needs: () => ctx.channels && ctx.channels[0],
    cmux: () => `sites.slack.history(${q(ctx.teams[0])}, ${q(ctx.channels[0])}, { limit: 20 })`,
    "reference-a": () => `(await slack.getClient(${q(ctx.teams[0])})).conversations.history({ channel: ${q(ctx.channels[0])}, limit: 20 })`,
    cx: list("v.messages", "x.ts", "x.text"),
    ax: list("v.messages", "x.ts", "x.text"),
  },
  {
    op: "slack.search",
    needs: () => ctx.teams && ctx.teams[0],
    cmux: () => `sites.slack.search(${q(ctx.teams[0])}, "the", { count: 20 })`,
    "reference-a": () => `(await slack.getClient(${q(ctx.teams[0])})).search.messages({ query: "the", count: 20 })`,
    cx: list("v.matches", "x.ts", "x.text"),
    ax: list("v.messages.matches", "x.ts", "x.text"),
  },
  // Notion
  { op: "notion.search", cmux: `sites.notion.search("a", { limit: 20 })`, "reference-a": `(await notion.getClient()).search({ query: "a", limit: 20, isNavigableOnly: true })`, cx: list("v", "x.id", "x.title"), ax: list("v", "x.id", "x.title"), keep: (c) => (ctx.notionIds = c) },
  {
    op: "notion.read (first page)",
    needs: () => ctx.notionIds && ctx.notionIds[0],
    cmux: () => `sites.notion.read(${q(ctx.notionIds[0])})`,
    "reference-a": () => `(async () => blockToMarkdown(await (await notion.getClient()).getBlock(${q(ctx.notionIds[0])})))()`,
    cx: text("v.markdown"),
    ax: text("v"),
  },
  // LinkedIn
  { op: "linkedin.me", cmux: "sites.linkedin.me()", "reference-a": "linkedin.getMe()", cx: `(v) => ({ count: v && v.publicIdentifier ? 1 : 0, ids: [v && v.publicIdentifier] })`, ax: `(v) => { const m = ((v && v.included) || []).find((x) => x.$type && x.$type.endsWith("MiniProfile")); return { count: m ? 1 : 0, ids: [m && m.publicIdentifier] }; }` },
  { op: "linkedin.feed (first page)", cmux: "sites.linkedin.feed({ limit: 10 })", "reference-a": null, cx: list("v", "x.id", "x.text") },
  { op: "linkedin.search people", cmux: `sites.linkedin.search("software engineer", { limit: 10 })`, "reference-a": `linkedin.searchPeople("software engineer")`, cx: list("v", "(x.url.match(/\\/in\\/([^/]+)/) || [])[1]", "x.name"), ax: list("v.results", "x.publicIdentifier || ((x.navigationUrl || x.url || '').match(/\\/in\\/([^/?]+)/) || [])[1]", "x.title") },
  // X
  { op: "x.user", cmux: `sites.x.user("XDevelopers")`, "reference-a": `twitter.getUser("XDevelopers")`, cx: `(v) => ({ count: v ? 1 : 0, ids: [v && v.screenName && v.screenName.toLowerCase()], followers: v && v.followersCount })`, ax: `(v) => ({ count: v ? 1 : 0, ids: [v && v.screenName && v.screenName.toLowerCase()], followers: v && v.followersCount })` },
  { op: "x.timeline", cmux: "sites.x.timeline({ limit: 20 })", "reference-a": "twitter.getTimeline({ count: 20 })", cx: list("v", "x.id", "x.text"), ax: list("v.tweets", "x.id", "x.text") },
  { op: "x.search", cmux: `sites.x.search("webkit", { limit: 20 })`, "reference-a": `twitter.search("webkit", { count: 20, product: "Latest" })`, cx: list("v", "x.id", "x.text"), ax: list("v.tweets", "x.id", "x.text") },
  // Code trackers (reference A has guides only)
  { op: "github.assigned", cmux: "sites.github.assigned()", "reference-a": null, cx: list("v", "x.url", "x.title") },
  { op: "linear.assigned", cmux: "sites.linear.assigned()", "reference-a": null, cx: list("v", "x.identifier", "x.title") },
  { op: "jira.sites", cmux: "sites.jira.sites()", "reference-a": null, cx: list("v", "x.url", "x.name"), keep: (c) => (ctx.jiraSite = process.env.LIVE_JIRA_SITE || c[0]) },
  { op: "jira.assigned", needs: () => ctx.jiraSite, cmux: () => `sites.jira.search("assignee = currentUser() ORDER BY updated DESC", { site: ${q(ctx.jiraSite)} })`, "reference-a": null, cx: list("v", "x.key", "x.summary") },
  // Browser-level reads
  { op: "tabs.content", cmux: `tabs.content({ urls: ["https://example.com/"], format: "markdown" })`, "reference-a": null, cx: text("v[0].content") },
  { op: "tabs.history", cmux: "tabs.history({ limit: 20 })", "reference-a": null, cx: list("v", "x.url", "x.title") },
  { op: "pageAssets.list", cmux: `(async () => { const p = await tabs.open("https://example.com/", { background: true }); try { return await sites.pageAssets.list(p); } finally { await p.close(); } })()`, "reference-a": null, cx: list("v.assets", "x.url", "x.name") },
];

// Signed-in check: cookie names only on the cmux side, account counts on
// reference A's side (its own lightweight identity calls). Reads no content.
const SIGNED_IN = [
  { site: "google", cookies: [["https://mail.google.com/", /^(SID|__Secure-1PSID)$/]], "reference-a": "(await googleAccounts.list()).length > 0" },
  { site: "youtube", cookies: [["https://www.youtube.com/", /^(SID|__Secure-1PSID|LOGIN_INFO)$/]], "reference-a": "(await googleAccounts.list()).length > 0" },
  { site: "slack", cookies: [["https://app.slack.com/", /^d$/]], "reference-a": "(await slack.listWorkspaces()).filter((w) => w.status === 'joined').length > 0" },
  { site: "notion", cookies: [["https://www.notion.so/", /^token_v2$/], ["https://app.notion.com/", /^token_v2$/]], "reference-a": "(await notion.listAccounts()).length > 0" },
  { site: "linkedin", cookies: [["https://www.linkedin.com/", /^li_at$/]], "reference-a": "!!(await linkedin.getMe())" },
  { site: "x", cookies: [["https://x.com/", /^auth_token$/]], "reference-a": "!!(await twitter.getMe())" },
  { site: "github", cookies: [["https://github.com/", /^user_session$/]], "reference-a": null },
  { site: "linear", cookies: [["https://linear.app/", /session|token/i], ["https://client-api.linear.app/", /session|token/i]], "reference-a": null },
  { site: "jira (atlassian)", cookies: [["https://id.atlassian.com/", /^cloud\.session\.token$/]], "reference-a": null },
];

async function signedIn() {
  const checks = SIGNED_IN.map((s) => `${q(s.site)}: (await Promise.all(${JSON.stringify(s.cookies.map(([u, re]) => [u, re.source, re.flags]))}.map(async ([u, src, fl]) => (await page.context().cookies([u])).some((c) => new RegExp(src, fl).test(c.name))))).some(Boolean)`);
  const cm = parse(await exec(CLI, ["browser", "repl", "--session", SESSION, "--eval", "-"], { input: program(`({ ${checks.join(", ")} })`, "(v) => ({ sites: v })"), timeoutMs: 120000 }));
  const rows = [];
  for (const s of SIGNED_IN) {
    let referenceA = "no tool";
    if (s["reference-a"]) {
      const r = parse(await exec(referenceACli(), ["repl", program(s["reference-a"], "(v) => ({ yes: !!v })", false)], { timeoutMs: 120000 }));
      referenceA = r.ok ? (r.yes ? "signed in" : "not signed in") : `not signed in (${r.code || redact(r.error)})`;
    }
    const c = cm.ok ? (cm.sites[s.site] ? "signed in" : "not signed in") : `unknown (${redact(cm.error)})`;
    rows.push({ site: s.site, cmux: c, "reference-a": referenceA });
  }
  console.table(rows);
  return rows;
}

// Verdict from two summaries.
function verdict(op, c, a, cap) {
  const unavailable = (r) => r.code === "not_signed_in" || /not signed in|sign in|invalid_auth|not_authed|unauthorized|login|logged in|cookie found|cookies missing|session may be expired/i.test(r.error || "");
  if (!c.ok && unavailable(c)) return { verdict: "cmux-unavailable", note: "user not signed in to cmux" };
  if (!a.ok && a.code === "no_tool") return c.ok ? { verdict: "cmux-better", note: "Reference A has no tool for this read" } : { verdict: "cmux-worse", note: `cmux failed: ${c.code || ""} ${redact(c.error)}` };
  if (!a.ok && unavailable(a)) return { verdict: "reference-a-unavailable", note: "Reference A not signed in" };
  if (!c.ok && !a.ok) return { verdict: "same", note: `both failed (cmux ${c.code || redact(c.error)}; reference A ${a.code || redact(a.error)})` };
  if (!c.ok) return { verdict: "cmux-worse", note: `cmux failed: ${c.code || ""} ${redact(c.error)}` };
  if (!a.ok) return { verdict: "cmux-better", note: `Reference A failed: ${a.code || ""} ${redact(a.error)}` };
  if (c.textLen !== undefined || a.textLen !== undefined) {
    const cl = c.textLen || 0;
    const al = a.textLen || 0;
    if (al === 0 && cl === 0) return { verdict: "same", note: "both empty" };
    if (cl >= al * 0.9) return { verdict: cl > al * 1.1 ? "cmux-better" : "same", note: `text ${cl} vs ${al} chars` };
    return { verdict: "cmux-worse", note: `text ${cl} vs ${al} chars` };
  }
  const cc = c.count || 0;
  // A read capped at `cap` items is compared with as many of the other's.
  const ac = cap && cc >= cap ? Math.min(a.count || 0, cap) : a.count || 0;
  const cIds = (c.ids || []).filter(Boolean);
  const aIds = (a.ids || []).filter(Boolean);
  const common = aIds.filter((x) => cIds.includes(x));
  const cover = aIds.length ? common.length / Math.min(aIds.length, Math.max(cIds.length, 1)) : 1;
  let order = null;
  if (common.length > 1) {
    const pos = common.map((x) => cIds.indexOf(x));
    let agree = 0;
    let pairs = 0;
    for (let i = 0; i < pos.length; i++) for (let j = i + 1; j < pos.length; j++) (pairs++, pos[i] < pos[j] && agree++);
    order = pairs ? agree / pairs : 1;
  }
  const note = `count ${cc} vs ${ac}; ids in common ${common.length}${order === null ? "" : `; order agreement ${Math.round(order * 100)}%`}`;
  if (cc >= ac && cover >= 0.8) return { verdict: cc > ac ? "cmux-better" : "same", note };
  if (cc < ac * 0.9 || cover < 0.5) return { verdict: "cmux-worse", note };
  return { verdict: "same", note };
}

const hashed = (r) => {
  const out = { ...r };
  if (out.ids) out.ids = out.ids.map((x) => (x === null ? null : hash(x)));
  if (out.error) out.error = redact(out.error);
  return out;
};

async function run({ ops, runs, writeDoc }) {
  // Google file URLs to read: env first, else cmux's own history (in memory only).
  ctx.files = { document: process.env.LIVE_DOC_URL, spreadsheets: process.env.LIVE_SHEET_URL, presentation: process.env.LIVE_SLIDES_URL };
  if (!ctx.files.document || !ctx.files.spreadsheets || !ctx.files.presentation) {
    const h = parse(await exec(CLI, ["browser", "repl", "--session", SESSION, "--eval", "-"], { input: program(`tabs.history({ query: "docs.google.com", limit: 200 })`, `(v) => ({ ids: v.map((x) => x.url) })`) }));
    for (const kind of ["document", "spreadsheets", "presentation"]) {
      if (ctx.files[kind] || !h.ok) continue;
      const url = h.ids.find((u) => new RegExp(`^https://docs\\.google\\.com/${kind}/(u/\\d+/)?d/[\\w-]+`).test(u));
      if (url) ctx.files[kind] = url;
    }
  }
  const rows = [];
  for (const o of OPS) {
    if (ops && !ops.some((f) => o.op.toLowerCase().includes(f.toLowerCase()))) continue;
    if (o.needs && !o.needs()) {
      rows.push({ op: o.op, verdict: "skipped", note: "no input from an earlier read (see its row)" });
      continue;
    }
    const cExpr = typeof o.cmux === "function" ? o.cmux() : o.cmux;
    const aExpr = typeof o["reference-a"] === "function" ? o["reference-a"]() : o["reference-a"];
    const cRuns = [];
    const aRuns = [];
    for (let i = 0; i < runs; i++) {
      cRuns.push(await runCmux(cExpr, o.cx));
      aRuns.push(await runReferenceA(aExpr, o.ax || o.cx));
    }
    const c = cRuns[cRuns.length - 1];
    const a = aRuns[aRuns.length - 1];
    if (o.keep && c.ok) o.keep(c.ids || []);
    // Reference A's ids feed later steps when cmux has none (so its own reads still run).
    if (o.keep && !c.ok && a.ok) o.keep(a.ids || []);
    const v = verdict(o.op, c, a, o.cap);
    const okRate = (list) => `${list.filter((r) => r.ok).length}/${list.length}`;
    const med = (list) => {
      const ms = list.map((r) => r.ms).filter((x) => typeof x === "number").sort((x, y) => x - y);
      return ms.length ? ms[Math.floor(ms.length / 2)] : null;
    };
    const shapeC = (c.shape || []).join(",");
    const shapeA = (a.shape || []).join(",");
    rows.push({ op: o.op, verdict: v.verdict, note: v.note, cmuxOk: okRate(cRuns), referenceAOk: aExpr ? okRate(aRuns) : "n/a", cmuxMs: med(cRuns), referenceAMs: aExpr ? med(aRuns) : null, cmux: hashed(c), "reference-a": hashed(a), shapes: shapeC || shapeA ? { cmux: shapeC, "reference-a": shapeA } : undefined });
    console.log(`${v.verdict.padEnd(17)} ${o.op.padEnd(34)} ${v.note}  [cmux ${okRate(cRuns)} ${med(cRuns)}ms | reference A ${aExpr ? `${okRate(aRuns)} ${med(aRuns)}ms` : "no tool"}]`);
  }
  fs.mkdirSync(resultsDir, { recursive: true });
  const file = path.join(resultsDir, `live-diff-${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
  fs.writeFileSync(file, JSON.stringify({ when: new Date().toISOString(), runs, rows }, null, 2));
  console.log(`summaries: ${path.relative(repoRoot, file)}`);
  if (writeDoc) writeTable(rows);
  return rows;
}

function writeTable(rows) {
  const begin = "<!-- live-diff:begin -->";
  const end = "<!-- live-diff:end -->";
  const table = [
    begin,
    `Live comparison on ${new Date().toISOString().slice(0, 10)} (counts and lengths only; ids compared as hashes):`,
    "",
    "| Operation | Verdict | Evidence | cmux ok, median ms | Reference A ok, median ms |",
    "| --- | --- | --- | --- | --- |",
    ...rows.map((r) => `| ${r.op} | ${r.verdict} | ${String(r.note || "").replace(/\|/g, "/")} | ${r.cmuxOk || ""} ${r.cmuxMs ?? ""} | ${r.referenceAOk || ""} ${r.referenceAMs ?? ""} |`),
    end,
  ].join("\n");
  let doc = fs.readFileSync(docPath, "utf8");
  if (doc.includes(begin)) doc = doc.slice(0, doc.indexOf(begin)) + table + doc.slice(doc.indexOf(end) + end.length);
  else doc = doc.replace("Tools against private accounts", `${table}\n\nTools against private accounts`);
  fs.writeFileSync(docPath, doc);
}

const [mode, ...rest] = process.argv.slice(2);
const opt = (name) => {
  const i = rest.indexOf(name);
  return i >= 0 ? rest[i + 1] : undefined;
};
if (mode === "signed-in") await signedIn();
else if (mode === "run") await run({ ops: opt("--ops") ? opt("--ops").split(",") : null, runs: Number(opt("--runs") || 1), writeDoc: rest.includes("--write-doc") });
else {
  console.log("usage: live-diff.mjs signed-in | run [--ops a,b] [--runs N] [--write-doc]");
  process.exit(2);
}
