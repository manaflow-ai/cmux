// A save reaches the page without work that cannot change it: no Tailwind stylesheet re-send for
// a save that adds no CSS (dev-server/tailwindOnNewClasses.ts), no 16 ms Fast Refresh debounce
// (dev-server/refreshNow.ts), and no fork of the dev server before the hot update is sent
// (dev-server/perfLint.ts lints through one long-lived shell).
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { perfLinter } from "../dev-server/perfLint";
import { refreshInMicrotask } from "../dev-server/refreshNow";
import { addsCss, twinOf } from "../dev-server/tailwindTwin.mjs";

const WEBVIEWS = path.resolve(import.meta.dir, "..");
const scratch = mkdtempSync(path.join(tmpdir(), "cmux-save-path-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

test("plugin-react's refresh runtime refreshes in a microtask, not after 16 ms", () => {
  const require = createRequire(path.join(WEBVIEWS, "package.json"));
  const runtime = path.join(
    path.dirname(require.resolve("@vitejs/plugin-react/package.json")),
    "dist/refresh-runtime.js",
  );
  const result = refreshInMicrotask(readFileSync(runtime, "utf8"));
  expect(result.changed).toBe(true);
  expect(result.code).toContain("queueMicrotask(");
  expect(result.code).not.toMatch(/enqueueUpdate = debounce\(/);
});

test("a save re-sends a Tailwind stylesheet only when it adds CSS", async () => {
  const stylesheet = path.join(WEBVIEWS, "src/styles.css");
  const twin = await twinOf(stylesheet, WEBVIEWS);
  // Words that are not utilities, and utilities the stylesheet already has, add nothing.
  expect(addsCss(twin, `<div data-hot-reload-probe="r7" className="flex" />`, "tsx")).toBe(false);
  expect(addsCss(twin, `const label = "r8 probe-word"`, "tsx")).toBe(false);
  // A utility nothing used yet adds CSS once; the same save again adds nothing. (Made here, not
  // written out: the twin scans this file too.)
  const save = `<div className="${["tracking", `[0.${process.pid}em]`].join("-")}" />`;
  expect(addsCss(twin, save, "tsx")).toBe(true);
  expect(addsCss(twin, save, "tsx")).toBe(false);
  // The twin scans all of webviews/ first, as the plugin does: seconds, more on a loaded runner.
}, 60_000);

test("perf lint runs every save through one shell and answers each in order", async () => {
  const vp = path.join(scratch, "vp");
  const calls = path.join(scratch, "calls");
  // A stand-in `vp lint`: one finding naming the file it was given.
  writeFileSync(
    vp,
    `#!/bin/sh\nfor f; do last="$f"; done\necho "$PPID" >> "${calls}"\nprintf '{"diagnostics":[{"filename":"%s","code":"cmux-perf(x)","message":"m","labels":[{"span":{"line":3}}]}]}' "$last"\n`,
  );
  chmodSync(vp, 0o755);
  const linter = perfLinter(vp, "/dev/null");
  try {
    const [a, b] = await Promise.all([
      linter.lint(path.join(WEBVIEWS, "src/a.tsx")),
      linter.lint(path.join(WEBVIEWS, "src/b.tsx")),
    ]);
    expect(a).toEqual([{ file: "src/a.tsx", line: 3, rule: "cmux-perf/x", message: "m" }]);
    expect(b).toEqual([{ file: "src/b.tsx", line: 3, rule: "cmux-perf/x", message: "m" }]);
    // Both lints ran under the same shell.
    expect(new Set(readFileSync(calls, "utf8").trim().split("\n")).size).toBe(1);
  } finally {
    linter.close();
  }
});
