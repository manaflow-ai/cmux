import { reactWithCompiler } from "./reactCompiler.mjs";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const previewRoot = path.join(webviewsRoot, "src/agent-session/acpmux-preview");

export default defineConfig({
  base: "./",
  root: previewRoot,
  server: {
    host: "127.0.0.1",
    port: 4175,
    // The repository root: the agent question gallery reads the shared fixtures in Packages/Shared.
    fs: { allow: ["../..", "../../..", "../../../.."] },
    watch: {
      usePolling: true,
      interval: 250,
      ignored: ["**/node_modules/**"],
    },
  },
  plugins: [...reactWithCompiler()],
  build: {
    outDir: path.join(webviewsRoot, "dist/acpmux-agent-session-preview"),
    emptyOutDir: true,
    target: "es2022",
    // The shared stylesheet's Tailwind import (with `source(...)`) is left as
    // is here; Lightning CSS, Vite 8's default minifier, rejects it.
    cssMinify: "esbuild",
    rolldownOptions: { input: path.join(previewRoot, "index.html") },
  },
});
