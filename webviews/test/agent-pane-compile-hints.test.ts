// V8 explicit compile hints on the agent pane (scripts/agent-pane/compileHints.mjs, bundle.mjs
// --compile-hints, CMUX_AGENT_PANE_COMPILE_HINTS=1 in build-agent-pane-web.sh). The hint has to be the first
// line of the classic pane.js that scripts/agent-pane/classicScript.mjs writes (the pass rewrites pane.js and
// deletes the static chunks, so the hint goes on after it), the lazy chunks stay unhinted, and the frame-site
// table, read from the source maps afterwards, must still name each position's source file.
/// <reference types="bun" />
import { afterAll, expect, test } from "bun:test";
import { build } from "esbuild";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  addCompileHints,
  COMPILE_HINT,
  mapWithCompileHint,
  withCompileHint,
} from "../scripts/agent-pane/compileHints.mjs";
import { classicScript } from "../scripts/agent-pane/classicScript.mjs";
import { writeFrameSites } from "../scripts/agent-pane/frameSites.mjs";
import { resolveSite, type SiteTable } from "../src/agent-session/acpmux/frameOwners";

const root = mkdtempSync(path.join(os.tmpdir(), "compile-hints-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

test("the hint is the first line, once", () => {
  const hinted = withCompileHint("var a=1;\n");
  expect(hinted).toBe(`${COMPILE_HINT}\nvar a=1;\n`);
  expect(withCompileHint(hinted)).toBe(hinted);
});

test("a source map moves down one line and keeps everything else", () => {
  const map = { version: 3, sources: ["a.ts"], names: [], mappings: "AAAA;AACA" };
  const shifted = JSON.parse(mapWithCompileHint(JSON.stringify(map)));
  expect(shifted.mappings).toBe(";AAAA;AACA");
  expect({ ...shifted, mappings: map.mappings }).toEqual(map);
});

test("a classic pane gets the hint on pane.js alone and its frame sites still resolve", async () => {
  const src = path.join(root, "src");
  mkdirSync(src, { recursive: true });
  writeFileSync(
    path.join(src, "shared.ts"),
    "export const sharedMarker = () => requestAnimationFrame(sharedMarker);\n",
  );
  writeFileSync(
    path.join(src, "lazy.ts"),
    'import { sharedMarker } from "./shared";\nexport const lazyMarker = () => setTimeout(sharedMarker, 16);\n',
  );
  writeFileSync(
    path.join(src, "main.ts"),
    'import { sharedMarker } from "./shared";\nsharedMarker();\nexport const later = () => import("./lazy");\n',
  );
  const outdir = path.join(root, "out");
  const outfile = path.join(outdir, "pane.js");
  const result = await build({
    entryPoints: [path.join(src, "main.ts")],
    bundle: true,
    format: "esm",
    splitting: true,
    outdir,
    entryNames: "pane",
    chunkNames: "chunks/[name]-[hash]",
    sourcemap: "external",
    metafile: true,
    logLevel: "silent",
  });
  const outputs = result.metafile.outputs;
  const entryOut = Object.keys(outputs).find((output) => path.resolve(output) === outfile)!;
  const staticOut = (outputs[entryOut]!.imports ?? [])
    .filter((item) => item.kind === "import-statement" && !item.external)
    .map((item) => item.path);
  expect(staticOut.length).toBeGreaterThan(0);

  // bundle.mjs's order: the classic pass, then the hint (on pane.js alone), then the site table.
  await classicScript({
    outdir,
    outputs,
    staticOut,
    entryOut,
    maps: true,
  });
  await addCompileHints([outfile]);

  const pane = readFileSync(outfile, "utf8");
  expect(pane.startsWith(`${COMPILE_HINT}\n`)).toBe(true);
  expect(pane.split(COMPILE_HINT).length).toBe(2);
  const chunks = readdirSync(path.join(outdir, "chunks")).filter((name) => name.endsWith(".js"));
  expect(chunks.length).toBe(1);
  expect(readFileSync(path.join(outdir, "chunks", chunks[0]!), "utf8")).not.toContain(COMPILE_HINT);

  const scripts = ["pane.js", `chunks/${chunks[0]}`];
  const file = path.join(outdir, "chunks", "frame-sites.js");
  await writeFrameSites({ outdir, outputs: scripts, file, webviewsRoot: root });
  const table = (await import(file)).default as SiteTable;
  const text = readFileSync(outfile, "utf8");
  const before = text.slice(0, text.indexOf("requestAnimationFrame")).split("\n");
  // Line 1 is the hint, so the code is on a later line: a map left unshifted would name no source here.
  expect(before.length).toBeGreaterThan(1);
  expect(resolveSite(table, `pane.js:${before.length}:${before.at(-1)!.length + 1}`)).toBe("src/shared.ts");
});
