#!/usr/bin/env bun
// Per-step before/after for two intro-walk reports (scripts/intro-walk.mjs --out).
// Each step is keyed by arm, width and step name, so a variant run and a base run
// line up row for row. It prints only the steps whose numbers moved, plus one
// summary line, so a [taste] batch or a regression reads as a list of named
// steps with numbers instead of one pass_share.
//
//   bun scripts/intro-walk-diff.mjs before.json after.json [--json]
//
// Exit 0 always; the walk itself owns pass/fail.
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const [beforePath, afterPath] = args.filter((a) => !a.startsWith("--"));
if (!beforePath || !afterPath) {
  console.error("usage: intro-walk-diff.mjs before.json after.json [--json]");
  process.exit(2);
}

const load = (p) => JSON.parse(readFileSync(p, "utf8"));

function rows(report) {
  const out = new Map();
  for (const walk of report.walks ?? []) {
    for (const s of walk.steps ?? []) {
      out.set(`${walk.arm}|${walk.width}|${s.step}`, {
        cls: s.cls ?? 0,
        previewCls: s.previewCls ?? 0,
        moved: (s.moved ?? []).length,
        shifted: (s.shifted ?? []).length,
        shown: s.shown !== false,
      });
    }
    out.set(`${walk.arm}|${walk.width}|skip`, {
      skipRestores: walk.skipRestores !== false,
      footerCovered: (walk.footerCovered ?? []).length,
    });
  }
  return out;
}

const before = load(beforePath);
const after = load(afterPath);
const a = rows(before);
const b = rows(after);
const changed = [];
for (const key of new Set([...a.keys(), ...b.keys()])) {
  const x = a.get(key);
  const y = b.get(key);
  if (!x || !y) {
    changed.push({ key, before: x ?? null, after: y ?? null });
    continue;
  }
  const fields = Object.keys({ ...x, ...y }).filter((f) => x[f] !== y[f]);
  if (fields.length) changed.push({ key, fields, before: x, after: y });
}

const summary = {
  pass_share: [before.pass_share, after.pass_share],
  passed: [before.passed, after.passed],
  checks: [before.checks, after.checks],
  cls_max: [before.cls_max, after.cls_max],
  failures: [(before.failures ?? []).length, (after.failures ?? []).length],
  steps_changed: changed.length,
};

if (asJson) {
  console.log(JSON.stringify({ summary, changed }, null, 2));
} else {
  for (const c of changed) {
    if (!c.before || !c.after) {
      console.log(`${c.key}: ${c.before ? "gone" : "new"}`);
      continue;
    }
    const parts = c.fields.map((f) => `${f} ${c.before[f]} -> ${c.after[f]}`);
    console.log(`${c.key}: ${parts.join(", ")}`);
  }
  const fmt = (k) => `${k} ${summary[k][0]} -> ${summary[k][1]}`;
  console.log(
    `intro-walk-diff: ${["pass_share", "passed", "checks", "cls_max", "failures"].map(fmt).join(", ")}, steps changed ${changed.length}`,
  );
}
