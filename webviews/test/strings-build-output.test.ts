// The pages' strings tables are build output (#21946). Committed copies made every pull request
// that touched a catalog or the settings schema conflict with every other one, and an autofix that
// rebuilt one from a stale schema dropped another branch's labels. No branch may carry them.
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LOCALES, PAGES } from "../scripts/pages/gen-strings.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const git = (...args: string[]) => execFileSync("git", args, { cwd: repo, encoding: "utf8" });

function outputs(): string[] {
  return Object.values(PAGES).flatMap((page) => {
    const out = page.out as string;
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
  const ignored = git("check-ignore", "--no-index", "--", ...files).trim().split("\n");
  expect(ignored.sort()).toEqual([...files].sort());
});
