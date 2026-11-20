// The guest page (src/agent-session/guest): the page a guest of a shared agent chat opens in any
// browser, served by the hosted room (manaflow-ai/cmux-platform) at /g/<share_id> with its files
// under /g/ (design/chat-multiplayer.md section 3). scripts/cmux-next/build-guest-page-web.sh
// builds it and adds the strings; `CMUX_GUEST_PAGE_OUT_DIR` names the output (default
// dist/guest-page), `CMUX_GUEST_PAGE_BASE` the path its files are served under (default /g/).
// It reuses the shared build settings (React Compiler, Tailwind) and the agent pane's shipped
// stylesheets (dev-server/galleryHost.ts), split between the first frame and the transcript (below).
import path from "node:path";
import { fileURLToPath } from "node:url";
import base from "./vite.config";
import { agentPaneCSS, galleryModules } from "./dev-server/galleryHost";

const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const pageRoot = path.join(webviewsRoot, "src/agent-session/guest");

// The pane's stylesheet is split in two so the first frame waits on only what it draws (Leo,
// 2026-11-07: "the whole, like, loading thing, I think it could probably be faster"). The first
// frame's sheets (guest/firstFrame.css: the page base, glass and the pane's palette, in the pane's
// own order) and the sheets its modules import themselves (Faces' multiplayer.css) load with the
// entry; the rest of the pane's sheet, with Tailwind, loads beside the transcript's chunk
// (guest/transcriptSheet.ts) and is in before any transcript row draws.
const FIRST_FRAME_SHEETS = [
  "src/pages/shared/desktop.css",
  "src/ui/glass/glass.css",
  "src/ui/wave.css",
  "src/agent-session/shared/styles.css",
  "src/agent-session/acpmux/multiplayer/multiplayer.css",
].map((file) => path.join(webviewsRoot, file));
const TRANSCRIPT_SHEET_ID = "virtual:cmux-guest/transcript.css";
const TRANSCRIPT_SHEET_PATH = path.join(pageRoot, "transcript.virtual.css");
const transcriptSheet = {
  name: "cmux-guest-page-transcript-css",
  resolveId: (source) => (source === TRANSCRIPT_SHEET_ID ? TRANSCRIPT_SHEET_PATH : undefined),
  load: (id) => (id.split("?")[0] === TRANSCRIPT_SHEET_PATH ? agentPaneCSS(new Set(FIRST_FRAME_SHEETS)) : undefined),
};

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
  // Only the stylesheet modules: the gallery's emitted chart library (`__lib/vega.js`) is not served
  // to guests, so a chart in a reply draws as its source there.
  plugins: [
    ...(base.plugins ?? []),
    { ...galleryModules(), name: "cmux-guest-page-pane-css", generateBundle: undefined },
    transcriptSheet,
  ],
  build: {
    outDir: process.env.CMUX_GUEST_PAGE_OUT_DIR ?? path.join(webviewsRoot, "dist/guest-page"),
    emptyOutDir: true,
    target: "es2022",
    rolldownOptions: { input: path.join(pageRoot, "index.html") },
  },
};
