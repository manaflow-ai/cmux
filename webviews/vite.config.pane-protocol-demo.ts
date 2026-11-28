import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite-plus";

// Dev-only demo for the pane protocol client (src/protocol); serve only, never built. Open
// http://127.0.0.1:4230/#ws=<ws url>&token=<token>&cwd=<repo> to call cmux.git.status.
const webviewsRoot = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  root: path.join(webviewsRoot, "src/protocol/demo"),
  server: { host: "127.0.0.1", port: 4230, strictPort: true, fs: { allow: [webviewsRoot] } },
});
