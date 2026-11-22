// Feature tips come from the What's New highlights (release-notes/next/highlights/*.md), so one
// file drives a feature's What's New entry and its tip (leo-workspace design/feature-tips.md). A
// highlight gets a tip with a `tip:` line naming the control the tip points at (a page's anchor
// table, e.g. `tip: agent.browser`); the tip is the highlight's title and the first sentence of
// its body. Only New and Improved highlights carry one.
//
// src/ui/featureTips/tips.generated.json is build output, ignored by git like the pages' strings
// tables: every run of gen-strings.mjs (install, the webview and bundle builds, the gallery) writes
// it too, and test/preload.ts writes it before any test reads it.
//
//   node scripts/pages/gen-feature-tips.mjs [--check]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const HIGHLIGHTS = path.join(repo, "release-notes/next/highlights");
export const GENERATED = path.join(repo, "webviews/src/ui/featureTips/tips.generated.json");

/** The body's first whole sentence. */
export function firstSentence(body) {
  const match = /^.+?[.!?](?=\s+[A-Z0-9"“(]|$)/.exec(body);
  return (match ? match[0] : body).trim();
}

/** The tip a highlight file declares ({id, anchor, title, body}), or null. Throws on a `tip:` line it cannot use. */
export function highlightTip(file, text) {
  const [head = "", ...rest] = text.replace(/\r\n/g, "\n").split("\n\n");
  const meta = new Map();
  for (const line of head.split("\n")) {
    const colon = line.indexOf(":");
    if (colon > 0) meta.set(line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim());
  }
  const anchor = meta.get("tip");
  if (!anchor) return null;
  const id = file.replace(/^.*\//, "").replace(/\.md$/, "");
  const category = meta.get("category") ?? "new";
  if (category !== "new" && category !== "improved")
    throw new Error(`${file}: a tip goes on a New or Improved highlight`);
  if (!/^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$/.test(anchor))
    throw new Error(`${file}: tip: names a control id (agent.browser)`);
  const title = meta.get("title");
  const body = rest.join(" ").replace(/\s+/g, " ").trim();
  if (!title || !body) throw new Error(`${file}: a tip needs the highlight's title and body`);
  return { id, anchor, title, body: firstSentence(body) };
}

/** Every tip of a set of highlight files, by id. */
export function tipsFromHighlights(files) {
  return files
    .map(({ file, text }) => highlightTip(file, text))
    .filter((tip) => tip !== null)
    .sort((a, b) => a.id.localeCompare(b.id));
}

/** The file's text for this tree's highlights. */
export function generatedTips() {
  const files = fs
    .readdirSync(HIGHLIGHTS)
    .filter((name) => name.endsWith(".md"))
    .map((name) => ({ file: name, text: fs.readFileSync(path.join(HIGHLIGHTS, name), "utf8") }));
  return `${JSON.stringify(tipsFromHighlights(files), null, 2)}\n`;
}

/** Writes the file (or with `check`, compares it); unchanged text is not rewritten. Returns 1 on a stale check. */
export function writeFeatureTips({ check = false, log = console.error } = {}) {
  const next = generatedTips();
  const current = fs.existsSync(GENERATED) ? fs.readFileSync(GENERATED, "utf8") : null;
  if (check) {
    if (current === next) return 0;
    log(`${path.relative(repo, GENERATED)} is stale or missing: run node webviews/scripts/pages/gen-feature-tips.mjs`);
    return 1;
  }
  if (current !== next) fs.writeFileSync(GENERATED, next);
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(writeFeatureTips({ check: process.argv.includes("--check") }));
}
