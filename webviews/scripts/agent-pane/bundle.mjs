import { artifactRuntimePlugin } from "./artifactRuntimePlugin.mjs";
// Bundles the React agent pane (src/agent-session/acpmux) for the app with the React
// Compiler on, the same compiler the Vite dev server runs (vite.config.ts).
//
//   bun scripts/agent-pane/bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>] [--split]
//
// --split writes the code behind dynamic imports (shiki's grammars, KaTeX) as chunks/ beside
// <outfile>, so the page's first script is only what its first frame runs.
//
// --css-inputs <file> lists, one per line relative to webviews/, every stylesheet the bundle
// imports, in the order the page applies them (cssInImportOrder). The bundle drops CSS: the page
// build writes its one <style> from this list, so a new import ships without a hand-kept list.
// --css-inputs-only writes just that list: no React Compiler, no minify, nothing written to
// <outfile>, so a test can ask for it in about a second.
//
// Pass `-` as the shiki alias for a page that does not use shiki (the Settings page).
//
// Each first-party .ts/.tsx file under src/ goes through the React Compiler that
// CMUX_REACT_COMPILER selects (reactCompiler.mjs; the pass is reactCompilerPlugin.mjs), then
// esbuild bundles and minifies as before. Components the compiler skips or bails out on are
// listed on stderr, and as JSON with --report, so a bailout is visible in review.
import { build } from "esbuild";
import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { reactCompilerMode } from "../../reactCompiler.mjs";
import { reactCompilerPlugin } from "./reactCompilerPlugin.mjs";
import { tailwindPlugin } from "./tailwindCompile.mjs";
import { jsonParsePlugin } from "./jsonParsePlugin.mjs";
import { katexStylePlugin } from "./katexStylePlugin.mjs";
import { writeFrameSites } from "./frameSites.mjs";
import { classicScript } from "./classicScript.mjs";

const [entry, shikiAlias, outfile, ...rest] = process.argv.slice(2);
if (!entry || !shikiAlias || !outfile) {
  console.error("usage: bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]");
  process.exit(2);
}
const reportIndex = rest.indexOf("--report");
const reportFile = reportIndex >= 0 ? rest[reportIndex + 1] : undefined;
const split = rest.includes("--split");
// --classic (with --split): the entry and the chunks it imports statically become one classic script, and only
// the lazy chunks stay ES modules (classicScript.mjs): V8 serves a classic script from its code cache on a
// warm load and an ES module never. The page loads pane.js with <script src>, and there is nothing to preload.
const classic = rest.includes("--classic");
if (classic && !split) {
  console.error("--classic needs --split");
  process.exit(2);
}
const cssInputsIndex = rest.indexOf("--css-inputs");
const cssInputsFile = cssInputsIndex >= 0 ? rest[cssInputsIndex + 1] : undefined;
const cssInputsOnly = rest.includes("--css-inputs-only");
// --metafile <file> writes esbuild's metafile (every output's bytes, its imports and the inputs in it),
// for an analyzer: what the page's first script holds and why.
const metafileIndex = rest.indexOf("--metafile");
const metafileOut = metafileIndex >= 0 ? rest[metafileIndex + 1] : undefined;
const artifactMetafileIndex = rest.indexOf("--artifact-metafile");
const artifactMetafile = artifactMetafileIndex >= 0 ? rest[artifactMetafileIndex + 1] : undefined;
// --preload-list <file> (with --split) writes the chunks the entry imports statically, directly or
// through another chunk, one per line relative to <outfile>'s folder: the page names each in a
// <link rel="modulepreload">, so they load and parse beside the entry instead of after it.
const preloadIndex = rest.indexOf("--preload-list");
const preloadFile = preloadIndex >= 0 ? rest[preloadIndex + 1] : undefined;
// --frame-sites <file> (with --split) writes the pane's site table there (frameSites.mjs): the
// build makes external source maps only to read them, and deletes them after.
const frameSitesIndex = rest.indexOf("--frame-sites");
const frameSitesFile = frameSitesIndex >= 0 ? rest[frameSitesIndex + 1] : undefined;
if (frameSitesFile && !split) {
  console.error("--frame-sites needs --split");
  process.exit(2);
}
const srcRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../src");

const mode = reactCompilerMode();
const bailouts = [];
const compiled = new Set();
const reactCompiler = reactCompilerPlugin({
  mode,
  srcRoot,
  onCompiled: (id) => compiled.add(id),
  onDiagnostic: (diagnostic) => bailouts.push(diagnostic),
});

/** Vite's `import.meta.env` as a production page sees it. */
const PRODUCTION_ENV = JSON.stringify({ DEV: false, PROD: true, MODE: "production", SSR: false });

const result = await build({
  entryPoints: [entry],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  // `import.meta.env` is Vite's: a browser has none, so a bare `import.meta.env.DEV` left in a shipped
  // page throws. #50616 put one in the pane's connect path and every NIGHTLY pane sat on
  // "Reconnecting…" (#51194). Defined here, any read of it is a production build's constant.
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env": PRODUCTION_ENV },
  minify: !cssInputsOnly,
  write: !cssInputsOnly,
  legalComments: "none",
  // An imported PNG or WOFF2 becomes a data URL: a page ships as one index.html and its CSP allows
  // `img-src data:` and fonts from data: only (the Settings page's Chief Pet mascots, the chat's
  // interface font choices, chatFonts/faces.ts, and the Updated card doodle's handwriting, both
  // behind a dynamic import).
  loader: { ".png": "dataurl", ".woff2": "dataurl" },
  alias: shikiAlias === "-" ? {} : { shiki: path.resolve(shikiAlias) },
  logLevel: "warning",
  ...(split
    ? {
        splitting: true,
        outdir: path.dirname(outfile),
        entryNames: path.basename(outfile, ".js"),
        chunkNames: "chunks/[name]-[hash]",
      }
    : { outfile }),
  plugins: cssInputsOnly
    ? [
        artifactRuntimePlugin({ metafile: artifactMetafile }),
        tailwindPlugin,
        jsonParsePlugin,
        katexStylePlugin({ split }),
      ]
    : [
        reactCompiler,
        artifactRuntimePlugin({ metafile: artifactMetafile }),
        tailwindPlugin,
        jsonParsePlugin,
        katexStylePlugin({ split }),
      ],
  metafile: Boolean(cssInputsFile || metafileOut || preloadFile || frameSitesFile || classic),
  // External maps add no comment to the scripts: they are the same code, and only the chunks'
  // content hashes (their names) change, as esbuild hashes a chunk with its map.
  ...(frameSitesFile && !cssInputsOnly ? { sourcemap: "external" } : {}),
});
if (!cssInputsOnly) await refuseRawImportMetaEnv();
if (classic && !cssInputsOnly) {
  const entryOut = Object.keys(result.metafile.outputs).find(
    (output) => path.resolve(output) === path.resolve(outfile),
  );
  await classicScript({
    outdir: path.resolve(path.dirname(outfile)),
    outputs: result.metafile.outputs,
    staticOut: staticChunks(result.metafile.outputs, entryOut),
    entryOut,
    maps: Boolean(frameSitesFile),
  });
}
if (frameSitesFile && !cssInputsOnly) {
  const outdir = path.resolve(path.dirname(outfile));
  const outputs = Object.keys(result.metafile.outputs)
    .filter((output) => !output.endsWith(".map"))
    .map((output) => path.relative(outdir, path.resolve(output)));
  await writeFrameSites({ outdir, outputs, file: frameSitesFile, webviewsRoot: path.dirname(srcRoot) });
}
if (metafileOut) await writeFile(metafileOut, JSON.stringify(result.metafile));
if (preloadFile) {
  const outdir = path.resolve(path.dirname(outfile));
  const entryOut = Object.keys(result.metafile.outputs).find(
    (output) => path.resolve(output) === path.resolve(outfile),
  );
  await writeFile(
    preloadFile,
    (classic ? [] : staticChunks(result.metafile.outputs, entryOut))
      .map((output) => path.relative(outdir, path.resolve(output)) + "\n")
      .join(""),
  );
}

/**
 * Fails the build when a written script still holds `import.meta.env`: the define above should
 * leave none, and one that slipped through (a new spelling esbuild does not match) throws in the
 * shipped page before it connects.
 */
async function refuseRawImportMetaEnv() {
  const outdir = path.resolve(path.dirname(outfile));
  const scripts = [path.resolve(outfile)];
  if (split) {
    const chunks = path.join(outdir, "chunks");
    for (const name of await readdir(chunks).catch(() => [])) {
      if (name.endsWith(".js")) scripts.push(path.join(chunks, name));
    }
  }
  const left = [];
  for (const file of scripts) {
    const text = await readFile(file, "utf8").catch(() => "");
    if (/import\.meta\s*\.\s*env|import\.meta\?\.env/.test(text)) left.push(path.relative(outdir, file));
  }
  if (left.length) {
    console.error(`bundle.mjs: import.meta.env left in ${left.join(", ")}: a browser has none, so the page throws`);
    process.exit(1);
  }
}

/**
 * The outputs `entryOut` imports statically, directly or through each other, breadth first: what
 * the browser fetches before the entry runs. Dynamic imports are left out (they load when used).
 */
function staticChunks(outputs, entryOut) {
  if (!entryOut) throw new Error(`--preload-list: no output for ${outfile}`);
  const order = [];
  const seen = new Set([entryOut]);
  const queue = [entryOut];
  while (queue.length) {
    for (const item of outputs[queue.shift()].imports ?? []) {
      if (item.kind !== "import-statement" || item.external || seen.has(item.path)) continue;
      seen.add(item.path);
      order.push(item.path);
      queue.push(item.path);
    }
  }
  return order;
}
if (cssInputsFile) {
  const webviewsRoot = path.dirname(srcRoot);
  const sheets = cssInImportOrder(result.metafile.inputs, entry)
    .filter((input) => !input.includes("node_modules/"))
    .map((input) => path.relative(webviewsRoot, path.resolve(input)));
  await writeFile(cssInputsFile, sheets.map((sheet) => sheet + "\n").join(""));
}

/**
 * Every stylesheet in `inputs` (an esbuild metafile's), in the order the page applies them: the
 * order the modules run, as the Vite dev server injects them and esbuild concatenates them. A
 * depth-first walk from `entry` over static imports, each module after what it imports (a sheet's
 * own `@import` before it), first visit wins; then the code behind dynamic imports, in the order
 * they were met; then any sheet the walk did not reach (a plugin's namespace), by path.
 */
function cssInImportOrder(inputs, entry) {
  const order = [];
  const seen = new Set();
  const later = [];
  const visit = (file) => {
    if (seen.has(file) || !inputs[file]) return;
    seen.add(file);
    for (const item of inputs[file].imports ?? []) {
      if (item.external) continue;
      if (item.kind === "dynamic-import") later.push(item.path);
      else visit(item.path);
    }
    if (file.endsWith(".css")) order.push(file);
  };
  const root = Object.keys(inputs).find((input) => path.resolve(input) === path.resolve(entry));
  if (root) visit(root);
  while (later.length) visit(later.shift());
  for (const input of Object.keys(inputs).sort()) if (input.endsWith(".css")) visit(input);
  return order;
}

bailouts.sort((a, b) => `${a.file}:${a.line}`.localeCompare(`${b.file}:${b.line}`));
if (bailouts.length) {
  console.error(
    `react compiler (${mode}): ${compiled.size} ${mode === "oxc" ? "files" : "functions"} compiled, ${bailouts.length} skipped or bailed out:`,
  );
  for (const item of bailouts)
    console.error(`  ${item.file}:${item.line ?? "?"} ${item.function ?? ""} ${item.kind}: ${item.reason}`);
}
if (reportFile)
  await writeFile(reportFile, JSON.stringify({ compiler: mode, compiled: compiled.size, bailouts }, null, 2) + "\n");
