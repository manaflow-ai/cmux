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
// Pierre's diff themes (`@pierre/theme`, the same shape in a single-quoted string) are packed the
// same way, and so is the Oniguruma engine's WebAssembly (`shiki-wasm`, 466 KB of bytes in base64,
// inflated by unpackBytes beside unpackJson). The agent pane and the pages (esbuild) pack the
// same modules with packModule (scripts/agent-pane/packedShikiPlugin.mjs).
//
// A module of these packages that neither holds that one document nor re-exports another
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

const DATA_MODULE = /\/(?:@shikijs\/(?:langs|themes)|@pierre\/theme)\/dist\/[^/]+\.mjs$/;
const WASM_MODULE = /\/@shikijs\/engine-oniguruma\/dist\/wasm-inlined\.mjs$/;
/** Every module packModule rewrites (or refuses, when its shape changed). */
export const PACKED_MODULE =
  /\/(?:(?:@shikijs\/(?:langs|themes)|@pierre\/theme)\/dist\/[^/]+|@shikijs\/engine-oniguruma\/dist\/wasm-inlined)\.mjs$/;
const WASM = /^var binary = Uint8Array\.from\(atob\("([A-Za-z0-9+/=]+)"\), c => c\.charCodeAt\(0\)\);$/m;
const DOCUMENT =
  /^(const lang = |export default )Object\.freeze\(JSON\.parse\(("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')\)\)$/m;
const MONACO_MESSAGES_MODULE = /\/monaco-editor\/esm\/vs\/nls\/lang\/[^/]+\.js$/;
const MONACO_MESSAGES = /^globalThis\._VSCODE_NLS_MESSAGES=(\[.*\]);$/m;
const ALIAS = /^export \{ default \} from '\.\/[^']+\.mjs'$/m;

/** The value of a JavaScript string literal in either quote; an escape JSON lacks fails the build. */
function stringLiteral(literal) {
  if (literal.startsWith('"')) return JSON.parse(literal);
  const body = literal
    .slice(1, -1)
    .replace(/\\(.)|"/g, (match, escaped) => (escaped === undefined ? '\\"' : escaped === "'" ? "'" : match));
  return JSON.parse(`"${body}"`);
}

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
  const text = stringLiteral(document[2]);
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
 * The Oniguruma engine's module with its WebAssembly bytes deflated (`unpackBytes` returns the
 * same Uint8Array the module's `atob` loop built). Exported for the test.
 */
export function packWasmModule(source, id) {
  const binary = source.match(WASM);
  if (!binary) throw new Error(`cmux-packed-shiki-data: ${id} holds no inlined WebAssembly; update the pattern`);
  const packed = deflateRawSync(Buffer.from(binary[1], "base64"), { level: 9 }).toString("base64");
  const replaced = source.replace(binary[0], () => `var binary = unpackBytes(${JSON.stringify(packed)});`);
  return `import { unpackBytes } from ${JSON.stringify(UNPACK_MODULE)};\n${replaced}`;
}

/** Any module PACKED_MODULE names, packed; null when it stays as it is. */
export function packModule(source, id) {
  if (WASM_MODULE.test(id)) return packWasmModule(source, id);
  if (DATA_MODULE.test(id)) return packShikiModule(source, id);
  return null;
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
      const code = packModule(readFileSync(path, "utf8"), path);
      return code == null ? null : { code, map: null };
    },
  };
}
