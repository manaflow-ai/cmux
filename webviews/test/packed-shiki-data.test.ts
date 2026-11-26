// cmux-web-test-timeout: 300
import { expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { packShikiModule, packWasmModule, packMonacoMessages } from "../scripts/packed-shiki-data.mjs";
import { unpackBytes, unpackJson } from "../src/shiki-packed/unpackJson";

// Every Shiki grammar and theme the app ships is stored deflated by scripts/packed-shiki-data.mjs
// and inflated by unpackJson on import (CMUX-570). Each one must come back as exactly the object
// Shiki's own module exports, or a language would highlight differently or not at all.
const dist = (name: string) => resolve(import.meta.dir, `../node_modules/@shikijs/${name}/dist`);
const PACKED_CALL = /Object\.freeze\(unpackJson\(("[A-Za-z0-9+/=]*")\)\)/;
const DOCUMENT = /Object\.freeze\(JSON\.parse\(("(?:[^"\\\n]|\\.)*")\)\)/;

for (const name of ["langs", "themes"]) {
  test(`every @shikijs/${name} document survives packing`, () => {
    let packed = 0;
    for (const file of readdirSync(dist(name)).filter((entry) => entry.endsWith(".mjs"))) {
      const path = `${dist(name)}/${file}`;
      const source = readFileSync(path, "utf8");
      const out: string | null = packShikiModule(source, path);
      if (out == null) {
        // An alias, an index, or a document too small for packing to pay (kept as Shiki wrote it).
        if (DOCUMENT.test(source)) expect(source.length).toBeLessThan(2_000);
        continue;
      }
      const original = JSON.parse(JSON.parse(source.match(DOCUMENT)![1]));
      const call = out.match(PACKED_CALL);
      expect(call).not.toBeNull();
      expect(unpackJson(JSON.parse(call![1]))).toEqual(original);
      // Imports of embedded languages and the export stay as Shiki wrote them.
      expect(out.replace(PACKED_CALL, "").split("\n").slice(1).join("\n")).toBe(source.replace(DOCUMENT, ""));
      expect(out.length).toBeLessThan(source.length);
      packed += 1;
    }
    expect(packed).toBeGreaterThan(name === "langs" ? 200 : 50);
    // Inflating and comparing all ~330 grammars takes several seconds on a busy runner.
  }, 120_000);
}

test("every @pierre/theme document survives packing", async () => {
  const pierre = resolve(import.meta.dir, "../node_modules/@pierre/theme/dist");
  let packed = 0;
  for (const file of readdirSync(pierre).filter((entry) => entry.endsWith(".mjs"))) {
    const path = `${pierre}/${file}`;
    const out: string | null = packShikiModule(readFileSync(path, "utf8"), path);
    if (file === "index.mjs") {
      expect(out).toBeNull();
      continue;
    }
    const call = out!.match(PACKED_CALL);
    expect(call).not.toBeNull();
    expect(unpackJson(JSON.parse(call![1]))).toEqual((await import(path)).default);
    packed += 1;
  }
  expect(packed).toBeGreaterThanOrEqual(4);
});

// The agent pane and the pages (esbuild, scripts/agent-pane/packedShikiPlugin.mjs): a page that
// loads a grammar behind a dynamic import keeps the inflater out of its first load, and the built
// grammar chunk exports Shiki's own object.
test("an esbuild page packs its grammar and keeps the inflater lazy", async () => {
  const { build } = await import("esbuild");
  const { packedShikiPlugin } = await import("../scripts/agent-pane/packedShikiPlugin.mjs");
  const outdir = mkdtempSync(join(tmpdir(), "packed-shiki-esbuild-"));
  try {
    const result = await build({
      stdin: {
        contents: `export const load = () => import("@shikijs/langs/rust");\nexport const theme = () => import("@pierre/theme/pierre-dark");`,
        resolveDir: resolve(import.meta.dir, ".."),
        sourcefile: "page.js",
      },
      bundle: true,
      splitting: true,
      format: "esm",
      platform: "browser",
      minify: true,
      outdir,
      entryNames: "page",
      chunkNames: "chunks/[name]-[hash]",
      metafile: true,
      plugins: [packedShikiPlugin],
      logLevel: "silent",
    });
    const outputs = result.metafile.outputs;
    const page = Object.keys(outputs).find((output) => output.endsWith("page.js"))!;
    const staticImports = outputs[page].imports.filter((item) => item.kind === "import-statement");
    expect(staticImports).toEqual([]);
    const pageSource = readFileSync(resolve(page), "utf8");
    expect(pageSource).not.toContain("inflateSync");
    const page_ = await import(resolve(page));
    const rust = await page_.load();
    expect(rust.default).toEqual((await import("@shikijs/langs/rust")).default);
    const theme = await page_.theme();
    expect(theme.default).toEqual((await import("@pierre/theme/pierre-dark")).default);
    const grammarChunk = Object.keys(outputs).find((output) => /chunks\/rust-/.test(output))!;
    expect(readFileSync(resolve(grammarChunk), "utf8")).not.toContain("JSON.parse");
  } finally {
    rmSync(outdir, { recursive: true, force: true });
  }
}, 60_000);

test("the Oniguruma engine's WebAssembly survives packing", async () => {
  const path = resolve(import.meta.dir, "../node_modules/@shikijs/engine-oniguruma/dist/wasm-inlined.mjs");
  const source = readFileSync(path, "utf8");
  const out = packWasmModule(source, path);
  const call = out.match(/var binary = unpackBytes\(("[A-Za-z0-9+/=]*")\);/);
  expect(call).not.toBeNull();
  const { wasmBinary } = await import(path);
  expect(unpackBytes(JSON.parse(call![1]))).toEqual(wasmBinary);
  expect(out.length).toBeLessThan(source.length / 2);
  expect(() => packWasmModule("var binary = 1;", path)).toThrow(/update the pattern/);
});

test("a module in neither shape fails the build", () => {
  expect(() => packShikiModule("export default {}", "/x/@shikijs/langs/dist/odd.mjs")).toThrow(/update the pattern/);
});

// Monaco's UI strings (the editor's find widget, menus) in each language the editor page loads
// (src/pages/editor/main.tsx): the packed module sets exactly the array Monaco's module sets.
const monacoLang = resolve(import.meta.dir, "../node_modules/monaco-editor/esm/vs/nls/lang");
const MESSAGES = /^globalThis\._VSCODE_NLS_MESSAGES=(\[.*\]);$/m;
const PACKED_MESSAGES = /^globalThis\._VSCODE_NLS_MESSAGES=unpackJson\(("[A-Za-z0-9+/=]*")\);$/m;

test("every Monaco UI-strings module survives packing", () => {
  const files = readdirSync(monacoLang).filter((entry) => entry.endsWith(".js"));
  for (const file of files) {
    const path = `${monacoLang}/${file}`;
    const source = readFileSync(path, "utf8");
    const out = packMonacoMessages(source, path);
    const call = out.match(PACKED_MESSAGES);
    expect(call).not.toBeNull();
    expect(unpackJson(JSON.parse(call![1]))).toEqual(JSON.parse(source.match(MESSAGES)![1]));
    // The language line and the license header stay as Monaco wrote them.
    expect(out.replace(PACKED_MESSAGES, "").split("\n").slice(1).join("\n")).toBe(source.replace(MESSAGES, ""));
    expect(out.length * 2).toBeLessThan(source.length);
  }
  expect(files.length).toBeGreaterThanOrEqual(12);
});

test("a Monaco UI-strings module in another shape fails the build", () => {
  expect(() => packMonacoMessages("globalThis.x=[]", "/x/monaco-editor/esm/vs/nls/lang/de.js")).toThrow(
    /update the pattern/,
  );
});
