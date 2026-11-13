// A grammar remains its own lazy module, including the upstream embedded-language imports.
// Only its JSON payload is packed; no eval, blob script, fetch or worker policy change is needed.
import { readFile } from "node:fs/promises";
import { gzipSync } from "node:zlib";
import { parseSync } from "@babel/core";

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
    generateBundle(_options, bundle) {
      let packed = 0;
      for (const chunk of Object.values(bundle)) {
        if (chunk.type !== "chunk" || !/^chunks\/shiki-lang-.*\.mjs$/.test(chunk.fileName)) continue;
        // Packing after chunking preserves the original eager graph. Giving Rolldown async
        // grammar modules before chunking adds hundreds of unrelated re-export facades.
        const code = packGeneratedGrammar(chunk.code, chunk.fileName);
        if (code === null) continue;
        chunk.code = code;
        chunk.imports.push("chunks/shiki-pack-inflate.mjs");
        packed++;
      }
      if (!packed) throw new Error("Shiki pack found no emitted grammar payloads");
      this.emitFile({ type: "asset", fileName: "chunks/shiki-pack-inflate.mjs", source: loader });
    },
  };
}

function packGeneratedGrammar(code, filename) {
  const identifier = "__cmuxInflateGrammar";
  if (code.includes(identifier)) throw new Error(`Shiki pack identifier collision: ${filename}`);
  const ast = parseSync(code, { filename, sourceType: "module", configFile: false, babelrc: false });
  const replacements = [];
  const visit = (node, functionDepth = 0) => {
    if (!node || typeof node !== "object") return;
    const nestedDepth = /^(?:Function|ArrowFunction|ObjectMethod|ClassMethod)/.test(node.type ?? "")
      ? functionDepth + 1
      : functionDepth;
    if (
      node.type === "CallExpression" &&
      node.callee.type === "MemberExpression" &&
      !node.callee.computed &&
      node.callee.object.name === "JSON" &&
      node.callee.property.name === "parse" &&
      node.arguments.length === 1
    ) {
      const value = node.arguments[0];
      const json =
        value.type === "StringLiteral"
          ? value.value
          : value.type === "TemplateLiteral" && value.expressions.length === 0
            ? value.quasis[0].value.cooked
            : null;
      if (typeof json === "string" && Buffer.byteLength(json) >= 4096) {
        if (functionDepth) throw new Error(`Shiki payload is not at module scope: ${filename}`);
        JSON.parse(json);
        const compressed = gzipSync(json, { level: 9 }).toString("base64");
        const replacement = `await ${identifier}(${JSON.stringify(compressed)})`;
        if (replacement.length + 100 < node.end - node.start)
          replacements.push({ start: node.start, end: node.end, replacement });
      }
    }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) for (const child of value) visit(child, nestedDepth);
      else if (value && typeof value === "object") visit(value, nestedDepth);
    }
  };
  visit(ast);
  if (!replacements.length) return null;
  for (const { start, end, replacement } of replacements.sort((a, b) => b.start - a.start))
    code = code.slice(0, start) + replacement + code.slice(end);
  return `import { inflateGrammar as ${identifier} } from "./shiki-pack-inflate.mjs";\n${code}`;
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
