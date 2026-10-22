// Bundles the React agent pane (src/agent-session/acpmux) for the app with the React
// Compiler on, the same compiler the Vite dev server runs (vite.config.ts).
//
//   bun scripts/agent-pane/bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>] [--split]
//
// --split writes the code behind dynamic imports (shiki's grammars, KaTeX) as chunks/ beside
// <outfile>, so the page's first script is only what its first frame runs.
//
// --css-inputs <file> lists, one per line relative to webviews/, every stylesheet the bundle
// imports. The bundle drops CSS, so the page build checks each one ships in the page.
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

const result = await build({
  entryPoints: [entry],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  minify: !cssInputsOnly,
  write: !cssInputsOnly,
  legalComments: "none",
  // An imported PNG becomes a data URL: a page ships as one index.html and its CSP allows
  // `img-src data:` only (the Settings page's Chief Pet mascots).
  loader: { ".png": "dataurl" },
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
    ? [tailwindPlugin, jsonParsePlugin, katexStylePlugin({ split })]
    : [reactCompiler, tailwindPlugin, jsonParsePlugin, katexStylePlugin({ split })],
  metafile: Boolean(cssInputsFile),
});
if (cssInputsFile) {
  const webviewsRoot = path.dirname(srcRoot);
  const sheets = Object.keys(result.metafile.inputs)
    .filter((input) => input.endsWith(".css") && !input.includes("node_modules/"))
    .map((input) => path.relative(webviewsRoot, path.resolve(input)))
    .sort();
  await writeFile(cssInputsFile, sheets.map((sheet) => sheet + "\n").join(""));
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
