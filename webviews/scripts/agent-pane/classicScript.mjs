// The agent pane's entry as a classic script (bundle.mjs --classic).
//
// V8's code cache serves a classic script on a warm load and never an ES module: measured in Chrome 158
// the pane's module code cache is written on every load and never read (a warm load compiled 4,387
// functions, the same as a cold one, first contentful paint 417 ms), and the same code as one classic
// script compiled 23 functions warm (first contentful paint 232 ms).
//
// bundle.mjs first writes the pane as ES modules: pane.js, the chunks it imports statically (code the
// entry and a lazy chunk share) and the lazy chunks. This turns the static part into one classic script
// and leaves the lazy chunks ES modules that `import()` loads when used:
//
//   pane.js       the entry and every static chunk bundled as one IIFE, with each static chunk's exports
//                 also published as globalThis.__paneChunks[<chunk file>]; its `import()` of a lazy chunk
//                 stays an `import()` (a classic script may call it; the path resolves from pane.js).
//   lazy chunks   rewritten so that what they import from a static chunk comes from that registry, so one
//                 instance of React, the stores and the rest serves the entry and the lazy code alike. A
//                 lazy chunk's import of another lazy chunk stays an ES module import.
//   static chunks deleted: nothing loads them any more.
//
// The registry is complete before any lazy chunk runs: the script finishes before the first `import()` it
// started evaluates its target. Source maps (for frame-sites) are composed through the second pass.
import { build } from "esbuild";
import { readFile, rename, rm } from "node:fs/promises";
import path from "node:path";

const REGISTRY = "__paneChunks";

/** The `export const` lines a shim for `exports` (a metafile output's export names) needs. */
function shimSource(chunkKey, exports) {
  const lines = [`const __paneRegistered = globalThis.${REGISTRY}[${JSON.stringify(chunkKey)}];`];
  // An export may be named like a reserved word (`export { x as if }`): bind a local, export it by name.
  const named = [];
  exports.forEach((name, at) => {
    lines.push(`const __pane${at} = __paneRegistered[${JSON.stringify(name)}];`);
    named.push(`__pane${at} as ${name === "default" ? "default" : JSON.stringify(name)}`);
  });
  if (named.length) lines.push(`export { ${named.join(", ")} };`);
  return lines.join("\n");
}

/**
 * @param outdir     folder holding pane.js (ES module form) and chunks/
 * @param outputs    the first build's metafile outputs
 * @param staticOut  output paths (metafile keys) of the chunks the entry imports statically
 * @param entryOut   the entry's output path (metafile key)
 * @param maps       also write source maps beside each script (for frame-sites)
 * @returns          the scripts written, relative to outdir
 */
export async function classicScript({ outdir, outputs, staticOut, entryOut, maps }) {
  const rel = (output) => path.relative(outdir, path.resolve(output)).split(path.sep).join("/");
  const staticKeys = new Map(staticOut.map((output) => [rel(output), outputs[output].exports ?? []]));
  const entryKey = rel(entryOut);
  const lazy = Object.keys(outputs)
    .map(rel)
    .filter((key) => key.endsWith(".js") && key !== entryKey && !staticKeys.has(key));

  // A script's own map is linked for esbuild to compose through: the first pass writes the maps without a comment.
  const withMap = (file) => ({
    name: `link-map-${path.basename(file)}`,
    setup(b) {
      b.onLoad({ filter: /\.js$/, namespace: "file" }, async (args) => {
        const contents = await readFile(args.path, "utf8");
        const map = `${args.path}.map`;
        const hasMap = await readFile(map, "utf8").then(
          () => true,
          () => false,
        );
        return {
          contents: hasMap ? `${contents}\n//# sourceMappingURL=${path.basename(map)}\n` : contents,
          loader: "js",
          resolveDir: path.dirname(args.path),
        };
      });
    },
  });

  const resolveChunks = ({ shim }) => ({
    name: "pane-chunks",
    setup(b) {
      b.onResolve({ filter: /^\.\.?\// }, (args) => {
        const key = path.relative(outdir, path.resolve(args.resolveDir, args.path)).split(path.sep).join("/");
        if (args.kind === "dynamic-import") {
          // Lazy code stays a runtime import, whatever imports it; a static chunk is never dynamically imported.
          if (staticKeys.has(key))
            throw new Error(`classic pane: ${args.importer} imports the static chunk ${key} with import()`);
          return { path: `./${key}`, external: true };
        }
        if (staticKeys.has(key)) {
          return shim ? { path: key, namespace: "pane-shim" } : { path: path.resolve(outdir, key), namespace: "file" };
        }
        if (key === entryKey) {
          if (args.importer.endsWith("classic-entry.js")) return { path: path.resolve(outdir, key), namespace: "file" };
          throw new Error(`classic pane: ${args.importer} imports the entry ${key}`);
        }
        // A lazy chunk's import of another lazy chunk: an ES module import, relative to this chunk's folder.
        const from = path.posix.dirname(path.relative(outdir, args.importer).split(path.sep).join("/"));
        const spec = path.posix.relative(from, key);
        return { path: spec.startsWith(".") ? spec : `./${spec}`, external: true };
      });
      b.onLoad({ filter: /.*/, namespace: "pane-shim" }, (args) => ({
        contents: shimSource(args.path, staticKeys.get(args.path)),
        loader: "js",
      }));
    },
  });

  const tmp = path.join(outdir, ".classic");
  await rm(tmp, { recursive: true, force: true });
  const common = {
    bundle: true,
    platform: "browser",
    target: "es2022",
    logLevel: "warning",
    // Full minify: the merged scope renames what the first pass had shortened (whitespace alone grew the pane
    // by 1.35 MB). Export names survive: the registry keys and the lazy chunks' exports are strings to esbuild.
    minify: true,
    sourcemap: maps ? "external" : false,
    legalComments: "none",
    absWorkingDir: outdir,
  };

  // The entry and every static chunk, as one script.
  const registry = [...staticKeys.keys()];
  const stdin = [
    `import "./${entryKey}";`,
    ...registry.map((key, at) => `import * as c${at} from "./${key}";`),
    `globalThis.${REGISTRY} = {${registry.map((key, at) => `${JSON.stringify(key)}: c${at}`).join(",")}};`,
  ].join("\n");
  await build({
    ...common,
    stdin: { contents: stdin, resolveDir: outdir, sourcefile: "classic-entry.js" },
    format: "iife",
    // `import.meta` does not exist in a classic script (esbuild would make it `{}`, and `new URL("./x.png", undefined)`
    // throws at load): read as the script's own URL, which is what pane.js's module URL was.
    banner: { js: "var __paneScriptUrl=(document.currentScript&&document.currentScript.src)||location.href;" },
    define: { "import.meta.url": "__paneScriptUrl" },
    outfile: path.join(tmp, "pane.js"),
    plugins: [withMap(entryKey), resolveChunks({ shim: false })],
  });

  // Each lazy chunk, with its imports of a static chunk read from the registry.
  if (lazy.length) {
    await build({
      ...common,
      entryPoints: lazy.map((key) => path.resolve(outdir, key)),
      format: "esm",
      outdir: path.join(tmp, "chunks"),
      outbase: path.join(outdir, "chunks"),
      plugins: [withMap("lazy"), resolveChunks({ shim: true })],
    });
  }

  const written = [entryKey, ...lazy];
  for (const key of written) {
    const from = path.join(tmp, key === entryKey ? "pane.js" : key);
    await rename(from, path.join(outdir, key));
    if (maps) await rename(`${from}.map`, path.join(outdir, `${key}.map`)).catch(() => {});
  }
  for (const key of staticKeys.keys()) {
    await rm(path.join(outdir, key), { force: true });
    await rm(path.join(outdir, `${key}.map`), { force: true });
  }
  await rm(tmp, { recursive: true, force: true });

  // Nothing may still import a deleted chunk (the registry names them by key, with no `./`).
  for (const key of written) {
    const text = await readFile(path.join(outdir, key), "utf8");
    for (const gone of staticKeys.keys()) {
      if (text.includes(`./${gone}`) || text.includes(`./${path.posix.basename(gone)}`))
        throw new Error(`classic pane: ${key} still names the static chunk ${gone}`);
    }
  }
  return written;
}
