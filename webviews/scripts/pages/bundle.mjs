// Compile all first-party pages in one graph: React, the compiler runtime and shared UI ship
// once. Each page keeps its own document, CSS, origin and bridge; chunks are immutable assets.
import { build } from "esbuild";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { reactCompilerMode } from "../../reactCompiler.mjs";
import { reactCompilerPlugin } from "../agent-pane/reactCompilerPlugin.mjs";
import { artifactRuntimePlugin } from "../agent-pane/artifactRuntimePlugin.mjs";
import { tailwindPlugin } from "../agent-pane/tailwindCompile.mjs";
import { createJsonParsePlugin } from "../agent-pane/jsonParsePlugin.mjs";
import { katexStylePlugin } from "../agent-pane/katexStylePlugin.mjs";

const [outdir, ...pages] = process.argv.slice(2);
if (!outdir || !pages.length) throw new Error("usage: bundle.mjs OUTDIR PAGE...");
const srcRoot = fileURLToPath(new URL("../../src", import.meta.url));
const mode = reactCompilerMode();
const jsonParseSettingsPagePlugin = createJsonParsePlugin({ settingsPageOnly: true });
const compiled = new Set();
const bailouts = [];
const result = await build({
  entryPoints: Object.fromEntries(pages.map((page) => [`${page}/app`, path.join(srcRoot, "pages", page, "main.tsx")])),
  outdir,
  bundle: true,
  splitting: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  minify: true,
  legalComments: "none",
  loader: { ".png": "dataurl", ".woff2": "dataurl" },
  alias: { shiki: path.join(srcRoot, "agent-session/acpmux/shiki") },
  chunkNames: "__shared/[name]-[hash]",
  logLevel: "warning",
  metafile: true,
  plugins: [
    reactCompilerPlugin({
      mode,
      srcRoot,
      onCompiled: (id) => compiled.add(id),
      onDiagnostic: (item) => bailouts.push(item),
    }),
    artifactRuntimePlugin(),
    tailwindPlugin,
    jsonParseSettingsPagePlugin,
    // Preserve the existing pages' math styling; splitting must not add new styling defaults.
    katexStylePlugin({ split: false }),
  ],
});
// esbuild's multi-entry CSS graph can reorder rules shared by different entries. Compile
// each document's CSS with its original isolated import graph; only JavaScript is shared.
// No React Compiler pass is needed to collect stylesheets, and the unused JS stays in memory.
for (const page of pages) {
  const styles = await build({
    entryPoints: [path.join(srcRoot, "pages", page, "main.tsx")],
    outfile: path.join(outdir, page, "styles.js"),
    bundle: true,
    write: false,
    format: "esm",
    platform: "browser",
    target: "es2022",
    define: { "process.env.NODE_ENV": '"production"' },
    minify: true,
    legalComments: "none",
    loader: { ".png": "dataurl", ".woff2": "dataurl" },
    alias: { shiki: path.join(srcRoot, page === "github" ? "pages/github/shiki" : "agent-session/acpmux/shiki") },
    logLevel: "warning",
    plugins: [artifactRuntimePlugin(), tailwindPlugin, jsonParseSettingsPagePlugin, katexStylePlugin({ split: false })],
  });
  const css = styles.outputFiles.find((file) => file.path.endsWith(".css"));
  await writeFile(path.join(outdir, page, "app.css"), css?.contents ?? "");
}
await writeFile(path.join(outdir, "metafile.json"), JSON.stringify(result.metafile));
console.error(`pages React compiler (${mode}): ${compiled.size} compiled; ${bailouts.length} diagnostics`);
for (const item of bailouts) console.error(`${item.file}:${item.line ?? "?"}: ${item.reason}`);

// Start all static dependencies alongside the entry; dynamic imports stay lazy.
for (const page of pages) {
  const entry = Object.keys(result.metafile.outputs).find(
    (file) => path.resolve(file) === path.resolve(outdir, page, "app.js"),
  );
  if (!entry) throw new Error(`Missing output for ${page}`);
  const seen = new Set([entry]);
  const queue = [entry];
  for (let i = 0; i < queue.length; i++) {
    for (const item of result.metafile.outputs[queue[i]].imports) {
      if (item.kind !== "import-statement" || item.external || seen.has(item.path)) continue;
      seen.add(item.path);
      queue.push(item.path);
    }
  }
  const staticLinks = queue.slice(1);
  // The Settings schema is intentionally a dynamic import so it does not bloat the entry script.
  // Preload that one Settings-only chunk alongside the entry, though: the module graph still
  // awaits it before mounting, and leaving it out would turn the byte saving into one network
  // round trip on every Settings open. Other dynamic chunks (Shiki, KaTeX, etc.) stay lazy.
  const settingsSchemaLinks =
    page === "settings"
      ? (result.metafile.outputs[entry].imports ?? [])
          .filter((item) => item.kind === "dynamic-import" && item.path.includes("settings-schema"))
          .map((item) => item.path)
      : [];
  const links = [...new Set([...staticLinks, ...settingsSchemaLinks])]
    .map((file) => `<link rel="modulepreload" href="${path.relative(path.dirname(entry), file)}" />`)
    .join("\n");
  await writeFile(path.join(outdir, page, "preloads.html"), links + "\n");
}
