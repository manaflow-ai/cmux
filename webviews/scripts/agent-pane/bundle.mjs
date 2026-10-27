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
// Pass `-` as the shiki alias for a bundle that does not use shiki.
//
// Each first-party .ts/.tsx file under src/ goes through the React Compiler that
// CMUX_REACT_COMPILER selects (reactCompiler.mjs; the pass is reactCompilerPlugin.mjs), then
// esbuild bundles and minifies as before. Components the compiler skips or bails out on are
// listed on stderr, and as JSON with --report, so a bailout is visible in review.
//
// The React pages build all their entries in one run with the same options and plugins
// (scripts/pages/build-pages.mjs imports appBundleOptions, reactCompilerPass and sourcePlugins).
import { build } from "esbuild";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { reactCompilerMode } from "../../reactCompiler.mjs";
import { reactCompilerPlugin } from "./reactCompilerPlugin.mjs";
import { tailwindPlugin } from "./tailwindCompile.mjs";
import { jsonParsePlugin } from "./jsonParsePlugin.mjs";
import { katexStylePlugin } from "./katexStylePlugin.mjs";

const srcRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../src");

/**
 * The esbuild options every app bundle shares. An imported PNG becomes a data URL: the page CSP
 * allows `img-src data:` and same-origin files only (the Settings page's Chief Pet mascots).
 */
export const appBundleOptions = {
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "none",
  loader: { ".png": "dataurl" },
  logLevel: "warning",
};

/**
 * The React Compiler pass over first-party sources: `plugin` for esbuild, then `finish(reportFile)`
 * lists every component it skipped or bailed out on, on stderr and as JSON in `reportFile`.
 */
export function reactCompilerPass() {
  const mode = reactCompilerMode();
  const bailouts = [];
  const compiled = new Set();
  const plugin = reactCompilerPlugin({
    mode,
    srcRoot,
    onCompiled: (id) => compiled.add(id),
    onDiagnostic: (diagnostic) => bailouts.push(diagnostic),
  });
  async function finish(reportFile) {
    bailouts.sort((a, b) => `${a.file}:${a.line}`.localeCompare(`${b.file}:${b.line}`));
    if (bailouts.length) {
      console.error(
        `react compiler (${mode}): ${compiled.size} ${mode === "oxc" ? "files" : "functions"} compiled, ${bailouts.length} skipped or bailed out:`,
      );
      for (const item of bailouts)
        console.error(`  ${item.file}:${item.line ?? "?"} ${item.function ?? ""} ${item.kind}: ${item.reason}`);
    }
    if (reportFile)
      await writeFile(
        reportFile,
        JSON.stringify({ compiler: mode, compiled: compiled.size, bailouts }, null, 2) + "\n",
      );
  }
  return { plugin, finish };
}

/** The loaders that run after the React Compiler: Tailwind entries, large JSON, KaTeX's stylesheet. */
export function sourcePlugins({ split }) {
  return [tailwindPlugin, jsonParsePlugin, katexStylePlugin({ split })];
}

/** esbuild's `alias` that resolves `shiki` to `dir` (the agent pane's trimmed copy); none for `-`. */
export function shikiAlias(dir) {
  return dir === "-" ? {} : { shiki: path.resolve(dir) };
}

async function main(argv) {
  const [entry, shikiDir, outfile, ...rest] = argv;
  if (!entry || !shikiDir || !outfile) {
    console.error("usage: bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]");
    process.exit(2);
  }
  const reportIndex = rest.indexOf("--report");
  const reportFile = reportIndex >= 0 ? rest[reportIndex + 1] : undefined;
  const split = rest.includes("--split");
  const cssInputsIndex = rest.indexOf("--css-inputs");
  const cssInputsFile = cssInputsIndex >= 0 ? rest[cssInputsIndex + 1] : undefined;
  const cssInputsOnly = rest.includes("--css-inputs-only");
  const compiler = reactCompilerPass();

  const result = await build({
    ...appBundleOptions,
    entryPoints: [entry],
    minify: !cssInputsOnly,
    write: !cssInputsOnly,
    alias: shikiAlias(shikiDir),
    ...(split
      ? {
          splitting: true,
          outdir: path.dirname(outfile),
          entryNames: path.basename(outfile, ".js"),
          chunkNames: "chunks/[name]-[hash]",
        }
      : { outfile }),
    plugins: cssInputsOnly ? sourcePlugins({ split }) : [compiler.plugin, ...sourcePlugins({ split })],
    metafile: Boolean(cssInputsFile),
  });
  if (cssInputsFile) {
    const webviewsRoot = path.dirname(srcRoot);
    const sheets = cssInImportOrder(result.metafile.inputs, entry)
      .filter((input) => !input.includes("node_modules/"))
      .map((input) => path.relative(webviewsRoot, path.resolve(input)));
    await writeFile(cssInputsFile, sheets.map((sheet) => sheet + "\n").join(""));
  }
  await compiler.finish(reportFile);
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

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  await main(process.argv.slice(2));
