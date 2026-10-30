import { artifactRuntimeVite } from "./scripts/agent-pane/artifactRuntimePlugin.mjs";
import { reactWithCompiler } from "./reactCompiler.mjs";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { viteCacheDir } from "./dev-server/viteCacheDir.mjs";
import { agentPaneHost } from "./dev-server/plugins";

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
    // Keep the standalone pane dev server's host contract identical to `bun run dev`: real,
    // confined checkout reads are served by /__dev-host/read instead of silently becoming stubs.
    // Install only this host plugin so `/` remains the pane, rather than the generic dev index.
    agentPaneHost(),
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
  ],
});
