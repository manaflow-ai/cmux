import { artifactRuntimeVite } from "./scripts/agent-pane/artifactRuntimePlugin.mjs";
import { reactWithCompiler } from "./reactCompiler.mjs";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { viteCacheDir } from "./dev-server/viteCacheDir.mjs";
import { jsonDevSourceMap } from "./dev-server/jsonDevSourceMap.mjs";
import { agentPaneHost, perfBudgetsDevEntry } from "./dev-server/plugins";
import { paneLocales } from "./scripts/agent-pane/paneLocales.mjs";

// Dev server for the real agent pane (src/agent-session/acpmux) with hot
// reload. A Debug or tagged cmux-next launched with
// CMUX_NEXT_AGENT_PANE_DEV_URL=http://127.0.0.1:4176/ loads the pane from here
// instead of its bundled page; Swift still answers the handshake, so the page
// talks to the real acpmux daemon. Serve only: the shipped pane is built by
// scripts/cmux-next/build-agent-pane-web.sh. See src/agent-session/acpmux/README.md.
const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const paneRoot = path.join(webviewsRoot, "src/agent-session/acpmux");
const sharedStyles = path.join(webviewsRoot, "src/agent-session/shared/styles.css");
// scripts/agent-pane/dev-slot.sh gives each slot its own port, so several worktrees serve at once.
const port = Number(process.env.CMUX_AGENT_PANE_DEV_PORT) || 4176;
// CMUX_AGENT_PANE_COMPILE_HINTS gives built chunks V8's `//# allFunctionsCalledOnLoad` hint as their first line
// (https://v8.dev/blog/explicit-compile-hints, Chrome 136+): a hinted chunk compiles every function eagerly while it
// loads, not lazily on the main thread when first called. Goal chat-attach-p95: ~2028 functions first run between the
// attach answer and the newest message (cmux#62173). `1` hints every chunk: A/B 46134754421 cut attach_to_latest
// ~10 ms but added ~20 ms to DOMContentLoaded, a net loss. `window` hints only the chunks holding the modules that
// first run in that window (cmux#62173's coverage list). Added after minification (which drops comments), so a source
// map gains one empty line in front.
const compileHints = process.env.CMUX_AGENT_PANE_COMPILE_HINTS ?? "";
const COMPILE_HINT = "//# allFunctionsCalledOnLoad";
const ATTACH_WINDOW_MODULES =
  /acpmux\/.*\b(direct|turns|model|sessionList|promptHeads|App|VirtualTranscript|RowFrame)\.tsx?$|\/pretext\/|@tanstack\/|\/marked\//;
function paneCompileHints() {
  return {
    name: "cmux-agent-pane-compile-hints",
    apply: "build",
    enforce: "post",
    generateBundle(_options, bundle) {
      for (const file of Object.values(bundle)) {
        if (file.type !== "chunk" || file.code.startsWith(COMPILE_HINT + "\n")) continue;
        if (compileHints === "window" && !file.moduleIds.some((id) => ATTACH_WINDOW_MODULES.test(id))) continue;
        file.code = `${COMPILE_HINT}\n${file.code}`;
        if (file.map) file.map.mappings = ";" + file.map.mappings;
      }
    },
  };
}

export default defineConfig({
  root: paneRoot,
  cacheDir: viteCacheDir,
  server: {
    host: "127.0.0.1",
    port,
    strictPort: true,
    fs: { allow: [webviewsRoot] },
  },
  plugins: [
    artifactRuntimeVite(),
    // A build (the benches' pane) loads English plus the page's language as the shipped page does,
    // not dev.tsx's whole 21-locale table.
    paneLocales(path.join(paneRoot, "generated/strings.json")),
    // Keep the standalone pane dev server's host contract identical to `bun run dev`: real,
    // confined checkout reads are served by /__dev-host/read instead of silently becoming stubs.
    // Install only this host plugin so `/` remains the pane, rather than the generic dev index.
    agentPaneHost(),
    // The runtime perf budgets' console warnings, as on `bun run dev` (src/devkit/perfBudgets.ts).
    perfBudgetsDevEntry(),
    {
      // The bundle drops the shared stylesheet's Tailwind @import (only its
      // variables and rules ship); do the same so dev matches the app.
      name: "cmux-agent-pane-shared-styles",
      enforce: "pre",
      transform(code, id) {
        if (id.split("?")[0] !== sharedStyles) return null;
        return { code: code.replace(/^@import .*$/gm, ""), map: null };
      },
    },
    ...reactWithCompiler(),
    // generated/strings.json is served as 26.7 MB without this, 5.1 MB with it (dev-server/jsonDevSourceMap.mjs).
    jsonDevSourceMap(),
    ...(compileHints === "1" || compileHints === "window" ? [paneCompileHints()] : []),
  ],
});
