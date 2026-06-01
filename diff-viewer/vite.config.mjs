import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const outDir = process.env.CMUX_DIFF_VIEWER_OUT_DIR ?? "../Resources/markdown-viewer/diff-viewer-app";

export default defineConfig({
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  plugins: [react()],
  build: {
    emptyOutDir: true,
    minify: "esbuild",
    outDir,
    lib: {
      entry: "src/main.jsx",
      formats: ["es"],
      fileName: () => "main.mjs",
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
});
