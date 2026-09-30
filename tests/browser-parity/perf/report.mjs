// Markdown tables from perf/results/*.json (bench.mjs), for
// docs/browser-repl/performance.md.
//
//   node tests/browser-parity/perf/report.mjs before-cmux-dev after-cmux-dev after-cmux ref-chrome ref-aside
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const runs = process.argv.slice(2).map((name) => ({ name, data: JSON.parse(fs.readFileSync(path.join(here, "results", `${name}.json`), "utf8")) }));

// label -> page -> result, one column per tool and run.
const columns = [];
for (const { name, data } of runs) {
  const tools = new Map();
  for (const [page, r] of Object.entries(data.pages)) {
    const byTool = r && r.tools ? r.tools : { [data.backend]: r };
    for (const [tool, v] of Object.entries(byTool)) {
      if (!tools.has(tool)) tools.set(tool, {});
      tools.get(tool)[page] = v;
    }
  }
  for (const [tool, pages] of tools) columns.push({ label: `${tool} (${name.replace(/-[^-]+$/, "").replace(/-cmux$/, "")})`, pages });
}
const pages = [...new Set(runs.flatMap((r) => Object.keys(r.data.pages)))];
const n = (v) => (v === undefined || v === null || Number.isNaN(v) ? "" : Math.round(v).toLocaleString("en-US"));
const cell = (v, f) => (!v ? "" : v.error ? "error" : f(v));

const table = (title, f) => {
  const out = [`### ${title}`, "", `| Page | ${columns.map((c) => c.label).join(" | ")} |`, `| --- | ${columns.map(() => "---:").join(" | ")} |`];
  for (const p of pages) out.push(`| ${p} | ${columns.map((c) => cell(c.pages[p], f)).join(" | ")} |`);
  return out.join("\n");
};

console.log(table("Snapshot time, p50 of 5 (ms; first snapshot in parentheses)", (v) => (v.p50 === undefined ? "" : `${n(v.p50)} (${n(v.firstMs)})`)));
console.log();
console.log(table("Printed characters (what the agent reads by default)", (v) => n(v.printedChars ?? v.printedBytes)));
console.log();
console.log(table("Full tree characters", (v) => n(v.treeChars ?? v.treeBytes)));
console.log();
console.log(table("Snapshot after one change (ms)", (v) => n(v.diff && v.diff.snapMs)));
console.log();
console.log(table("Ref to text through a locator (ms)", (v) => n(v.locatorMs)));
