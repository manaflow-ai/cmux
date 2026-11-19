// A page's PNG ships as base64 inside the JavaScript that imports it (bundle.mjs inlines images: the
// pages' CSP allows `img-src data:` only). Imported statically from a page's own modules, it is parsed
// before the page draws anything; Settings carried all 17 Chief characters (about 850 KB) that way.
// Art a page does not draw at open goes behind `import()` (src/pages/shared/lazyArt.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Metafile } from "esbuild";

const webviews = path.resolve(import.meta.dir, "..");
const pagesRoot = path.join(webviews, "src/pages");

/** Modules that import a PNG statically on purpose: each says why in its own comment. */
const STATIC_ART = new Set([
  // Every character, for the Look card's grid: the chunk ChiefPetCard.tsx loads with `import()`.
  "settings/components/chiefPetArt.ts",
  // The page's empty state is what it draws at open, with no pull request.
  "github/GitHubPage.tsx",
]);

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) return sources(file);
    return /\.(ts|tsx)$/.test(name) && !/\.(test|gallery)\.tsx?$/.test(name) ? [file] : [];
  });
}

test("no page module imports a PNG statically, unless the page draws it at open", () => {
  const offenders = sources(pagesRoot)
    .filter((file) => /^import \w+ from "[^"]+\.png";$/m.test(readFileSync(file, "utf8")))
    .map((file) => path.relative(pagesRoot, file))
    .filter((file) => !STATIC_ART.has(file));
  expect(offenders).toEqual([]);
});

const work = mkdtempSync(path.join(tmpdir(), "pages-first-load-art-"));
const PAGES = ["settings", "home-messages"];

beforeAll(() => {
  const result = spawnSync("bun", ["scripts/pages/bundle.mjs", work, ...PAGES], {
    cwd: webviews,
    encoding: "utf8",
    timeout: 170_000,
  });
  expect(result.status, result.stderr).toBe(0);
}, 180_000);

afterAll(() => rmSync(work, { recursive: true, force: true }));

test("Settings and Home load no mascot art before they draw", () => {
  const { outputs } = JSON.parse(readFileSync(path.join(work, "metafile.json"), "utf8")) as Metafile;
  for (const page of PAGES) {
    const entry = Object.keys(outputs).find((file) => path.resolve(file) === path.join(work, page, "app.js"))!;
    expect(entry).toBeDefined();
    // The page's first load: its entry and every chunk it imports statically.
    const seen = new Set([entry]);
    for (const file of seen) {
      for (const item of outputs[file]!.imports) {
        if (item.kind === "import-statement" && !item.external) seen.add(item.path);
      }
    }
    const art = [...seen].flatMap((file) =>
      Object.keys(outputs[file]!.inputs).filter((input) => input.endsWith(".png")),
    );
    expect({ page, art }).toEqual({ page, art: [] });
  }
});
