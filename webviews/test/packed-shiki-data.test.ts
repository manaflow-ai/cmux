// cmux-web-test-timeout: 300
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { packMonacoMessages, packShikiModule } from "../scripts/packed-shiki-data.mjs";
import { unpackJson } from "../src/shiki-packed/unpackJson";

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
  expect(() => packMonacoMessages("globalThis.x=[]", "/x/monaco-editor/esm/vs/nls/lang/de.js")).toThrow(/update the pattern/);
});
