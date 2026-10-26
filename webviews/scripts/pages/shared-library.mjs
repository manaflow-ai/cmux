// The library every page and the agent pane import by one URL: React, built once into
// _shared/react-<hash>.js and external to every other bundle. Chrome's WebUI pages do the same with
// chrome://resources: each page is bundled on its own and chrome://resources stays an import
// (ui/webui/resources/tools/optimize_webui.gni, `external_paths`), so adding a page never changes
// what another page loads. The pages' code splitting shares the rest between pages; the agent pane
// is bundled on its own and shares only this file with them.
//
// The file has real ES exports: every name of the five modules below, React as its default, and each
// other module's own default as defaultName(module). A bundle's ES import of one of them is an import
// of the file (libraryPlugin), so `useState` is one binding of one module in every bundle. A
// CommonJS `require()` of one (use-sync-external-store) gets that module's object through a
// two-line bridge. The names are the packages' production exports, read when the build runs.
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appBundleOptions } from "../agent-pane/bundle.mjs";
import { SHARED_ORIGIN } from "./shared-origin.mjs";

const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/** The modules the library holds; React's default is the library's. Other modules of the packages are bundled. */
export const LIBRARY_MODULES = [
  "react",
  "react/jsx-runtime",
  "react/compiler-runtime",
  "react-dom",
  "react-dom/client",
];
const DEFAULT_MODULE = "react";

/** The library's export that holds `module`'s default: `default` for React, else `default$react_dom` and so on. */
export function defaultName(module) {
  return module === DEFAULT_MODULE ? "default" : `default$${module.replace(/[^A-Za-z0-9]/g, "_")}`;
}

/**
 * The production export names of each of LIBRARY_MODULES, read from the installed packages. A name
 * two modules export (`Fragment`, `version`) is one export of the library, so it must be the same
 * value in both; the build fails otherwise.
 */
export function libraryExports() {
  const script = `
    const modules = ${JSON.stringify(LIBRARY_MODULES)};
    const loaded = modules.map((module) => [module, require(module)]);
    const owner = new Map();
    const clashes = [];
    for (const [module, value] of loaded)
      for (const name of Object.keys(value)) {
        const first = owner.get(name);
        if (first === undefined) owner.set(name, [module, value[name]]);
        else if (first[1] !== value[name]) clashes.push(name + " (" + first[0] + ", " + module + ")");
      }
    console.log(JSON.stringify({ exports: Object.fromEntries(loaded.map(([m, v]) => [m, Object.keys(v)])), clashes }));
  `;
  const output = execFileSync(process.execPath, ["-e", script], {
    cwd: webviewsRoot,
    encoding: "utf8",
    env: { ...process.env, NODE_ENV: "production" },
  });
  const { exports, clashes } = JSON.parse(output);
  if (clashes.length) throw new Error(`the shared library's modules export different values as ${clashes.join(", ")}`);
  return exports;
}

/**
 * The library's entry: every name of every module once, and each module's object as
 * defaultName(module). Each module is required and its names read from its object (esbuild leaves
 * the locals of `export { name } from "<CommonJS module>"` unminified).
 */
export function librarySource(exports) {
  const seen = new Set();
  const lines = [];
  for (const [index, module] of LIBRARY_MODULES.entries()) {
    const names = exports[module].filter((name) => !seen.has(name));
    for (const name of names) seen.add(name);
    lines.push(`const m${index} = require(${JSON.stringify(module)});`);
    if (names.length) lines.push(`export const { ${names.join(", ")} } = m${index};`);
    lines.push(
      module === DEFAULT_MODULE ? `export default m${index};` : `export const ${defaultName(module)} = m${index};`,
    );
  }
  return lines.join("\n") + "\n";
}

/**
 * Whether `source` imports the default of `module` (`import X from`, `import X, {...} from`,
 * `import { default as X } from`, `export { default } from`). Type-only imports do not count.
 */
export function importsDefault(source, module) {
  const code = source.replace(/\bimport\s+type\b[^;]*;/g, "");
  const from = `\\s*from\\s*["']${module.replace(/[/]/g, "\\/")}["']`;
  const binding = new RegExp(
    `\\bimport\\s*[A-Za-z_$][\\w$]*\\s*(?:,\\s*(?:\\{[^}]*\\}|\\*\\s*as\\s*[\\w$]+)\\s*)?${from}`,
  );
  const named = new RegExp(`\\b(?:import|export)\\s*\\{[^}]*\\bdefault\\b[^}]*\\}${from}`);
  return binding.test(code) || named.test(code);
}

const CJS = "cmux-shared-library";
const ESM = "cmux-shared-library-export";

/**
 * Builds the library into `dir` (the build's _shared folder). Returns its file name, its URL on the
 * shared origin, and `plugin(specifier)`, the esbuild plugin of a bundle that names the library
 * `specifier` (its URL, or a path relative to the bundle's chunks).
 */
export async function buildSharedLibrary(dir) {
  const exports = libraryExports();
  const result = await build({
    ...appBundleOptions,
    stdin: { contents: librarySource(exports), resolveDir: webviewsRoot, sourcefile: "shared-library.js" },
    outdir: dir,
    entryNames: "react-[hash]",
    minify: true,
    metafile: true,
  });
  const file = path.basename(Object.keys(result.metafile.outputs)[0]);
  return { file, url: SHARED_ORIGIN + file, plugin: (specifier) => libraryPlugin(specifier) };
}

/**
 * Makes each of LIBRARY_MODULES the library, which a bundle imports as `specifier`. An ES import
 * (static or dynamic) names it directly, and fails for the default of a module other than React,
 * which the library's default is not. A `require()` gets a CommonJS bridge whose `module.exports`
 * is the module's object (the library's defaultName(module)), as the package's own entry is.
 */
export function libraryPlugin(specifier) {
  const modules = new Set(LIBRARY_MODULES);
  const sources = new Map();
  const sourceOf = (file) => {
    if (!sources.has(file)) sources.set(file, fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "");
    return sources.get(file);
  };
  return {
    name: "cmux-shared-library",
    setup(build) {
      build.onResolve({ filter: /^react(?:-dom)?(?:\/|$)/, namespace: "file" }, (args) => {
        if (!modules.has(args.path)) return undefined;
        if (args.kind === "require-call") return { path: args.path, namespace: CJS };
        if (args.path !== DEFAULT_MODULE && importsDefault(sourceOf(args.importer), args.path))
          return {
            errors: [
              {
                text: `${args.importer} imports the default of ${args.path}, and the shared library's default is React's: import its names`,
              },
            ],
          };
        return { path: specifier, external: true };
      });
      build.onLoad({ filter: /.*/, namespace: CJS }, (args) => ({
        contents: `module.exports = require(${JSON.stringify(args.path)}).default;\n`,
        loader: "js",
      }));
      build.onResolve({ filter: /.*/, namespace: CJS }, (args) => ({ path: args.path, namespace: ESM }));
      build.onLoad({ filter: /.*/, namespace: ESM }, (args) => ({
        contents: `export { ${defaultName(args.path)} as default } from ${JSON.stringify(specifier)};\n`,
        loader: "js",
      }));
      build.onResolve({ filter: /.*/, namespace: ESM }, (args) => ({ path: args.path, external: true }));
    },
  };
}
