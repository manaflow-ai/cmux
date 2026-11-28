// The agent pane's site table (scripts/agent-pane/frameSites.mjs, bundle.mjs --frame-sites): a
// minified, split bundle's stack position resolves to the source file it came from
// (frameOwners.ts resolveSite), the source maps it was read from are deleted, and the scripts carry
// no source map comment.
/// <reference types="bun" />
import { afterAll, expect, test } from "bun:test";
import { build } from "esbuild";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { boundaries, siteSource, writeFrameSites } from "../scripts/agent-pane/frameSites.mjs";
import { resolveSite, type SiteTable } from "../src/agent-session/acpmux/frameOwners";

const root = mkdtempSync(path.join(os.tmpdir(), "frame-sites-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

test("node_modules sources collapse to their package, others stay paths under webviews/", () => {
  const webviews = "/w/webviews";
  expect(
    siteSource(
      "../../node_modules/.bun/react-dom@19/node_modules/react-dom/cjs/x.js",
      "/w/webviews/out/pane",
      webviews,
    ),
  ).toBe("node_modules/react-dom");
  expect(siteSource("../../node_modules/@pierre/diffs/dist/a.js", "/w/webviews/out/pane", webviews)).toBe(
    "node_modules/@pierre/diffs",
  );
  expect(siteSource("../../src/agent-session/acpmux/flickerLog.ts", "/w/webviews/out/pane", webviews)).toBe(
    "src/agent-session/acpmux/flickerLog.ts",
  );
  expect(siteSource("artifact-runtime:shim", "/w/webviews/out/pane", webviews)).toBe("artifact-runtime:shim");
});

test("a file the build wrote outside webviews/ is named from the build root, not its temp path", () => {
  const webviews = "/w/webviews";
  expect(siteSource("../chunks/c-ABC.js", "/tmp/tmp.X1/pane", webviews, "/tmp/tmp.X1")).toBe("build:chunks/c-ABC.js");
  expect(siteSource("../chunks/c-ABC.js", "/tmp/tmp.Y2/pane", webviews, "/tmp/tmp.Y2")).toBe("build:chunks/c-ABC.js");
  expect(siteSource("../../src/a.ts", "/w/webviews/out/pane", webviews, "/w/webviews/out")).toBe("src/a.ts");
});

test("boundaries keep one entry per run of one source", () => {
  // Line 0: col 0 source 0, col 5 source 0, col 9 source 1; line 1: col 0 source 1 (no new entry), col 4 no source.
  const map = { sources: ["a.ts", "b.ts"], mappings: "AAAA,KAAC,ICAA;AAAA,I" };
  const sources: string[] = [];
  expect(boundaries(map, (source: string) => `src/${source}`, sources)).toEqual([0, 0, 0, 0, 9, 1]);
  expect(sources).toEqual(["src/a.ts", "src/b.ts"]);
});

test("a minified split bundle's positions name their source files", async () => {
  const src = path.join(root, "src");
  mkdirSync(src, { recursive: true });
  writeFileSync(
    path.join(src, "loop.ts"),
    "export function loopOwnerMarker(){ return requestAnimationFrame(loopOwnerMarker); }\n",
  );
  writeFileSync(
    path.join(src, "lazy.ts"),
    'export const lazyOwnerMarker = () => setTimeout(() => "lazyOwnerMarker", 16);\n',
  );
  writeFileSync(
    path.join(src, "main.ts"),
    'import { loopOwnerMarker } from "./loop";\nloopOwnerMarker();\nexport const later = () => import("./lazy");\n',
  );
  const outdir = path.join(root, "out");
  const result = await build({
    entryPoints: [path.join(src, "main.ts")],
    bundle: true,
    format: "esm",
    minify: true,
    splitting: true,
    outdir,
    entryNames: "pane",
    chunkNames: "chunks/[name]-[hash]",
    sourcemap: "external",
    metafile: true,
    logLevel: "silent",
    absWorkingDir: root,
  });
  const scripts = Object.keys(result.metafile.outputs)
    .filter((output) => output.endsWith(".js"))
    .map((output) => path.relative(outdir, path.resolve(root, output)));
  mkdirSync(path.join(outdir, "chunks"), { recursive: true });
  const file = path.join(outdir, "chunks", "frame-sites.js");
  await writeFrameSites({ outdir, outputs: scripts, file, webviewsRoot: root });
  const table = (await import(file)).default as SiteTable;
  const position = (script: string, marker: string) => {
    const text = readFileSync(path.join(outdir, script), "utf8");
    const at = text.indexOf(marker);
    expect(at).toBeGreaterThanOrEqual(0);
    const before = text.slice(0, at).split("\n");
    return `${script}:${before.length}:${before.at(-1)!.length + 1}`;
  };
  expect(resolveSite(table, position("pane.js", "requestAnimationFrame"))).toBe("src/loop.ts");
  const lazy = scripts.find((script) => readFileSync(path.join(outdir, script), "utf8").includes("lazyOwnerMarker"))!;
  expect(lazy.startsWith("chunks/")).toBe(true);
  expect(resolveSite(table, position(lazy, "setTimeout"))).toBe("src/lazy.ts");
  // The maps were only read: none ships, and no script points at one.
  const all = [...readdirSync(outdir), ...readdirSync(path.join(outdir, "chunks")).map((name) => `chunks/${name}`)];
  expect(all.filter((name) => name.endsWith(".map"))).toEqual([]);
  for (const script of scripts)
    expect(readFileSync(path.join(outdir, script), "utf8")).not.toContain("sourceMappingURL");
});
