// The compiler-bail ratchet (scripts/check-compiler-bails.mjs): which files a change makes it check.
import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { changedSources } from "../scripts/check-compiler-bails.mjs";

const dir = mkdtempSync(path.join(tmpdir(), "compiler-bails-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));
const list = (...files: string[]) => {
  const file = path.join(dir, `${files.length}-${Math.random()}.txt`);
  writeFileSync(file, files.map((f) => `${f}\n`).join(""));
  return file;
};

test("no list checks every file", () => {
  expect(changedSources(undefined)).toBeNull();
  expect(changedSources(path.join(dir, "missing.txt"))).toBeNull();
});

test("a change under src/ checks only its agent-chat files", () => {
  expect(
    changedSources(
      list("webviews/src/agent-session/acpmux/a.tsx", "webviews/src/other/b.ts", "Packages/x.swift", "web/app/c.tsx"),
    ),
  ).toEqual(["src/agent-session/acpmux/a.tsx"]);
  expect(changedSources(list("Packages/x.swift"))).toEqual([]);
});

test("a change to webviews/ outside src/ (the script, the baseline, the lockfile, the config) checks every file", () => {
  for (const other of [
    "webviews/scripts/compiler-bails-baseline.tsv",
    "webviews/scripts/check-compiler-bails.mjs",
    "webviews/bun.lock",
    "webviews/reactCompiler.mjs",
  ])
    expect(changedSources(list("webviews/src/agent-session/acpmux/a.tsx", other))).toBeNull();
});
