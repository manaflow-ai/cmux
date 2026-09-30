// Renders results/results.json as markdown tables (results/summary.md).
//   node tests/browser-parity/compare/report.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const TOOLS = ["cmux", "cmux-i", "cmux-v", "aside", "aside-i", "chatgpt-ax", "chatgpt-dom", "chatgpt-pw", "chatgpt-live-ax", "chatgpt-live-dom", "chatgpt-live-pw", "pw-mcp", "browser-use", "stagehand"];
const pct = (x) => (x == null ? "n/a" : `${Math.round(x * 100)}%`);
const k = (n) => (n == null ? "n/a" : n >= 10000 ? `${(n / 1000).toFixed(0)}k` : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));
const row = (cells) => `| ${cells.join(" | ")} |`;
const header = (cols) => [row(cols), row(cols.map(() => "---"))].join("\n");

function pagesOf(results, kind) {
  return Object.entries(results.pages).filter(([, p]) => p.kind === kind);
}

function micro(pages, tool, field, sub = "recall") {
  let num = 0;
  let den = 0;
  for (const [, p] of pages) {
    const t = p.tools[tool];
    if (t?.invalid) continue;
    const r = t?.[sub];
    if (!r || r.denominator == null) continue;
    num += (r[field] ?? 0) * r.denominator;
    den += r.denominator;
  }
  return den ? num / den : null;
}

export function writeSummary(results, file = path.join(here, "results/summary.md")) {
  const out = [];
  const fixtures = pagesOf(results, "fixture");
  const live = pagesOf(results, "live");
  const corpus = pagesOf(results, "corpus");
  out.push(`# Representation comparison results\n\nTokenizer: ${results.tokenizer}. Viewport ${results.viewport}. Versions: ${JSON.stringify(results.versions ?? {})}.\n`);

  out.push("## Size (tokens) per page\n");
  out.push(header(["page", ...TOOLS]));
  const cell = (p, t, v) => (p.tools[t]?.error ? "err" : p.tools[t]?.invalid ? `${v} (${p.tools[t].invalid.split(" ")[0]})` : v);
  for (const [name, p] of [...fixtures, ...corpus, ...live]) out.push(row([name, ...TOOLS.map((t) => cell(p, t, k(p.tools[t]?.tokens)))]));
  // Totals only over pages every tool captured validly.
  // A frozen copy stands in for its live page only when the live capture
  // was not valid for every tool.
  // Tools that did not capture a set at all (live ChatGPT on live sites) are
  // left out of that set's totals.
  const allValid = (p) => TOOLS.every((t) => !p.tools[t] || (!p.tools[t].invalid && !p.tools[t].error));
  const common = (set) => set.filter(([n, p]) => allValid(p) && !(n.endsWith("-frozen") && results.pages[n.replace(/-frozen$/, "")] && allValid(results.pages[n.replace(/-frozen$/, "")])));
  for (const [label, set] of [["fixtures total", common(fixtures)], ["corpus total", common(corpus)], ["live total", common(live)]]) {
    if (!set.length) continue;
    out.push(row([`**${label}** (${set.map(([n]) => n).join(", ").slice(0, 60)})`, ...TOOLS.map((t) => (set.every(([, p]) => p.tools[t]) ? k(set.reduce((a, [, p]) => a + (p.tools[t]?.tokens ?? 0), 0)) : "n/a"))]));
  }

  // Cost per element the model can find and act on.
  out.push("\n## Tokens per addressable visible element (common live pages)\n");
  out.push(header(["set", ...TOOLS]));
  {
    const set = common(live).filter(([, p]) => p.tools.cmux);
    out.push(row([set.map(([n]) => n).join(", "), ...TOOLS.map((t) => {
      let tok = 0;
      let hit = 0;
      for (const [, p] of set) {
        tok += p.tools[t]?.tokens ?? 0;
        hit += (p.tools[t]?.recall?.lenient ?? 0) * (p.tools[t]?.recall?.denominator ?? 0);
      }
      return hit ? (tok / hit).toFixed(1) : "n/a";
    })]));
  }

  out.push("\n## Addressable interactive recall (lenient; strict in parentheses)\n");
  out.push(header(["page", "GT", ...TOOLS]));
  for (const [name, p] of [...fixtures, ...corpus, ...live]) {
    out.push(row([name, String(p.groundTruth?.interactiveVisibleNamed ?? "?"), ...TOOLS.map((t) => {
      const r = p.tools[t]?.recall;
      return r ? cell(p, t, `${pct(r.lenient)} (${pct(r.strict)})`) : p.tools[t]?.error ? "err" : "-";
    })]));
  }
  for (const [label, set] of [["fixtures (micro)", fixtures], ["corpus (micro)", corpus], ["live (micro)", live]]) {
    if (!set.length) continue;
    out.push(row([`**${label}**`, "", ...TOOLS.map((t) => `${pct(micro(set, t, "lenient"))} (${pct(micro(set, t, "strict"))})`)]));
  }
  out.push("\n## In-viewport recall (lenient)\n");
  out.push(header(["set", ...TOOLS]));
  for (const [label, set] of [["fixtures", fixtures], ["corpus", corpus], ["live", live]]) if (set.length) out.push(row([label, ...TOOLS.map((t) => pct(micro(set, t, "lenient", "recallViewport")))]));

  out.push("\n## Precision and hidden-content leaks\n\nCell: leaked interactive items / interactive items emitted (+ hidden items the tool flags as hidden), leaked hidden texts / hidden texts on the page.\n");
  out.push(header(["page", ...TOOLS]));
  for (const [name, p] of [...fixtures, ...corpus, ...live]) {
    out.push(row([name, ...TOOLS.map((t) => {
      const pr = p.tools[t]?.precision;
      return pr ? cell(p, t, `${pr.leakedItems}/${pr.widgetItems}${pr.flaggedHidden ? ` (+${pr.flaggedHidden} flagged)` : ""}, ${pr.leakedTexts}/${pr.hiddenTexts}`) : "-";
    })]));
  }

  const probeRows = {};
  for (const [, p] of fixtures) for (const [t, r] of Object.entries(p.structure ?? {})) for (const [id, v] of Object.entries(r)) ((probeRows[id] ??= { category: v.category })[t] = v.pass);
  out.push("\n## Structure probes\n");
  out.push(header(["probe", ...TOOLS]));
  const totals = Object.fromEntries(TOOLS.map((t) => [t, [0, 0]]));
  for (const [id, r] of Object.entries(probeRows).sort((a, b) => a[1].category.localeCompare(b[1].category))) {
    out.push(row([`${r.category}: ${id}`, ...TOOLS.map((t) => (t in r ? (r[t] ? "yes" : "**no**") : "-"))]));
    for (const t of TOOLS) if (t in r) {
      totals[t][1]++;
      if (r[t]) totals[t][0]++;
    }
  }
  out.push(row(["**passed**", ...TOOLS.map((t) => `${totals[t][0]}/${totals[t][1]}`)]));

  for (const key of ["change", "changeBig"]) {
    const ch = results.scenarios?.[key];
    if (!ch) continue;
    out.push(`\n## Change reporting (${key === "change" ? "small form page" : "big page, ~300 elements"})\n`);
    out.push(header(["tool", "output after action", "full", "shown/full", "value", "checked", "focus"]));
    for (const t of TOOLS) {
      const c = ch[t];
      if (!c) continue;
      out.push(row([t, c.mode, `${k(c.fullBytes)} B`, pct(c.ratio), c.showsValue ? "yes" : "no", c.showsChecked ? "yes" : "no", c.focused ? "yes" : "no"]));
    }
  }
  const flow = results.scenarios?.actionFlow;
  if (flow) {
    out.push("\n## Action flow (fill Email, check terms, submit; what the tool prints next)\n");
    out.push(header(["tool", "printed", "full", "value", "checked", "submit result"]));
    for (const t of TOOLS) {
      const c = flow[t];
      if (!c) continue;
      out.push(row([t, `${k(c.shownBytes)} B`, `${k(c.fullBytes)} B`, c.showsValue ? "yes" : "no", c.showsChecked ? "yes" : "no", c.showsSubmitResult ? "yes" : "no"]));
    }
  }
  if (results.offlineVsLive && Object.keys(results.offlineVsLive).length) {
    out.push("\n## Offline stand-ins vs live ChatGPT (lines shared / offline lines / live lines, bytes offline to live)\n");
    out.push(header(["page", "chatgpt-ax vs live", "chatgpt-dom vs live", "chatgpt-pw vs live"]));
    for (const [name, r] of Object.entries(results.offlineVsLive)) {
      out.push(row([name, ...["chatgpt-ax", "chatgpt-dom", "chatgpt-pw"].map((t) => (r[t] ? `${r[t].identical ? "identical " : ""}${r[t].sameLines}/${r[t].offlineLines}/${r[t].liveLines}, ${k(r[t].offlineBytes)} to ${k(r[t].liveBytes)} B` : "-"))]));
    }
  }
  const refs = results.scenarios?.refs;
  if (refs) {
    out.push("\n## Ref stability\n");
    out.push(header(["tool", "before", "after", "survivors keep ref", "removed ref reused", "old refs after new snapshot"]));
    for (const t of TOOLS) {
      const r = refs[t];
      if (!r) continue;
      const fmt = (o) => Object.entries(o ?? {}).map(([n, v]) => `${n}=${v ?? "none"}`).join(", ");
      const old = r.oldRefsAfterNewSnapshot ? Object.entries(r.oldRefsAfterNewSnapshot).map(([n, v]) => `${n}: ${v.text != null ? JSON.stringify(v.text) : v.error ? v.error.slice(0, 50) : "no ref"}`).join("; ") : "-";
      out.push(row([t, fmt(r.r1), fmt(r.r2), r.addressable ? (r.survivorsKeepRef ? "yes" : "**no**") : "no refs", r.addressable ? (r.removedRefReused ? "**yes**" : "no") : "-", old]));
    }
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, out.join("\n") + "\n");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeSummary(JSON.parse(fs.readFileSync(path.join(here, "results/results.json"), "utf8")));
}
