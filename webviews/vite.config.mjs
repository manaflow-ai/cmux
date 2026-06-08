import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

const outDir = process.env.CMUX_WEBVIEWS_OUT_DIR ?? "../Resources/markdown-viewer/webviews-app";

export default defineConfig({
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  plugins: [
    react({
      babel: {
        // React Compiler. React 19 ships the required react/compiler-runtime.
        plugins: [["babel-plugin-react-compiler", { target: "19" }]],
      },
    }),
    tailwindcss(),
  ],
  build: {
    emptyOutDir: true,
    minify: "esbuild",
    outDir,
    lib: {
      entry: "src/main.tsx",
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
