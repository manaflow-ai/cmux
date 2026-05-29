import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "renderer/react",
  plugins: [react()],
  define: {
    "process.env.NODE_ENV": JSON.stringify("production")
  },
  build: {
    emptyOutDir: false,
    outDir: "../dist",
    lib: {
      entry: "settings-ui.jsx",
      formats: ["iife"],
      name: "CmuxSettingsUi",
      fileName: () => "settings-ui.js"
    }
  }
});
