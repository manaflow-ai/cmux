// One switch for the React Compiler implementation every webviews build uses:
// vite.config.ts, the agent pane and preview dev configs, the Settings page config, and
// scripts/agent-pane/bundle.mjs (the shipped agent pane and pages).
//
//   CMUX_REACT_COMPILER=babel  babel-plugin-react-compiler (default; the committed bundles)
//   CMUX_REACT_COMPILER=oxc    Oxc's native port (oxc-transform-react), experimental upstream
//
// Both target React 19 (react/compiler-runtime).
import path from "node:path";
import { fileURLToPath } from "node:url";
import babel from "@rolldown/plugin-babel";
import react, { reactCompilerPreset } from "@vitejs/plugin-react";
import { viteCacheDir } from "./dev-server/viteCacheDir.mjs";

export const REACT_COMPILER_TARGET = "19";

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * Vite's optimized dependencies in the per-file cache scripts/ci/run-webviews-tests.sh sets
 * (CMUX_VITE_CACHE_DIR, /tmp/.../vite/N): outside node_modules, where the default cache
 * (node_modules/.vite) is. Vite resolves a relative cacheDir from the config's root, webviews/.
 */
export function viteCacheExclude(cacheDir = viteCacheDir) {
  if (!cacheDir) return [];
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), cacheDir);
  return [new RegExp(`^${escapeRegExp(root)}[/\\\\]`)];
}

/** @returns {"babel" | "oxc"} */
export function reactCompilerMode(value = process.env.CMUX_REACT_COMPILER) {
  if (value === undefined || value === "" || value === "babel") return "babel";
  if (value === "oxc") return "oxc";
  throw new Error(`CMUX_REACT_COMPILER must be "babel" or "oxc", got ${JSON.stringify(value)}`);
}

/** `@vitejs/plugin-react` with the React Compiler from `reactCompilerMode()`. */
export function reactWithCompiler(mode = reactCompilerMode()) {
  if (mode === "oxc") return [react({ compiler: { target: REACT_COMPILER_TARGET } })];
  return [
    react(),
    babel({
      // Same files the Babel pass saw under @vitejs/plugin-react 5: first-party JS/TS only,
      // not node_modules, Vite's optimized dependencies wherever its cache is, or virtual modules
      // such as Vite's `\0vite/preload-helper.js`.
      include: [/\.[tj]sx?(?:$|\?)/],
      // oxlint-disable-next-line no-control-regex -- Rollup marks virtual module ids with a leading NUL.
      exclude: [/[/\\]node_modules[/\\]/, ...viteCacheExclude(), /^\0/],
      presets: [reactCompilerPreset({ target: REACT_COMPILER_TARGET })],
    }),
  ];
}
