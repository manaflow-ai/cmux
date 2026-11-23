#!/usr/bin/env node
// The JavaScript each shipped web page parses before its first paint, per entry point, against its
// budget in scripts/cmux-next/web-entry-js-budget.json.
//
//   node scripts/cmux-next/web-entry-js.mjs OUT_ROOT [--budget FILE] [--json OUT] [--markdown]
//
// OUT_ROOT is a `build-web-bundles.sh --out-root` folder (or the repository root after an in-tree
// build). Every `index.html` / `*.html` under the shipped bundle folders is an entry point: its
// classic `<script src>` files, its `<script type="module" src>` and `<link rel="modulepreload">`
// files, and every file those reach through static `import`/`export ... from` are its startup set.
// A dynamic `import()` is lazy and not counted: that is the point of the budget (lazy-load heavy
// views, keep the first paint small).
//
// Exit 0 when every budgeted entry is within its cap, 1 when one is over (the table names it),
// 2 on a broken input. An entry with no budget row is listed and never fails, so a new page
// shows up in the table the day it ships. --markdown prints a Markdown table for a job summary.
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// The bundle folders build-web-bundles.sh writes, relative to OUT_ROOT.
const bundleRoots = [
  "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
  "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
  "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
  "Resources/markdown-viewer/webviews-app",
];

function usage(message) {
  if (message) console.error(`web-entry-js: ${message}`);
  console.error("usage: web-entry-js.mjs OUT_ROOT [--budget FILE] [--json OUT] [--markdown]");
  process.exit(2);
}

const args = process.argv.slice(2);
let outRoot = "";
let budgetPath = join(repositoryRoot, "scripts/cmux-next/web-entry-js-budget.json");
let jsonPath = "";
let markdown = false;
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--budget") budgetPath = args[++i] ?? usage("--budget needs a file");
  else if (arg === "--json") jsonPath = args[++i] ?? usage("--json needs a file");
  else if (arg === "--markdown") markdown = true;
  else if (arg === "-h" || arg === "--help") usage();
  else if (!outRoot && !arg.startsWith("-")) outRoot = resolve(arg);
  else usage(`unknown argument ${arg}`);
}
if (!outRoot) usage("OUT_ROOT is required");

let budget;
try {
  budget = JSON.parse(readFileSync(budgetPath, "utf8"));
} catch (error) {
  usage(`cannot read the budget ${budgetPath}: ${error.message}`);
}
const caps = budget.entries ?? {};

function htmlEntries(root) {
  const found = [];
  const walk = (directory) => {
    for (const name of readdirSync(directory)) {
      const path = join(directory, name);
      if (statSync(path).isDirectory()) {
        // Shared chunks and locale tables hold no page of their own.
        if (name !== "chunks" && name !== "__shared" && name !== "locales" && name !== "assets") walk(path);
      } else if (name.endsWith(".html")) {
        found.push(path);
      }
    }
  };
  walk(root);
  return found;
}

const tagPattern = /<(script|link)\b([^>]*)>/gi;
function attribute(attributes, name) {
  const match = new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)')`, "i").exec(attributes);
  return match ? (match[2] ?? match[3]) : null;
}

// The files an HTML page evaluates before first paint. A src built at run time (a locale picked
// in an inline script, `' + locale + '`) is skipped: its English twin is a plain src beside it.
function pageScripts(htmlPath) {
  const html = readFileSync(htmlPath, "utf8");
  const files = [];
  let inlineBytes = 0;
  for (const [, attributes, body] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (!attribute(attributes, "src")) inlineBytes += Buffer.byteLength(body);
  }
  for (const [, tag, attributes] of html.matchAll(tagPattern)) {
    let target = null;
    if (tag.toLowerCase() === "script") target = attribute(attributes, "src");
    else if ((attribute(attributes, "rel") ?? "").toLowerCase() === "modulepreload") target = attribute(attributes, "href");
    if (!target || /^[a-z]+:/i.test(target) || target.startsWith("//") || target.includes("'")) continue;
    // The host answers `__snapshot/...` at run time (the agent pane's last-frame snapshot): no bundle file.
    if (target.startsWith("__snapshot/")) continue;
    files.push(resolve(dirname(htmlPath), target.split(/[?#]/)[0]));
  }
  return { files, inlineBytes };
}

const staticImportPattern = /(?:^|[;}\s])(?:import|export)\s*(?:[^;'"()]*?from\s*)?["']([^"']+)["']/g;
function staticImports(filePath) {
  const source = readFileSync(filePath, "utf8");
  const found = [];
  for (const match of source.matchAll(staticImportPattern)) {
    if (match[1].startsWith(".")) found.push(resolve(dirname(filePath), match[1]));
  }
  return found;
}

function startupSet(entryFiles, problems, label) {
  const seen = new Map();
  const queue = [...entryFiles];
  while (queue.length > 0) {
    const filePath = queue.pop();
    if (seen.has(filePath)) continue;
    if (!existsSync(filePath)) {
      problems.push(`${label}: ${relative(outRoot, filePath)} is referenced but missing`);
      seen.set(filePath, 0);
      continue;
    }
    seen.set(filePath, statSync(filePath).size);
    if (/\.(m?js)$/.test(filePath)) queue.push(...staticImports(filePath));
  }
  return seen;
}

const problems = [];
const rows = [];
for (const bundle of bundleRoots) {
  const root = join(outRoot, bundle);
  if (!existsSync(root)) {
    problems.push(`${bundle} is missing; build it with scripts/cmux-next/build-web-bundles.sh --out-root ${outRoot}`);
    continue;
  }
  for (const htmlPath of htmlEntries(root)) {
    const name = relative(outRoot, htmlPath);
    const page = pageScripts(htmlPath);
    const files = startupSet(page.files, problems, name);
    const bytes = page.inlineBytes + Array.from(files.values()).reduce((sum, size) => sum + size, 0);
    const cap = caps[name]?.max_bytes ?? null;
    rows.push({ entry: name, bytes, files: files.size, cap, over: cap !== null && bytes > cap });
  }
}
if (problems.length > 0) {
  for (const problem of problems) console.error(`error: ${problem}`);
  process.exit(2);
}
rows.sort((left, right) => right.bytes - left.bytes);

const kb = (bytes) => (bytes / 1000).toFixed(1);
const over = rows.filter((row) => row.over);
const total = rows.reduce((sum, row) => sum + row.bytes, 0);
if (markdown) {
  console.log(
    over.length > 0
      ? `**${over.length} web entr${over.length === 1 ? "y is" : "ies are"} over the startup JS budget**`
      : `**Every budgeted web entry is within its startup JS budget** (${rows.length} entries)`,
  );
  console.log("");
  console.log("| entry | startup JS kB | files | budget kB | |");
  console.log("|---|---:|---:|---:|---|");
  for (const row of rows) {
    const short = row.entry.replace(/^Packages\/macOS\/CmuxNext\/Sources\//, "");
    console.log(`| \`${short}\` | ${kb(row.bytes)} | ${row.files} | ${row.cap === null ? "none" : kb(row.cap)} | ${row.over ? "OVER" : ""} |`);
  }
} else {
  for (const row of rows) {
    const state = row.cap === null ? "no budget" : row.over ? `OVER budget ${row.cap}` : `budget ${row.cap}`;
    console.log(`${String(row.bytes).padStart(10)}  ${String(row.files).padStart(4)} files  ${row.entry}  (${state})`);
  }
  console.log(`${rows.length} entries, ${total} startup bytes in all`);
}
if (jsonPath) writeFileSync(jsonPath, `${JSON.stringify({ schema: 1, entries: rows }, null, 2)}\n`);
for (const row of over) {
  console.error(`error: ${row.entry} parses ${row.bytes} bytes of JS at startup, budget ${row.cap}`);
}
process.exit(over.length > 0 ? 1 : 0);
