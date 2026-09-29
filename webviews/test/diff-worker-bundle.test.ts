import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const vendoredWorkerDirectory = resolve(import.meta.dir, "../../Resources/markdown-viewer/diff-viewer/worker-pool");
const packageWorkerDirectory = resolve(import.meta.dir, "../node_modules/@pierre/diffs/dist/worker");

// The main-thread WorkerPoolManager comes from the installed `@pierre/diffs`
// while the highlight worker is served from the vendored copy. Both sides of
// the worker protocol must come from the same package build, and the worker
// must only need the WASM engine file the CLI copies next to it.
test("vendored diff worker matches the installed @pierre/diffs worker", () => {
  for (const name of ["worker-portable.js", "wasm-BaDzIkIn.js"]) {
    expect(readFileSync(resolve(vendoredWorkerDirectory, name), "utf8"))
      .toBe(readFileSync(resolve(packageWorkerDirectory, name), "utf8"));
  }
  const worker = readFileSync(resolve(vendoredWorkerDirectory, "worker-portable.js"), "utf8");
  expect(worker).toContain('import("./wasm-BaDzIkIn.js")');
  expect(/^import\s.*\sfrom\s/m.test(worker)).toBe(false);
});
