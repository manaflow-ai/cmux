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
//   chunks/c/     each lazy chunk again as a classic script (classicLazyChunk): it reads its imports of a static or
//                 another lazy chunk from the registry and publishes its own exports there. pane.js loads these
//                 in place of `import()` only when the page's localStorage key `cmux.paneClassicChunks` is "1"
//                 when pane.js starts (default off: every `import()` loads the ES module, as before). The ES module
//                 code cache is written and never read, so lazy code compiled again on every cold open; the
//                 classic copies are served from the code cache like pane.js.
//
// The registry is complete before any lazy chunk runs: the script finishes before the first `import()` it
// started evaluates its target. Source maps (for frame-sites) are composed through the second pass.
import { build } from "esbuild";
import { realpathSync } from "node:fs";
import { mkdir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

const REGISTRY = "__paneChunks";
/** localStorage key: "1" makes pane.js load the classic copies of its lazy chunks (chunks/c/). */
export const CLASSIC_LAZY_KEY = "cmux.paneClassicChunks";
/** Where a lazy chunk's classic copy goes: chunks/x.js -> chunks/c/x.js. */
export const classicLazyPath = (key) => `chunks/c/${key.slice("chunks/".length)}`;

// `import("./chunks/x.js")` as esbuild prints an external dynamic import, any quote.
const DYNAMIC_IMPORT = /\bimport\((["'`])(\.{1,2}\/[^"'`]+?\.js)\1\)/g;

/** The banner of pane.js: the flag, read once, and the loader of the classic lazy copies. */
function classicLazyBanner(deps) {
  return [
    `var __paneClassicLazy=(function(){try{return localStorage.getItem(${JSON.stringify(CLASSIC_LAZY_KEY)})==="1"}catch(e){return false}})();`,
    "var __pImp;(function(){",
    `var deps=${JSON.stringify(deps)},loading={},base=new URL(".",__paneScriptUrl).href;`,
    // A URL under the pane's folder, either the ES chunk's or its classic copy's, names the same chunk key.
    `function keyOf(url){if(url.indexOf(base)!==0)return null;var k=url.slice(base.length);return k.indexOf("chunks/c/")===0?"chunks/"+k.slice(9):k}`,
    "function load(key){",
    "if(loading[key])return loading[key];",
    `var got=globalThis.${REGISTRY}&&globalThis.${REGISTRY}[key];if(got)return(loading[key]=Promise.resolve(got));`,
    "return(loading[key]=Promise.all((deps[key]||[]).map(load)).then(function(){return new Promise(function(resolve,reject){",
    'var s=document.createElement("script");s.src=base+"chunks/c/"+key.slice(7);s.async=true;',
    `s.onload=function(){var m=globalThis.${REGISTRY}[key];m?resolve(m):reject(new Error("classic pane chunk did not register: "+key))};`,
    's.onerror=function(){delete loading[key];reject(new TypeError("Failed to fetch classic pane chunk "+key))};',
    "document.head.appendChild(s)})}))}",
    // A copy's own import() of lazy code (SPEC from the ES chunk FROM's folder): the classic copy too.
    'globalThis.__paneLoadRel=function(spec,from){var key=keyOf(new URL(spec,base+from).href);if(!key||!(key in deps))return Promise.reject(new TypeError("classic pane: no chunk "+spec));return load(key)};',
    // pane.js's import() of a lazy chunk: the ES module (flag off, as before) or its classic copy.
    "__pImp=function(spec){var url=new URL(spec,__paneScriptUrl).href,key=__paneClassicLazy&&keyOf(url);return key&&key in deps?load(key):import(url)};",
    "})();",
  ].join("");
}

/** Rewrites every external `import()` in TEXT with WRAP(spec); returns the text and how many it rewrote. */
function rewriteDynamicImports(text, wrap) {
  let count = 0;
  const out = text.replace(DYNAMIC_IMPORT, (_, q, spec) => {
    count += 1;
    return wrap(JSON.stringify(spec));
  });
  return { text: out, count };
}

/** Whether the lazy chunks' static imports of each other (DEPS) have a cycle: the loader would wait on itself. */
function hasCycle(deps) {
  const state = new Map();
  const visit = (key) => {
    if (state.get(key) === 1) return true;
    if (state.get(key) === 2) return false;
    state.set(key, 1);
    for (const dep of deps[key] || []) if (visit(dep)) return true;
    state.set(key, 2);
    return false;
  };
  return Object.keys(deps).some(visit);
}

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
export async function classicScript({ outdir: given, outputs, staticOut, entryOut, maps }) {
  // esbuild resolves imports against real paths, so the chunk keys are taken from real paths too: macOS's
  // `mktemp -d` and /tmp sit under symlinks (/var -> /private/var), and a key from the linked path never
  // matched the one an import resolved to, leaving lazy chunks importing deleted static chunks.
  const outdir = await realpath(given);
  const rel = (output) =>
    path
      .relative(outdir, realpathSync(path.resolve(output)))
      .split(path.sep)
      .join("/");
  const staticKeys = new Map(staticOut.map((output) => [rel(output), outputs[output].exports ?? []]));
  const entryKey = rel(entryOut);
  const lazy = Object.keys(outputs)
    .map(rel)
    .filter((key) => key.endsWith(".js") && key !== entryKey && !staticKeys.has(key));
  const lazySet = new Set(lazy);
  // Each lazy chunk's static imports of other lazy chunks (shared lazy code): loaded before it, in the classic form.
  const outputOf = new Map(Object.keys(outputs).map((output) => [rel(output), outputs[output]]));
  const lazyDeps = {};
  for (const key of lazy) {
    const imports = (outputOf.get(key).imports ?? [])
      .filter((i) => i.kind === "import-statement")
      .map((i) => {
        try {
          return rel(i.path);
        } catch {
          return null;
        }
      })
      .filter((dep) => dep && lazySet.has(dep));
    lazyDeps[key] = [...new Set(imports)];
  }
  // Classic copies need every lazy chunk under chunks/ and no import cycle among them; otherwise none are written
  // and the flag does nothing (the loader knows no chunk and falls back to import()).
  const classicLazy = lazy.length > 0 && lazy.every((key) => key.startsWith("chunks/")) && !hasCycle(lazyDeps);
  if (lazy.length && !classicLazy)
    console.warn("classic pane: lazy chunks not written as classic scripts (a cycle or a chunk outside chunks/)");

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
      // KEY as a module specifier from where the importer ends up: pane.js (the outdir) for the entry and the
      // static chunks it absorbs, the lazy chunk's own folder for a lazy chunk.
      const specifierFor = (key, importer) => {
        const from = shim ? path.posix.dirname(path.relative(outdir, importer).split(path.sep).join("/")) : ".";
        const spec = path.posix.relative(from, key);
        return spec.startsWith(".") ? spec : `./${spec}`;
      };
      b.onResolve({ filter: /^\.\.?\// }, (args) => {
        const key = path.relative(outdir, path.resolve(args.resolveDir, args.path)).split(path.sep).join("/");
        if (args.kind === "dynamic-import") {
          // Lazy code stays a runtime import, whatever imports it; a static chunk is never dynamically imported.
          if (staticKeys.has(key))
            throw new Error(`classic pane: ${args.importer} imports the static chunk ${key} with import()`);
          // From a lazy chunk in chunks/, `./chunks/x.js` resolved to chunks/chunks/x.js: every shiki grammar the
          // lazy highlighter chunk imports failed to load ("Failed to fetch dynamically imported module").
          return { path: specifierFor(key, args.importer), external: true };
        }
        if (staticKeys.has(key)) {
          return shim ? { path: key, namespace: "pane-shim" } : { path: path.resolve(outdir, key), namespace: "file" };
        }
        if (key === entryKey) {
          if (args.importer.endsWith("classic-entry.js")) return { path: path.resolve(outdir, key), namespace: "file" };
          throw new Error(`classic pane: ${args.importer} imports the entry ${key}`);
        }
        // A lazy chunk's import of another lazy chunk: an ES module import, relative to this chunk's folder.
        return { path: specifierFor(key, args.importer), external: true };
      });
      b.onLoad({ filter: /.*/, namespace: "pane-shim" }, (args) => ({
        contents: shimSource(args.path, staticKeys.get(args.path)),
        loader: "js",
      }));
    },
  });

  // A lazy chunk's classic copy: the chunk itself from its file; a static or another lazy chunk from the registry;
  // its import() of lazy code external (rewritten after the build).
  const exportsOf = (key) => staticKeys.get(key) ?? outputOf.get(key)?.exports ?? [];
  const classicLazyChunk = ({ self }) => ({
    name: "pane-classic-lazy",
    setup(b) {
      b.onResolve({ filter: /^\.\.?\// }, (args) => {
        const key = path.relative(outdir, path.resolve(args.resolveDir, args.path)).split(path.sep).join("/");
        if (args.kind === "dynamic-import") {
          if (staticKeys.has(key))
            throw new Error(`classic pane: ${args.importer} imports the static chunk ${key} with import()`);
          // Relative to the ES chunk's folder, as the loader resolves it (__paneLoadRel).
          const from = path.posix.dirname(self);
          const spec = path.posix.relative(from, key);
          return { path: spec.startsWith(".") ? spec : `./${spec}`, external: true };
        }
        if (key === self) return { path: path.resolve(outdir, key), namespace: "file" };
        if (staticKeys.has(key) || lazySet.has(key)) return { path: key, namespace: "pane-shim" };
        if (key === entryKey) throw new Error(`classic pane: ${args.importer} imports the entry ${key}`);
        throw new Error(`classic pane: ${args.importer} imports ${key}, no chunk of this build`);
      });
      b.onLoad({ filter: /.*/, namespace: "pane-shim" }, (args) => ({
        contents: shimSource(args.path, exportsOf(args.path)),
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

  const paneBanner =
    "var __paneScriptUrl=(document.currentScript&&document.currentScript.src)||location.href;" +
    classicLazyBanner(classicLazy ? lazyDeps : {});
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
    banner: { js: paneBanner },
    define: { "import.meta.url": "__paneScriptUrl" },
    outfile: path.join(tmp, "pane.js"),
    plugins: [withMap(entryKey), resolveChunks({ shim: false })],
  });

  // pane.js's import() of a lazy chunk goes through __paneImport: the flag picks the ES module or its classic copy.
  {
    const file = path.join(tmp, "pane.js");
    const before = await readFile(file, "utf8");
    // `import(` becomes `__pImp(`, the same length: pane.js's source map (frame-sites) still lines up.
    if (!before.startsWith(paneBanner) || /\b__pImp\b/.test(before.slice(paneBanner.length)))
      throw new Error("classic pane: pane.js already names __pImp");
    const text = before.replace(DYNAMIC_IMPORT, (call) => `__pImp${call.slice("import".length)}`);
    await writeFile(file, text);
  }

  // Each lazy chunk again as a classic script, read from the first pass's ES chunks (still in outdir).
  if (classicLazy) {
    await Promise.all(
      lazy.map(async (key) => {
        const file = path.join(tmp, classicLazyPath(key));
        await build({
          ...common,
          sourcemap: false,
          stdin: {
            contents: `import * as m from "./${key}";\nglobalThis.${REGISTRY}[${JSON.stringify(key)}] = m;`,
            resolveDir: outdir,
            sourcefile: `classic-${path.posix.basename(key)}`,
          },
          format: "iife",
          outfile: file,
          plugins: [classicLazyChunk({ self: key })],
        });
        // Its own import() of lazy code: the classic copy too (the flag was on, or this copy would not run).
        const { text } = rewriteDynamicImports(
          await readFile(file, "utf8"),
          (spec) => `__paneLoadRel(${spec},${JSON.stringify(key)})`,
        );
        await writeFile(file, text);
      }),
    );
  }

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
  const classicCopies = classicLazy ? lazy.map(classicLazyPath) : [];
  for (const copy of classicCopies) {
    await mkdir(path.dirname(path.join(outdir, copy)), { recursive: true });
    await rename(path.join(tmp, copy), path.join(outdir, copy));
  }
  for (const key of staticKeys.keys()) {
    await rm(path.join(outdir, key), { force: true });
    await rm(path.join(outdir, `${key}.map`), { force: true });
  }
  await rm(tmp, { recursive: true, force: true });

  // Nothing may still import a deleted chunk (the registry names them by key, with no `./`).
  for (const key of [...written, ...classicCopies]) {
    const text = await readFile(path.join(outdir, key), "utf8");
    for (const gone of staticKeys.keys()) {
      if (text.includes(`./${gone}`) || text.includes(`./${path.posix.basename(gone)}`))
        throw new Error(`classic pane: ${key} still names the static chunk ${gone}`);
    }
  }
  // A classic copy runs as a classic script: an import() left in it would load the ES module beside it (two
  // instances of that code), and so would a static import that escaped the registry.
  for (const copy of classicCopies) {
    const text = await readFile(path.join(outdir, copy), "utf8");
    if (DYNAMIC_IMPORT.test(text)) throw new Error(`classic pane: ${copy} still has an import() of a chunk`);
    DYNAMIC_IMPORT.lastIndex = 0;
  }
  return [...written, ...classicCopies];
}
