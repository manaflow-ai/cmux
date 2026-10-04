import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

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
  server: {
    host: "127.0.0.1",
    port,
    strictPort: true,
    fs: { allow: [webviewsRoot] },
  },
  plugins: [
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
    react({ babel: { plugins: [["babel-plugin-react-compiler", { target: "19" }]] } }),
  ],
});
