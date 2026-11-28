import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite-plus";
import base from "./vite.config";

// `bun run dev:pages`: every page the app hosts from one dev server with hot reload, for a Debug or
// tagged cmux-next launched with CMUX_NEXT_PAGES_DEV_URL=http://127.0.0.1:4190/ (PageDevServer).
// The app serves each page under its own cmux-page://<id>/ origin and fetches the files from here:
// /<page>/ for the React pages (dev-server/plugins.ts DEV_PAGES), /diff-page.html,
// /markdown-page.html and /editor-page.html for the viewers, and every module at its own path.
// The page's origin is not this server, so the Vite client is told where its HMR socket is.
const port = Number(process.env.CMUX_PAGES_DEV_PORT) || 4190;
const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));

export default defineConfig({
  ...base,
  server: {
    ...base.server,
    port,
    hmr: { protocol: "ws", host: "127.0.0.1", clientPort: port },
    // Settings imports its schema from schemas/settings at the repository root.
    fs: { allow: [webviewsRoot, path.join(webviewsRoot, "..", "schemas/settings")] },
  },
  // The pages' entries, so the first dependency scan finds them instead of reloading mid-load.
  optimizeDeps: { entries: ["src/pages/*/main.tsx"] },
});
