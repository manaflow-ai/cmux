import { reactWithCompiler } from "./reactCompiler.mjs";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { viteCacheDir } from "./dev-server/viteCacheDir.mjs";
import {
  DEV_RENDER_FRAME_PATH,
  RENDER_FRAME_DOC,
  RENDER_POLICY,
} from "./src/agent-session/acpmux/conversation/renderFrameShell.ts";

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
    {
      // The render frame (liveRender lab): served with its own policy, as cmux-agent://render/frame
      // is in the app, because a srcdoc frame would also inherit this page's stricter one.
      name: "cmux-agent-pane-render-frame",
      configureServer(server) {
        server.middlewares.use(DEV_RENDER_FRAME_PATH, (_request, response) => {
          response.setHeader("Content-Type", "text/html; charset=utf-8");
          response.setHeader("Content-Security-Policy", RENDER_POLICY);
          response.setHeader("Cache-Control", "no-store");
          response.setHeader("Referrer-Policy", "no-referrer");
          response.end(RENDER_FRAME_DOC);
        });
        // A pane render error the page posts (PaneBoundary.tsx), appended to a log a session can read.
        server.middlewares.use("/__cmux-pane-error", (request, response) => {
          if (request.method !== "POST") {
            response.statusCode = 405;
            response.end();
            return;
          }
          if (request.headers["sec-fetch-site"] !== "same-origin") {
            response.statusCode = 403;
            response.end();
            return;
          }
          const chunks = [];
          let bytes = 0;
          request.on("data", (chunk) => {
            bytes += chunk.length;
            if (bytes > 20000) {
              response.statusCode = 413;
              response.end();
              request.destroy();
              return;
            }
            chunks.push(chunk);
          });
          request.on("end", () => {
            if (bytes > 20000) return;
            fs.appendFileSync(
              path.join(os.tmpdir(), "cmux-pane-errors.log"),
              Buffer.concat(chunks).toString("utf8") + "\n",
            );
            response.statusCode = 204;
            response.end();
          });
        });
      },
    },
    ...reactWithCompiler(),
  ],
});
