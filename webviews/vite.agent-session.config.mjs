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
        plugins: [["babel-plugin-react-compiler", { target: "19" }]],
      },
    }),
    tailwindcss(),
  ],
  build: {
    emptyOutDir: false,
    minify: "esbuild",
    outDir,
    lib: {
      entry: "src/agentSessionClassic.tsx",
      formats: ["iife"],
      name: "CmuxAgentSession",
      fileName: () => "agent-session.js",
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
});
