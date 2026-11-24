// Shiki's grammars and themes, stored deflated in the app (CMUX-570, app size).
//
// Each `@shikijs/langs` and `@shikijs/themes` module is one JSON document in a JavaScript string
// (`Object.freeze(JSON.parse("..."))`): 253 grammars and 65 themes, 8.8 MB of the installed app,
// one lazy chunk each. This plugin rewrites that string at build time into the same document,
// raw-deflated and base64-encoded, and the chunk inflates it when it is imported
// (src/shiki-packed/unpackJson.ts, synchronously, so the module still exports the same frozen
// object at the same moment). Nothing else changes: the same chunks under the same names, loaded
// the same way, offline as before; the bytes on disk are about a fifth.
//
// A module of either package that neither holds that one document nor re-exports another
// (`export { default } from './x.mjs'`, the aliases) fails the build, so a Shiki that changes
// its module format is noticed here, not as a grammar that is silently missing.
//
// Monaco's UI strings get the same treatment: each `monaco-editor/esm/vs/nls/lang/<code>.js`
// sets `globalThis._VSCODE_NLS_MESSAGES` to one JSON array of 2,153 strings, written with
// `\uXXXX` escapes (Russian is 620 KB). The rewritten module sets the same array, inflated when
// the editor page imports it before Monaco (src/pages/editor/main.tsx): 1.5 MB of the app becomes
// about 0.45 MB. A language module in another shape fails the build the same way.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { deflateRawSync } from "node:zlib";

const PACKED_MODULE = /\/@shikijs\/(langs|themes)\/dist\/([^/]+)\.mjs$/;
const MONACO_MESSAGES_MODULE = /\/monaco-editor\/esm\/vs\/nls\/lang\/[^/]+\.js$/;
const MONACO_MESSAGES = /^globalThis\._VSCODE_NLS_MESSAGES=(\[.*\]);$/m;
const DOCUMENT = /^(const lang = |export default )Object\.freeze\(JSON\.parse\(("(?:[^"\\\n]|\\.)*")\)\)$/m;
const ALIAS = /^export \{ default \} from '\.\/[^']+\.mjs'$/m;

/** The runtime half; its module id, imported by every rewritten chunk. */
export const UNPACK_MODULE = fileURLToPath(new URL("../src/shiki-packed/unpackJson.ts", import.meta.url));

/**
 * The module source with its JSON document deflated, or null when it holds none (an alias or a
 * package index) or packing would not make it smaller. Exported for the test.
 */
export function packShikiModule(source, id) {
  const document = source.match(DOCUMENT);
  if (!document) {
    if (ALIAS.test(source) || id.endsWith("/index.mjs")) return null;
    throw new Error(`cmux-packed-shiki-data: ${id} holds no Object.freeze(JSON.parse(...)); update the pattern`);
  }
  const text = JSON.parse(document[2]);
  JSON.parse(text); // a document that is not JSON fails the build, not the page
  const packed = deflateRawSync(Buffer.from(text, "utf8"), { level: 9 }).toString("base64");
  const replaced = source.replace(
    document[0],
    () => `${document[1]}Object.freeze(unpackJson(${JSON.stringify(packed)}))`,
  );
  const out = `import { unpackJson } from ${JSON.stringify(UNPACK_MODULE)};\n${replaced}`;
  // A few documents are a few hundred bytes, which base64 makes larger: those stay as they are.
  return out.length < source.length ? out : null;
}

/**
 * A Monaco UI-strings module with its messages array deflated. Unlike a grammar it always
 * shrinks; a module without that one array fails the build. Exported for the test.
 */
export function packMonacoMessages(source, id) {
  const messages = source.match(MONACO_MESSAGES);
  if (!messages) {
    throw new Error(`cmux-packed-shiki-data: ${id} sets no globalThis._VSCODE_NLS_MESSAGES=[...]; update the pattern`);
  }
  const array = JSON.parse(messages[1]); // an array that is not JSON fails the build, not the editor
  if (!Array.isArray(array)) throw new Error(`cmux-packed-shiki-data: ${id} messages are not an array`);
  const packed = deflateRawSync(Buffer.from(JSON.stringify(array), "utf8"), { level: 9 }).toString("base64");
  const replaced = source.replace(
    messages[0],
    () => `globalThis._VSCODE_NLS_MESSAGES=unpackJson(${JSON.stringify(packed)});`,
  );
  return `import { unpackJson } from ${JSON.stringify(UNPACK_MODULE)};\n${replaced}`;
}

export function packedShikiData() {
  return {
    name: "cmux-packed-shiki-data",
    apply: "build",
    enforce: "pre",
    load(id) {
      const path = id.split("?")[0];
      if (MONACO_MESSAGES_MODULE.test(path)) {
        return { code: packMonacoMessages(readFileSync(path, "utf8"), path), map: null };
      }
      if (!PACKED_MODULE.test(path)) return null;
      const code = packShikiModule(readFileSync(path, "utf8"), path);
      return code == null ? null : { code, map: null };
    },
  };
}
