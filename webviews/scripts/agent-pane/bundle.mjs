// Bundles the React agent pane (src/agent-session/acpmux) for the app with the React
// Compiler on, the same compiler the Vite dev server runs (vite.config.ts).
//
//   bun scripts/agent-pane/bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]
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
import { reactCompilerMode } from "../../reactCompiler.mjs";
import { reactCompilerPlugin } from "./reactCompilerPlugin.mjs";

const [entry, shikiAlias, outfile, ...rest] = process.argv.slice(2);
if (!entry || !shikiAlias || !outfile) {
  console.error("usage: bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]");
  process.exit(2);
}
const reportIndex = rest.indexOf("--report");
const reportFile = reportIndex >= 0 ? rest[reportIndex + 1] : undefined;
const srcRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../src");

const mode = reactCompilerMode();
const bailouts = [];
const compiled = new Set();
const reactCompiler = reactCompilerPlugin({
  mode,
  srcRoot,
  onCompiled: (id) => compiled.add(id),
  onDiagnostic: (diagnostic) => bailouts.push(diagnostic),
});

await build({
  entryPoints: [entry],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  minify: true,
  legalComments: "none",
  alias: shikiAlias === "-" ? {} : { shiki: path.resolve(shikiAlias) },
  logLevel: "warning",
  outfile,
  plugins: [reactCompiler],
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
