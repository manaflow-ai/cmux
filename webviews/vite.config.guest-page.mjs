// The guest page (src/agent-session/guest): the page a guest of a shared agent chat opens in any
// browser, served by the hosted room (manaflow-ai/cmux-platform) at /g/<share_id> with its files
// under /g/ (design/chat-multiplayer.md section 3). scripts/cmux-next/build-guest-page-web.sh
// builds it and adds the strings; `CMUX_GUEST_PAGE_OUT_DIR` names the output (default
// dist/guest-page), `CMUX_GUEST_PAGE_BASE` the path its files are served under (default /g/).
// It reuses the shared build settings (React Compiler, Tailwind) and the agent pane's shipped
// stylesheet module (dev-server/galleryHost.ts).
import path from "node:path";
import { fileURLToPath } from "node:url";
import base from "./vite.config";
import { galleryModules } from "./dev-server/galleryHost";

const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const pageRoot = path.join(webviewsRoot, "src/agent-session/guest");

export default {
  ...base,
  root: pageRoot,
  base: process.env.CMUX_GUEST_PAGE_BASE ?? "/g/",
  server: {
    host: "127.0.0.1",
    port: 4179,
    strictPort: true,
    fs: { allow: [webviewsRoot, path.join(webviewsRoot, "..")] },
  },
  // Only the stylesheet module: the gallery's emitted chart library (`__lib/vega.js`) is not served
  // to guests, so a chart in a reply draws as its source there.
  plugins: [
    ...(base.plugins ?? []),
    { ...galleryModules(), name: "cmux-guest-page-pane-css", generateBundle: undefined },
  ],
  build: {
    outDir: process.env.CMUX_GUEST_PAGE_OUT_DIR ?? path.join(webviewsRoot, "dist/guest-page"),
    emptyOutDir: true,
    target: "es2022",
    rolldownOptions: { input: path.join(pageRoot, "index.html") },
  },
};
