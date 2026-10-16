import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => ({
  root: "renderer/react",
  plugins: [react()],
  define: {
    "process.env.NODE_ENV": JSON.stringify(process.env.NODE_ENV || (mode === "production" ? "production" : "development"))
  },
  build: {
    emptyOutDir: false,
    outDir: "../dist",
    lib: {
      entry: "settings-ui.jsx",
      formats: ["iife"],
      name: "CmuxSettingsUi",
      fileName: "settings-ui"
    },
    rollupOptions: {
      output: {
        entryFileNames: "settings-ui.js"
      }
    }
  }
}));
