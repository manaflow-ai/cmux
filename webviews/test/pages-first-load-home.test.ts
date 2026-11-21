// Home's two pages (Messages and Channels) parsed, before they drew anything, code that never runs in
// the app: the in-browser mock provider with its fixtures (only `?mock` and the gallery use it), and
// the no-results orb, which bundle.mjs inlines as base64 (the pages' CSP allows `img-src data:` only).
// Both now load with `import()`. Bundled the way the app ships them (scripts/pages/bundle.mjs), each
// page's first load (its entry and every chunk it imports statically) carries neither.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Metafile } from "esbuild";

const webviews = path.resolve(import.meta.dir, "..");
const work = mkdtempSync(path.join(tmpdir(), "pages-first-load-home-"));
const PAGES = ["home-messages", "home-channels"];

beforeAll(() => {
  const result = spawnSync("bun", ["scripts/pages/bundle.mjs", work, ...PAGES], {
    cwd: webviews,
    encoding: "utf8",
    timeout: 170_000,
  });
  expect(result.status, result.stderr).toBe(0);
}, 180_000);

afterAll(() => rmSync(work, { recursive: true, force: true }));

test("Home's pages load no mock provider and no inlined art before they draw", () => {
  const { outputs } = JSON.parse(readFileSync(path.join(work, "metafile.json"), "utf8")) as Metafile;
  for (const page of PAGES) {
    const entry = Object.keys(outputs).find((file) => path.resolve(file) === path.join(work, page, "app.js"));
    expect(entry).toBeDefined();
    const seen = new Set([entry!]);
    for (const file of seen) {
      for (const item of outputs[file]!.imports) {
        if (item.kind === "import-statement" && !item.external) seen.add(item.path);
      }
    }
    const unwanted = [...seen].flatMap((file) =>
      Object.keys(outputs[file]!.inputs).filter((input) => input.endsWith(".png") || /\/mockProvider\.ts$/.test(input)),
    );
    expect({ page, unwanted }).toEqual({ page, unwanted: [] });
  }
});
