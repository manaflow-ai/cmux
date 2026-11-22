// Settings opens to content fast: its startup script holds the frame, the schema rows and the
// sidebar, and every card (with its art and catalogs) is a chunk read with its section
// (components/cardModules.tsx). This walks the static imports from the page's entry, as the
// bundler does, and holds that no card module, no Chief character art and no mock fixture is in it;
// and that a section's ensure loads its cards before it resolves, so none draws a frame late.
import { afterAll, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());

const here = path.dirname(fileURLToPath(import.meta.url));
const transpilers = { ts: new Bun.Transpiler({ loader: "ts" }), tsx: new Bun.Transpiler({ loader: "tsx" }) };

/** A relative specifier as a file on disk, or null for a package or an asset the bundler inlines. */
function resolve(from: string, specifier: string): string | null {
  if (!specifier.startsWith(".")) return null;
  const base = path.resolve(path.dirname(from), specifier);
  const candidates = [base, `${base}.ts`, `${base}.tsx`, path.join(base, "index.ts"), path.join(base, "index.tsx")];
  return candidates.find((candidate) => /\.(tsx?|png|json|css)$/.test(candidate) && existsSync(candidate)) ?? null;
}

/** Every file the entry reaches through static imports (dynamic `import()`s are chunks). */
function staticClosure(entry: string): Set<string> {
  const seen = new Set<string>();
  const queue = [entry];
  while (queue.length) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    if (!/\.tsx?$/.test(file)) continue;
    const transpiler = file.endsWith(".tsx") ? transpilers.tsx : transpilers.ts;
    for (const item of transpiler.scanImports(readFileSync(file, "utf8"))) {
      if (item.kind !== "import-statement") continue;
      const next = resolve(file, item.path);
      if (next) queue.push(next);
    }
  }
  return seen;
}

test("the page's startup script carries no card, no Chief character art and no mock fixture", () => {
  const closure = [...staticClosure(path.join(here, "main.tsx"))].map((file) => path.relative(here, file));
  const cardModules = readFileSync(path.join(here, "components/cardModules.tsx"), "utf8");
  const cards = [...cardModules.matchAll(/import\("\.\/([A-Za-z]+)"\)/g)].map((match) => `components/${match[1]}.tsx`);
  expect(cards.length).toBeGreaterThan(30);
  expect(closure.filter((file) => cards.includes(file))).toEqual([]);
  expect(closure.filter((file) => file.includes("/mascots/"))).toEqual([]);
  expect(closure.filter((file) => /(^|\/)mock[A-Z][A-Za-z]*\.ts$/.test(file))).toEqual([]);
});

test("a section's ensure loads its cards before it resolves", async () => {
  const { createMockClient } = await import("./mockProvider");
  const { SettingsStore } = await import("./store");
  const { ensureSection } = await import("./sectionQueries");
  const { loadCard } = await import("./components/cardModules");
  const { categoryById } = await import("./categories");
  const mock = createMockClient();
  const store = new SettingsStore(mock.client);
  await store.start();
  const cards = [...categoryById("appearance").lead, ...categoryById("appearance").trail];
  expect(cards.length).toBeGreaterThan(0);
  await ensureSection(store.queryClient, store, "appearance");
  for (const card of cards) expect(loadCard(card).status).toBe("fulfilled");
  store.dispose();
  mock.close();
});
