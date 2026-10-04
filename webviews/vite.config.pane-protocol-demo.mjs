import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Dev-only demo for the pane protocol TS client (src/protocol). Serve only, never built or
// shipped. Open http://127.0.0.1:4230/#ws=<ws url>&token=<token>&cwd=<repo path> to connect to
// a pane protocol provider over WebSocket and call cmux.git.status.
const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));

export default defineConfig({
  root: path.join(webviewsRoot, "src/protocol/demo"),
  server: {
    host: "127.0.0.1",
    port: 4230,
    strictPort: true,
    fs: { allow: [webviewsRoot] },
  },
});
