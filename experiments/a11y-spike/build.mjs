// Builds the spike once per library (production, minified, React Compiler on) and prints the
// gzip size of each build's JS minus the React-only baseline. Also counts React Compiler outcomes.
import { build } from "vite";
import react from "@vitejs/plugin-react";
import { createRequire } from "node:module";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { gzipSync, brotliCompressSync } from "node:zlib";
import path from "node:path";

const require = createRequire(import.meta.url);
const optimizeLocales = require("@react-aria/optimize-locales-plugin");
const here = path.dirname(new URL(import.meta.url).pathname);
// The 21 locales the cmux pages ship (src/viewer-empty/generated/strings.json).
const OURS = ["ar", "bs", "da", "de", "en", "es", "fr", "it", "ja", "km", "ko", "nb", "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"];

const variants = [
  { name: "baseline", lib: "baseline" },
  { name: "rac", lib: "rac" },
  { name: "rac-21-locales", lib: "rac", locales: OURS },
  { name: "rac-en-only", lib: "rac", locales: ["en"] },
  { name: "rac-combobox", lib: "rac-combobox", locales: OURS },
  { name: "baseui", lib: "baseui" },
  { name: "ariakit", lib: "ariakit" },
  { name: "radix-no-combobox", lib: "radix" },
];

const results = {};
for (const v of variants) {
  const compiler = { success: 0, error: 0, skip: 0, errors: [] };
  await build({
    root: here,
    logLevel: "warn",
    configFile: false,
    base: "./",
    build: { outDir: `dist/${v.name}`, emptyOutDir: true, minify: true, modulePreload: false },
    plugins: [
      v.locales ? optimizeLocales.vite({ locales: v.locales }) : null,
      {
        name: "spike-lib",
        resolveId: (id) => (id === "virtual:spike-lib" ? path.join(here, `src/${v.lib}.tsx`) : null),
      },
      react({
        babel: {
          plugins: [["babel-plugin-react-compiler", {
            target: "19",
            logger: {
              logEvent(file, event) {
                if (event.kind === "CompileSuccess") compiler.success++;
                else if (event.kind === "CompileError" || event.kind === "CompileDiagnostic") { compiler.error++; compiler.errors.push(`${path.basename(file)}: ${event.detail?.reason ?? event.kind}`); }
                else if (event.kind === "CompileSkip") compiler.skip++;
              },
            },
          }]],
        },
      }),
    ].filter(Boolean),
  });
  const dir = path.join(here, `dist/${v.name}/assets`);
  const js = readdirSync(dir).filter((f) => f.endsWith(".js")).map((f) => readFileSync(path.join(dir, f)));
  const raw = Buffer.concat(js);
  results[v.name] = { min: raw.length, gzip: gzipSync(raw, { level: 9 }).length, brotli: brotliCompressSync(raw).length, compiler };
}
const base = results.baseline;
const kb = (n) => (n / 1024).toFixed(1);
console.log("variant              min KB  gzip KB  brotli KB  (library cost over React baseline: min / gzip / brotli)  compiler ok/err");
for (const [name, r] of Object.entries(results)) {
  console.log(`${name.padEnd(20)} ${kb(r.min).padStart(6)} ${kb(r.gzip).padStart(8)} ${kb(r.brotli).padStart(10)}   +${kb(r.min - base.min)} / +${kb(r.gzip - base.gzip)} / +${kb(r.brotli - base.brotli)}   ${r.compiler.success}/${r.compiler.error}`);
  for (const e of r.compiler.errors) console.log(`    compiler: ${e}`);
}
writeFileSync(path.join(here, "results-bundle.json"), JSON.stringify(results, null, 2));
