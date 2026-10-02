import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Dev server for the ported agent pane prototype (src/agent-session-port). A Debug or
// tagged cmux-next launched with CMUX_NEXT_AGENT_PANE_DEV_URL=http://127.0.0.1:4177/ and the
// Port prototype selected loads the pane from here with hot reload; Swift still answers
// the handshake. The shipped page is built by scripts/cmux-next/build-agent-pane-port-web.sh.
const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));

export default defineConfig({
  root: path.join(webviewsRoot, "src/agent-session-port"),
  server: { host: "127.0.0.1", port: 4177, strictPort: true, fs: { allow: [webviewsRoot] } },
  plugins: [react({ babel: { plugins: [["babel-plugin-react-compiler", { target: "19" }]] } })],
});
