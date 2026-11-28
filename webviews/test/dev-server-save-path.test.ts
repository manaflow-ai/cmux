// A save reaches the page without work that cannot change it: no Tailwind stylesheet re-send for
// a save that adds no CSS (dev-server/tailwindOnNewClasses.ts), no 16 ms Fast Refresh debounce
// (dev-server/refreshNow.ts), and no fork of the dev server before the hot update is sent
// (dev-server/perfLint.ts lints through one long-lived shell), and no re-read of the saved file's whole
// folder on the save path (dev-server/deferDirRescan.ts).
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { deferRescans } from "../dev-server/deferDirRescan";
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

test("Vite's watcher re-reads a folder after a save, not during it, and still reports added and removed files", async () => {
  const require = createRequire(path.join(WEBVIEWS, "package.json"));
  const { createServer } = await import(require.resolve("vite"));
  const root = mkdtempSync(path.join(scratch, "watch-"));
  writeFileSync(path.join(root, "a.ts"), "export const a = 1;\n");
  const server = await createServer({ root, configFile: false, logLevel: "silent", server: { port: 0 } });
  try {
    // Vite starts watching at createServer; wait until the folder is watched (ready may have fired already).
    const watcher = server.watcher as unknown as { getWatched(): Record<string, string[]> };
    for (let i = 0; i < 100 && !watcher.getWatched()[root]?.includes("a.ts"); i += 1) await Bun.sleep(20);
    expect(watcher.getWatched()[root]).toContain("a.ts");
    const handler = (server.watcher as unknown as { _nodeFsHandler: { _handleRead: Function } })._nodeFsHandler;
    const reads: number[] = [];
    const wrapped = handler._handleRead;
    handler._handleRead = function (this: unknown, ...args: unknown[]) {
      if (!args[1]) reads.push(performance.now());
      return wrapped.apply(this, args);
    };
    // The deferral wraps whatever _handleRead is: a chokidar without it fails here, not silently.
    expect(deferRescans(server.watcher, 150)).toBe(true);
    const changed = new Promise<number>((resolve) => server.watcher.once("change", () => resolve(performance.now())));
    writeFileSync(path.join(root, "a.ts"), "export const a = 2;\n");
    const changeAt = await changed;
    const readsNow = reads.filter((at) => at <= changeAt + 50).length;
    const added = new Promise<void>((resolve) => server.watcher.once("add", () => resolve()));
    writeFileSync(path.join(root, "b.ts"), "export const b = 1;\n");
    await added;
    const removed = new Promise<void>((resolve) => server.watcher.once("unlink", () => resolve()));
    rmSync(path.join(root, "b.ts"));
    await removed;
    expect(readsNow).toBe(0);
    expect(reads.length).toBeGreaterThan(0);
    expect(Math.min(...reads)).toBeGreaterThan(changeAt + 100);
  } finally {
    await server.close();
  }
});
