// Bundles the React agent pane (src/agent-session/acpmux) for the app with the React
// Compiler on, the same compiler the Vite dev server runs (vite.config.ts).
//
//   bun scripts/agent-pane/bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>] [--split]
//     [--css-inputs <file> [--page-styles <module>] [--css-inputs-only]]
//
// --split writes the code behind dynamic imports (shiki's grammars, KaTeX) as chunks/ beside
// <outfile>, so the page's first script is only what its first frame runs.
//
// --css-inputs <file> lists, one per line relative to webviews/, every stylesheet the page imports,
// in the order the page applies them: esbuild's order for the CSS bundle (import order, each sheet
// at its first import, after the sheets it @imports), then any sheet only a lazily loaded chunk
// imports, by path. The bundle drops CSS: the page build writes its <style> from this list
// (build-agent-pane-web.sh), so a sheet a component imports always ships.
// --page-styles <module> is imported ahead of <entry> for that list: the page's own sheets, which
// no component imports, in cascade order (acpmux/pageStyles.ts).
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
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { reactCompilerMode } from "../../reactCompiler.mjs";
import { reactCompilerPlugin } from "./reactCompilerPlugin.mjs";
import { tailwindPlugin } from "./tailwindCompile.mjs";
import { jsonParsePlugin } from "./jsonParsePlugin.mjs";
import { katexStylePlugin } from "./katexStylePlugin.mjs";

const [entry, shikiAlias, outfile, ...rest] = process.argv.slice(2);
if (!entry || !shikiAlias || !outfile) {
  console.error("usage: bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]");
  process.exit(2);
}
const reportIndex = rest.indexOf("--report");
const reportFile = reportIndex >= 0 ? rest[reportIndex + 1] : undefined;
const split = rest.includes("--split");
const cssInputsIndex = rest.indexOf("--css-inputs");
const cssInputsFile = cssInputsIndex >= 0 ? rest[cssInputsIndex + 1] : undefined;
const cssInputsOnly = rest.includes("--css-inputs-only");
const pageStylesIndex = rest.indexOf("--page-styles");
const pageStyles = pageStylesIndex >= 0 ? rest[pageStylesIndex + 1] : undefined;
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

const options = {
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  // An imported PNG becomes a data URL: a page ships as one index.html and its CSP allows
  // `img-src data:` only (the Settings page's Chief Pet mascots).
  loader: { ".png": "dataurl" },
  alias: shikiAlias === "-" ? {} : { shiki: path.resolve(shikiAlias) },
  logLevel: "warning",
};

/** Every stylesheet the page imports, in the order the page applies them (--css-inputs above). */
async function stylesheets() {
  const webviewsRoot = path.dirname(srcRoot);
  const sourcefile = "page-stylesheets.js";
  const imports = [pageStyles, entry].filter(Boolean).map((file) => `import ${JSON.stringify(path.resolve(file))};`);
  const result = await build({
    ...options,
    stdin: { contents: imports.join("\n"), resolveDir: process.cwd(), sourcefile, loader: "js" },
    // Split as the page is, so a sheet only a lazily loaded chunk imports stays out of the order.
    splitting: true,
    outdir: path.join(path.dirname(outfile), "stylesheets"),
    write: false,
    metafile: true,
    plugins: [tailwindPlugin, jsonParsePlugin, katexStylePlugin({ split: true })],
  });
  const local = (input) => input.endsWith(".css") && !input.includes("node_modules/");
  const relative = (input) => path.relative(webviewsRoot, path.resolve(input));
  const outputs = result.metafile.outputs;
  // The page's own CSS bundle; each dynamic import is an entry point of its own.
  const bundle = Object.values(outputs).find((output) => output.entryPoint === sourcefile)?.cssBundle;
  const ordered = bundle ? Object.keys(outputs[bundle].inputs).filter(local).map(relative) : [];
  const all = Object.keys(result.metafile.inputs).filter(local).map(relative);
  // No page bundle while the graph has sheets means esbuild's metafile changed shape: fail rather
  // than ship every sheet in path order.
  if (!bundle && all.length)
    throw new Error("bundle.mjs: the page imports stylesheets but esbuild wrote no CSS bundle");
  return [...ordered, ...all.filter((sheet) => !ordered.includes(sheet)).sort()];
}

if (cssInputsFile) await writeFile(cssInputsFile, (await stylesheets()).map((sheet) => sheet + "\n").join(""));
if (!cssInputsOnly)
  await build({
    ...options,
    entryPoints: [entry],
    minify: true,
    legalComments: "none",
    ...(split
      ? {
          splitting: true,
          outdir: path.dirname(outfile),
          entryNames: path.basename(outfile, ".js"),
          chunkNames: "chunks/[name]-[hash]",
        }
      : { outfile }),
    plugins: [reactCompiler, tailwindPlugin, jsonParsePlugin, katexStylePlugin({ split })],
  });

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
