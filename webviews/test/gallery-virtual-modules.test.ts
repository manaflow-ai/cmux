// Every virtual:cmux-gallery/* module that src/gallery/virtual.d.ts declares resolves in every gallery runner:
// each Vite config that serves or builds gallery files (bun run dev, gallery:dev, gallery:build, the guest page and
// Chief web) and bun's own runners (manifest.ts, touched.ts, notes.ts: gallery health and the visual evidence
// capture). cmux#46783 added `looks` to the Vite plugin only, and every gallery health shard then failed in
// `bun scripts/gallery/manifest.ts` with "Cannot find module 'virtual:cmux-gallery/looks'"; behind it, a gallery
// fixture whose module read `window` at load (CloudStartView.gallery.tsx) failed the same command.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { GALLERY_CSS_MODULE_ID, GALLERY_DATA_MODULES } from "../dev-server/galleryHost";

const webviews = path.resolve(import.meta.dir, "..");

function declaredIds(): string[] {
  const source = fs.readFileSync(path.join(webviews, "src/gallery/virtual.d.ts"), "utf8");
  return [...source.matchAll(/declare module "(virtual:cmux-gallery\/[^"]+)"/g)].map((match) => match[1]!);
}

/** Each Vite config whose pages import gallery files or the pane sheet. */
const VITE_CONFIGS = [
  "vite.config.ts",
  "vite.config.gallery.ts",
  "vite.config.gallery-dev.ts",
  "vite.config.guest-page.mjs",
  "vite.config.chief-web.mjs",
];

type ResolvingPlugin = { name?: string; resolveId?: unknown };

async function configPlugins(file: string): Promise<ResolvingPlugin[]> {
  const loaded = (await import(path.join(webviews, file))).default as unknown;
  const config = (typeof loaded === "function" ? await loaded({ command: "build", mode: "production" }) : loaded) as {
    plugins?: unknown[];
  };
  const plugins = await Promise.all([config.plugins ?? []].flat(Infinity as 1));
  return plugins
    .flat(Infinity as 1)
    .filter((plugin): plugin is ResolvingPlugin => Boolean(plugin && typeof plugin === "object"));
}

async function resolvedBy(plugins: ResolvingPlugin[], id: string): Promise<boolean> {
  for (const plugin of plugins) {
    const hook = plugin.resolveId;
    const handler = typeof hook === "function" ? hook : (hook as { handler?: unknown } | undefined)?.handler;
    if (typeof handler !== "function") continue;
    const context = { resolve: async () => null, info: () => undefined, warn: () => undefined };
    const result = await handler.call(context, id, path.join(webviews, "src/gallery/frame/main.ts"), {});
    if (result) return true;
  }
  return false;
}

describe("virtual:cmux-gallery modules", () => {
  const ids = declaredIds();

  test("virtual.d.ts declares the modules this test checks", () => {
    expect(ids).toContain("virtual:cmux-gallery/looks");
    expect(ids.length).toBeGreaterThanOrEqual(8);
  });

  test("galleryHost's one table serves every declared module", () => {
    const served = [...Object.keys(GALLERY_DATA_MODULES), GALLERY_CSS_MODULE_ID].sort();
    expect(served).toEqual([...ids].sort());
  });

  for (const file of VITE_CONFIGS)
    test(`${file} resolves every declared module`, async () => {
      const plugins = await configPlugins(file);
      const missing: string[] = [];
      for (const id of ids) if (!(await resolvedBy(plugins, id))) missing.push(id);
      expect(missing).toEqual([]);
    });

  // A child process: no test preload (its jsdom window and Bun plugins), as gallery health runs it.
  test("bun's runner loads every module and every gallery file (gallery health's manifest command)", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gallery-virtual-modules-"));
    const probe = path.join(webviews, `.gallery-virtual-modules-probe-${process.pid}.ts`);
    fs.writeFileSync(
      probe,
      `import "./scripts/gallery/entries";
const ids = ${JSON.stringify(ids)};
const out: Record<string, string> = {};
for (const id of ids) out[id] = typeof (await import(id)).default;
console.log(JSON.stringify(out));
`,
    );
    try {
      const modules = Bun.spawnSync(["bun", probe], { cwd: webviews, stdout: "pipe", stderr: "pipe" });
      expect(modules.stderr.toString()).toBe("");
      const types = JSON.parse(modules.stdout.toString()) as Record<string, string>;
      // The pane sheet has no export under bun; each data module exports its data.
      const empty = ids.filter((id) => id !== GALLERY_CSS_MODULE_ID && types[id] === "undefined");
      expect(Object.keys(types).sort()).toEqual([...ids].sort());
      expect(empty).toEqual([]);

      const out = path.join(dir, "manifest.json");
      const manifest = Bun.spawnSync(
        ["bun", "scripts/gallery/manifest.ts", "--frame", "component", "--limit", "1", "--out", out],
        { cwd: webviews, stdout: "pipe", stderr: "pipe" },
      );
      expect(manifest.exitCode, manifest.stderr.toString()).toBe(0);
      expect(fs.existsSync(out)).toBe(true);
    } finally {
      fs.rmSync(probe, { force: true });
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }, 120_000);
});
