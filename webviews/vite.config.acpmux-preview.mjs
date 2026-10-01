import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const previewRoot = path.join(webviewsRoot, "src/agent-session/acpmux-preview");

export default defineConfig({
  base: "./",
  root: previewRoot,
  server: { host: "127.0.0.1", port: 4175, fs: { allow: ["../..", "../../.."] }, watch: { usePolling: true, interval: 250, ignored: ["**/node_modules/**", "**/src/agent-session/solid/**", "**/src/agent-session/react/**"] } },
  plugins: [react({ babel: { plugins: [["babel-plugin-react-compiler", { target: "19" }]] } })],
  build: {
    outDir: path.join(webviewsRoot, "dist/acpmux-agent-session-preview"),
    emptyOutDir: true,
    target: "es2022",
    rollupOptions: { input: path.join(previewRoot, "index.html") },
  },
});
