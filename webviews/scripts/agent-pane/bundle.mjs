// Bundles the React agent pane (src/agent-session/acpmux) for the app with the React
// Compiler on, the same compiler the Vite dev server runs (vite.config.ts).
//
//   bun scripts/agent-pane/bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]
//
// Pass `-` as the shiki alias for a page that does not use shiki (the Settings page).
//
// Each first-party .ts/.tsx file under src/ goes through babel-plugin-react-compiler
// (TypeScript and JSX are only parsed there, so esbuild still strips the types), then
// esbuild bundles and minifies as before. Components the compiler skips or bails out on
// are listed on stderr, and as JSON with --report, so a bailout is visible in review.
import { transformAsync } from "@babel/core";
import { build } from "esbuild";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const [entry, shikiAlias, outfile, ...rest] = process.argv.slice(2);
if (!entry || !shikiAlias || !outfile) {
  console.error("usage: bundle.mjs <entry> <shiki alias dir> <outfile> [--report <file>]");
  process.exit(2);
}
const reportIndex = rest.indexOf("--report");
const reportFile = reportIndex >= 0 ? rest[reportIndex + 1] : undefined;
const srcRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../src");

const bailouts = [];
const compiled = new Set();

const reactCompiler = {
  name: "react-compiler",
  setup(context) {
    context.onLoad({ filter: /\.(tsx|ts)$/ }, async (args) => {
      if (!args.path.startsWith(srcRoot + path.sep) || args.path.endsWith(".d.ts")) return undefined;
      const source = await readFile(args.path, "utf8");
      const relative = path.relative(srcRoot, args.path);
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
              target: "19",
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
  console.error(`react compiler: ${compiled.size} functions compiled, ${bailouts.length} skipped or bailed out:`);
  for (const item of bailouts)
    console.error(`  ${item.file}:${item.line ?? "?"} ${item.function ?? ""} ${item.kind}: ${item.reason}`);
}
if (reportFile) await writeFile(reportFile, JSON.stringify({ compiled: compiled.size, bailouts }, null, 2) + "\n");
