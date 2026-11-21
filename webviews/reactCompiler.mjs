// One switch for the React Compiler implementation every webviews build uses:
// vite.config.ts, the agent pane and preview dev configs, the Settings page config, and
// scripts/agent-pane/bundle.mjs (the shipped agent pane and pages).
//
//   CMUX_REACT_COMPILER=babel  babel-plugin-react-compiler (default; the committed bundles)
//   CMUX_REACT_COMPILER=oxc    Oxc's native port (oxc-transform-react), experimental upstream
//
// Both target React 19 (react/compiler-runtime).
import crypto from "node:crypto";
import fs from "node:fs";
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
    withTransformCache(
      babel({
        // Same files the Babel pass saw under @vitejs/plugin-react 5: first-party JS/TS only,
        // not node_modules, Vite's optimized dependencies wherever its cache is, or virtual modules
        // such as Vite's `\0vite/preload-helper.js`.
        include: [/\.[tj]sx?(?:$|\?)/],
        // oxlint-disable-next-line no-control-regex -- Rollup marks virtual module ids with a leading NUL.
        exclude: [/[/\\]node_modules[/\\]/, ...viteCacheExclude(), /^\0/],
        presets: [reactCompilerPreset({ target: REACT_COMPILER_TARGET })],
      }),
    ),
  ];
}

/**
 * The Babel React Compiler pass, its output kept on disk in CMUX_VITE_TRANSFORM_CACHE when that is set
 * (scripts/ci/run-webviews-tests.sh sets one for the whole run), so each dev server test file does not
 * compile the agent pane again. That pass is most of a dev server file's start: App.tsx (813 KB)
 * took 33 s alone on an idle machine (2026-11-04), and every dev server test file paid it in its own Vite,
 * 60 s and more with the shard's other files beside it, which put files that run in 30 s over
 * their 120 s limit and timed out their gallery warm-ups. The key is the module id, its
 * environment and type, the exact code handed to the pass and the lockfile, so a hit is the output
 * that pass would make. Unset (dev servers, bundles), nothing changes.
 * @template T
 * @param {T} pending the plugin, or the promise of it
 * @param {string} [dir]
 * @returns {T}
 */
function withTransformCache(pending, dir = process.env.CMUX_VITE_TRANSFORM_CACHE) {
  if (!dir) return pending;
  // `@rolldown/plugin-babel` returns its plugin as a promise, which Vite awaits.
  return /** @type {T} */ (Promise.resolve(pending).then((plugin) => cacheTransforms(plugin, dir)));
}

function cacheTransforms(plugin, dir) {
  const webviews = path.dirname(fileURLToPath(import.meta.url));
  let lock = "";
  try {
    lock = crypto
      .createHash("sha256")
      .update(fs.readFileSync(path.join(webviews, "bun.lock")))
      .digest("hex");
  } catch {}
  const salt = JSON.stringify([REACT_COMPILER_TARGET, lock]);
  const handler = plugin.transform.handler;
  plugin.transform.handler = async function (code, id, opts) {
    const key = crypto
      .createHash("sha256")
      .update(JSON.stringify([salt, this.environment?.name, opts?.moduleType, id]))
      .update("\0")
      .update(code)
      .digest("hex");
    const file = path.join(dir, key.slice(0, 2), `${key}.json`);
    try {
      return JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {}
    const result = await handler.call(this, code, id, opts);
    if (result) {
      // Written whole and renamed into place: files beside this one may read the same key at once.
      try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const temporary = `${file}.${process.pid}.${crypto.randomUUID()}`;
        fs.writeFileSync(temporary, JSON.stringify(result));
        fs.renameSync(temporary, file);
      } catch {}
    }
    return result;
  };
  return plugin;
}
