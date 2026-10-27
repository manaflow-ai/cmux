// One React for every web tree the app ships (plans/cmux-next/chrome-parity/p13-webui.md, E, 072).
//
// The pages (esbuild, scripts/pages/build-pages.mjs), Agent Activity (esbuild,
// scripts/cmux-next/build-agent-activity-web.sh) and the webviews app (Vite/Rolldown,
// scripts/build-webviews-app.sh) are three bundler runs. A chunk one run splits out has a name
// only that run knows, so React would be three files at three URLs. Chrome solves this for WebUI:
// shared libraries are built once into chrome://resources, and every page's build marks them
// external and imports them by that one absolute URL (ui/webui/resources/tools/optimize_webui.gni
// `external_paths`, chrome/browser/resources/tools/rollup_plugin.mjs). Here React is built once,
// as one content-hashed file, into the pages output's `_shared/` (served as
// cmux-page://cmux.shared/, PageSharedChunks), and every run resolves `react`, `react-dom` and
// their entry points to that file's absolute URL.
//
// The one file exports every name of every entry under a prefix (`react$useState`,
// `react_jsx_runtime$jsx`): one request for all of React. A specifier resolves to a small module
// inside the importing bundle that re-exports its names from that URL without the prefix, for
// `import` and CommonJS `require` alike (React and many of its dependents ship CommonJS).
//
// The build is deterministic (same lockfile, same bytes, same name), so each run builds it again to
// learn the URL; the pages run writes the file.
import { build } from "esbuild";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** The origin every shipped tree imports the shared chunks from (PageID.sharedOrigin). */
export const SHARED_ORIGIN = "cmux-page://cmux.shared/";

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const requireFromWebviews = createRequire(path.join(webviewsRoot, "package.json"));

/**
 * Every specifier the shared file answers, with the production CommonJS module whose export names
 * it carries. `react-dom/server` is not here: only the markdown page renders to static markup, so
 * it stays in that page's own chunks (and uses the shared `react` and `react-dom`).
 */
export const SHARED_REACT_ENTRIES = [
  { specifier: "react", module: "react/cjs/react.production.js" },
  { specifier: "react/jsx-runtime", module: "react/cjs/react-jsx-runtime.production.js" },
  { specifier: "react/compiler-runtime", module: "react/cjs/react-compiler-runtime.production.js" },
  { specifier: "react-dom", module: "react-dom/cjs/react-dom.production.js" },
  { specifier: "react-dom/client", module: "react-dom/cjs/react-dom-client.production.js" },
];

/** The Vite plugin's name: builds for a plain server (the gallery, the latency harness) drop it. */
export const SHARED_REACT_PLUGIN = "cmux-shared-react";

const SPECIFIERS = new Set(SHARED_REACT_ENTRIES.map((entry) => entry.specifier));
const NAMESPACE = "cmux-shared-react";
const IDENTIFIER = /^[A-Za-z_$][\w$]*$/;

/** The prefix of `specifier`'s names in the shared file: `react/jsx-runtime` is `react_jsx_runtime$`. */
export function prefix(specifier) {
  return `${specifier.replace(/[^A-Za-z0-9]/g, "_")}$`;
}

/** The names `entry`'s production module exports, `default` first, then sorted. */
export function exportNames(entry) {
  const [pkg, ...rest] = entry.module.split("/");
  const root = path.dirname(requireFromWebviews.resolve(`${pkg}/package.json`));
  const exports = requireFromWebviews(path.join(root, ...rest));
  const names = Object.keys(exports).filter((name) => IDENTIFIER.test(name) && name !== "default");
  return ["default", ...names.sort()];
}

/** The shared file's source: every entry's names, prefixed. */
function sharedSource() {
  return SHARED_REACT_ENTRIES.map((entry) => {
    const names = exportNames(entry).map((name) => `${name} as ${prefix(entry.specifier)}${name}`);
    return `export { ${names.join(", ")} } from ${JSON.stringify(entry.specifier)};\n`;
  }).join("");
}

/**
 * The module `specifier` resolves to in a consuming bundle: its names, from the shared `url`. It also
 * imports every other specifier, so the five modules form one cycle that every importer of one of
 * them reaches whole: a code-splitting bundler puts modules reached by the same entries in one chunk,
 * and five modules with five entry sets would be up to five more chunks per page.
 */
export function specifierModule(specifier, url) {
  const entry = SHARED_REACT_ENTRIES.find((candidate) => candidate.specifier === specifier);
  const names = exportNames(entry).map((name) => `${prefix(specifier)}${name} as ${name}`);
  const siblings = SHARED_REACT_ENTRIES.filter((other) => other !== entry).map(
    (other) => `import ${JSON.stringify(other.specifier)};\n`,
  );
  return `${siblings.join("")}export { ${names.join(", ")} } from ${JSON.stringify(url)};\n`;
}

/**
 * Builds the shared file: `{ name, bytes, url }` (its content-hashed file name in `_shared/`, its
 * bytes, its cmux.shared URL). Nothing is written.
 */
export async function buildSharedReact() {
  const result = await build({
    absWorkingDir: webviewsRoot,
    stdin: { contents: sharedSource(), resolveDir: webviewsRoot, sourcefile: "shared-react.js", loader: "js" },
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    minify: true,
    define: { "process.env.NODE_ENV": '"production"' },
    legalComments: "none",
    logLevel: "warning",
    outdir: "/shared-react",
    entryNames: "react-[hash]",
    write: false,
  });
  if (result.outputFiles.length !== 1)
    throw new Error(`the shared React build wrote ${result.outputFiles.length} files`);
  const [file] = result.outputFiles;
  const name = path.basename(file.path);
  return { name, bytes: file.contents, url: SHARED_ORIGIN + name };
}

/** The esbuild plugin that resolves every shared specifier, imported or required, to the shared file at `url`. */
export function sharedReactEsbuildPlugin(url) {
  return {
    name: "cmux-shared-react",
    setup(builder) {
      builder.onResolve({ filter: /^react(?:-dom)?(?:\/[a-z-]+)?$/ }, (args) =>
        SPECIFIERS.has(args.path) ? { path: args.path, namespace: NAMESPACE } : undefined,
      );
      builder.onLoad({ filter: /.*/, namespace: NAMESPACE }, (args) => ({
        contents: specifierModule(args.path, url),
        resolveDir: webviewsRoot,
        loader: "js",
      }));
      builder.onResolve({ filter: new RegExp(`^${url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`) }, (args) => ({
        path: args.path,
        external: true,
      }));
    },
  };
}

/**
 * The same for Vite (Rolldown), build only: the dev server keeps serving React from node_modules.
 * It builds the shared file when the build starts, to learn its URL.
 */
export function sharedReactVitePlugin() {
  const virtual = `\0${NAMESPACE}:`;
  let url;
  return {
    name: SHARED_REACT_PLUGIN,
    apply: "build",
    enforce: "pre",
    async buildStart() {
      url ??= (await buildSharedReact()).url;
    },
    resolveId(source) {
      if (source === url) return { id: source, external: true };
      return SPECIFIERS.has(source) ? virtual + source : null;
    },
    load(id) {
      return id.startsWith(virtual) ? specifierModule(id.slice(virtual.length), url) : null;
    },
  };
}

const IMPORTED_URL = /(?:\bfrom|\bimport)\s*\(?\s*["'](cmux-page:\/\/cmux\.shared\/[^"']+)["']/g;

/** Every cmux.shared file name the script `text` imports, statically or dynamically. */
export function sharedImports(text) {
  return [...text.matchAll(IMPORTED_URL)].map((match) => match[1].slice(SHARED_ORIGIN.length));
}

/** Prints the shared file's URL (the shell builders read it). */
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { url } = await buildSharedReact();
  process.stdout.write(`${url}\n`);
}
