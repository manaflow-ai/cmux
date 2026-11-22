// A row that only says its work ended keeps its quiet ink: no rule for a finished, done or ended
// state draws the success green (Leo, 2026-11-14: "why ... does worked for turn green after it's
// done"). The finish moment of a long turn (finish/finish.css) tinted the "Worked for" label green
// for 700 ms, and with Reduce Motion held it there; a subagent line's done check and a finished
// session's status word drew the same green. Green stays for a result that passed (checks, an open
// or approved pull request, a verified connection), never for "it stopped running".
//
// The detector reads every shipped stylesheet of the agent chat (galleries hold rejected looks and
// are skipped) and fails on a rule whose selector names a finished state and whose body draws
// `--agent-status-success`.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "..");

/// Selectors of a state that only says the work ended.
const FINISHED =
  /\.cv-worked\b|\.cv-finish-check\b|\.acpmux-done-mark__check\b|\[data-status="?done"?\]|\[data-finished\]|\[data-done-check\]/;

/// Finished-looking selectors whose green says a result passed, each with why.
const PASSED = new Map<string, string>([
  // "GitHub connected · owner/repo attached": the recovery's verified result, not the end of a run.
  [".cv-repo-recovery--done", "a verified connection"],
]);

function rules(css: string): { selector: string; body: string }[] {
  const out: { selector: string; body: string }[] = [];
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const pattern = /([^{}]+)\{([^{}]*)\}/g;
  for (let match = pattern.exec(text); match; match = pattern.exec(text))
    out.push({ selector: match[1]!.trim(), body: match[2]! });
  return out;
}

test("no finished, done or ended state draws the success green", () => {
  const files = [...new Bun.Glob("**/*.css").scanSync(ROOT)].filter((file) => !file.includes(".gallery."));
  expect(files.length).toBeGreaterThan(10);
  const found: string[] = [];
  for (const file of files) {
    for (const { selector, body } of rules(readFileSync(path.join(ROOT, file), "utf8"))) {
      if (!body.includes("--agent-status-success")) continue;
      for (const one of selector.split(",").map((part) => part.trim())) {
        if (!FINISHED.test(one) || [...PASSED.keys()].some((kept) => one.includes(kept))) continue;
        found.push(`${file}: ${one}`);
      }
    }
  }
  expect(found).toEqual([]);
});

test("the detector catches the old Worked for tint", () => {
  const old = `.cv-worked[data-finish] > .cv-worked__label { color: var(--agent-status-success); }
@keyframes cv-finish-tint { 0%, 55% { color: var(--agent-status-success); } }`;
  const hits = rules(old).filter(
    ({ selector, body }) => FINISHED.test(selector) && body.includes("--agent-status-success"),
  );
  expect(hits.map((hit) => hit.selector)).toEqual([".cv-worked[data-finish] > .cv-worked__label"]);
});
