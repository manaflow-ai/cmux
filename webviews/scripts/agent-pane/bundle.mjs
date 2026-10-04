// Bundles the React agent pane (src/agent-session/acpmux) for the app with the React
// Compiler on, the same compiler the Vite dev server runs (vite.config.ts).
//
//   bun scripts/agent-pane/bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]
//
// Pass `-` as the shiki alias for a page that does not use shiki (the Settings page).
//
// Each first-party .ts/.tsx file under src/ goes through the React Compiler that
// CMUX_REACT_COMPILER selects (reactCompiler.mjs), then esbuild bundles and minifies as before.
// babel (default): babel-plugin-react-compiler; TypeScript and JSX are only parsed there, so
// esbuild still strips the types. oxc: oxc-transform-react, which strips the types and keeps
// JSX; a fatal result fails the build. Components the compiler skips or bails out on are
// listed on stderr, and as JSON with --report, so a bailout is visible in review.
import { transformAsync } from "@babel/core";
import { build } from "esbuild";
import { transformSync } from "oxc-transform-react";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { REACT_COMPILER_TARGET, reactCompilerMode } from "../../reactCompiler.mjs";

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

function lineOf(source, offset) {
  let line = 1;
  for (let index = 0; index < offset && index < source.length; index++) if (source.charCodeAt(index) === 10) line++;
  return line;
}

// Oxc reports diagnostics per finding, not per function, and has no success event, so
// `compiled` counts files here.
function compileWithOxc(file, relative, source) {
  const result = transformSync(file, source, {
    lang: file.endsWith(".tsx") ? "tsx" : "ts",
    sourceType: "module",
    jsx: "preserve",
    reactCompiler: { target: REACT_COMPILER_TARGET },
  });
  for (const error of result.errors) {
    bailouts.push({
      file: relative,
      kind: error.severity,
      function: null,
      line: error.labels[0] ? lineOf(source, error.labels[0].start) : null,
      reason: error.message,
    });
  }
  if (result.fatal) {
    const detail = result.errors.map((error) => error.codeframe ?? error.message).join("\n\n");
    throw new Error(`React Compiler (oxc) failed on ${relative}:\n${detail || "unknown error"}`);
  }
  compiled.add(relative);
  return { contents: result.code, loader: "jsx" };
}

const reactCompiler = {
  name: "react-compiler",
  setup(context) {
    context.onLoad({ filter: /\.(tsx|ts)$/ }, async (args) => {
      if (!args.path.startsWith(srcRoot + path.sep) || args.path.endsWith(".d.ts")) return undefined;
      const source = await readFile(args.path, "utf8");
      const relative = path.relative(srcRoot, args.path);
      if (mode === "oxc") return compileWithOxc(args.path, relative, source);
      const result = await transformAsync(source, {
        filename: args.path,
        babelrc: false,
        configFile: false,
        sourceMaps: false,
        compact: false,
        retainLines: false,
        parserOpts: { plugins: ["jsx", "typescript"] },
        plugins: [
          [
            "babel-plugin-react-compiler",
            {
              target: REACT_COMPILER_TARGET,
              logger: {
                logEvent(_filename, event) {
                  if (event.kind === "CompileSuccess") compiled.add(`${relative}:${event.fnName ?? "anonymous"}`);
                  if (event.kind === "CompileError" || event.kind === "CompileSkip" || event.kind === "PipelineError") {
                    const detail = event.detail ?? {};
                    bailouts.push({
                      file: relative,
                      kind: event.kind,
                      function: event.fnName ?? null,
                      line: event.fnLoc?.start?.line ?? detail.loc?.start?.line ?? null,
                      reason: String(
                        detail.reason ?? detail.options?.reason ?? event.reason ?? event.data ?? "unknown",
                      ),
                    });
                  }
                },
              },
            },
          ],
        ],
      });
      return { contents: result?.code ?? source, loader: args.path.endsWith(".tsx") ? "tsx" : "ts" };
    });
  },
};

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
