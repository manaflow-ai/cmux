// A grammar remains its own lazy module, including the upstream embedded-language imports.
// Only its JSON payload is packed; no eval, blob script, fetch or worker policy change is needed.
import { readFile } from "node:fs/promises";
import { gzipSync } from "node:zlib";

const grammarFile = /\/@shikijs\/langs\/dist\/[^/]+\.mjs$/;
const payload = /JSON\.parse\(("(?:\\.|[^"\\])*")\)/g;
const loaderId = "virtual:cmux-shiki-inflate";
const loader = `export async function inflateGrammar(base64) {
  const bytes = Uint8Array.from(atob(base64), (byte) => byte.charCodeAt(0));
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return JSON.parse(await new Response(stream).text());
}`;

export function packGrammar(code, id) {
  if (!grammarFile.test(id.replaceAll("\\", "/"))) return null;
  let packed = 0;
  const transformed = code.replace(payload, (original, literal) => {
    const json = JSON.parse(literal);
    // Validate the data at build time, and avoid adding asynchronous work to tiny grammars.
    JSON.parse(json);
    if (Buffer.byteLength(json) < 4096) return original;
    const compressed = gzipSync(json, { level: 9 }).toString("base64");
    if (compressed.length + 100 >= original.length) return original;
    packed++;
    return `await inflateGrammar(${JSON.stringify(compressed)})`;
  });
  if (!packed) return null;
  return `import { inflateGrammar } from ${JSON.stringify(loaderId)};\n${transformed}`;
}

export function shikiPackVite() {
  return {
    name: "cmux-shiki-pack",
    apply: "build",
    enforce: "pre",
    resolveId(id) {
      return id === loaderId ? `\0${loaderId}` : null;
    },
    load(id) {
      return id === `\0${loaderId}` ? loader : null;
    },
    transform(code, id) {
      const packed = packGrammar(code, id);
      return packed === null ? null : { code: packed, map: null };
    },
  };
}

export function shikiPackEsbuild() {
  return {
    name: "cmux-shiki-pack",
    setup(build) {
      build.onResolve({ filter: /^virtual:cmux-shiki-inflate$/ }, () => ({ path: loaderId, namespace: "shiki-pack" }));
      build.onLoad({ filter: /.*/, namespace: "shiki-pack" }, () => ({ contents: loader, loader: "js" }));
      build.onLoad({ filter: /\/@shikijs\/langs\/dist\/[^/]+\.mjs$/ }, async ({ path }) => {
        const packed = packGrammar(await readFile(path, "utf8"), path);
        return packed === null ? undefined : { contents: packed, loader: "js" };
      });
    },
  };
}
