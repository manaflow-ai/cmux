// The pages' strings tables are build output (#21946). Committed copies made every pull request
// that touched a catalog or the settings schema conflict with every other one, and an autofix that
// rebuilt one from a stale schema dropped another branch's labels. No branch may carry them.
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LOCALES, PAGES, writeStrings } from "../scripts/pages/gen-strings.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const git = (...args: string[]) => execFileSync("git", args, { cwd: repo, encoding: "utf8" });

function outputs(): string[] {
  const pages = Object.values(PAGES) as { out: string; splitLocales?: boolean }[];
  return pages.flatMap((page) => {
    const out = page.out;
    if (!page.splitLocales) return [out];
    const dir = path.posix.dirname(out);
    return [out, `${dir}/localeLoaders.ts`, ...LOCALES.map((locale) => `${dir}/locales/${locale}.json`)];
  });
}

test("no strings table gen-strings.mjs writes is tracked", () => {
  expect(git("ls-files", "--", ...outputs()).trim()).toBe("");
});

test("every strings table gen-strings.mjs writes is ignored", () => {
  const files = outputs();
  // check-ignore --no-index tests the path rules alone, so a tracked copy still counts as ignored here.
  const ignored = git("check-ignore", "--no-index", "--", ...files)
    .trim()
    .split("\n");
  expect(ignored.sort()).toEqual([...files].sort());
});

// test/preload.ts writes the agent pane's table in every `bun test` process. A touch of a current
// table is a change to every agent pane dev server watching it, which full-reloads the page of each
// browser test running beside that process (agent-pane-older-rows-fade lost its page mid-test that way).
test("writing an unchanged table that is already current leaves it untouched", () => {
  writeStrings({ only: ["agentPane"], bestEffort: true, log: () => {} });
  const table = path.join(repo, PAGES.agentPane.out);
  const inputs = [
    path.join(repo, "webviews/scripts/pages/gen-strings.mjs"),
    ...PAGES.agentPane.catalogs.map((catalog: { file: string }) => path.join(repo, catalog.file)),
  ];
  // Newer than every input but in the past, so a touch (to now) would show.
  const current = new Date(Math.max(...inputs.map((file) => fs.statSync(file).mtimeMs)) + 1000);
  fs.utimesSync(table, current, current);
  const before = fs.statSync(table).mtimeMs;
  writeStrings({ only: ["agentPane"], bestEffort: true, log: () => {} });
  expect(fs.statSync(table).mtimeMs).toBe(before);
});
