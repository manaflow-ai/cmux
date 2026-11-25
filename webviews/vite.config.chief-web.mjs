// Chief mobile web client. build-chief-web.sh emits this page for /c/<handle>.
import path from "node:path";
import { fileURLToPath } from "node:url";
import base from "./vite.config";
import { galleryModules } from "./dev-server/galleryHost";

const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const pageRoot = path.join(webviewsRoot, "src/chief-web");

export default {
  ...base,
  root: pageRoot,
  base: process.env.CMUX_CHIEF_WEB_BASE ?? "/c/",
  server: {
    host: "127.0.0.1",
    port: 4180,
    strictPort: true,
    fs: { allow: [webviewsRoot, path.join(webviewsRoot, "..")] },
  },
  // Only the stylesheet module: the gallery's emitted chart library (`__lib/vega.js`) is not served
  // to browsers, so a chart in a reply draws as its source there.
  plugins: [
    ...(base.plugins ?? []),
    { ...galleryModules(), name: "cmux-chief-web-pane-css", generateBundle: undefined },
  ],
  build: {
    outDir: process.env.CMUX_CHIEF_WEB_OUT_DIR ?? path.join(webviewsRoot, "dist/chief-web"),
    emptyOutDir: true,
    target: "es2022",
    rolldownOptions: { input: path.join(pageRoot, "index.html") },
  },
};
