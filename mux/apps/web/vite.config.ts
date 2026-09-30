import { tanstackRouter } from "@tanstack/router-plugin/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, lazyPlugins } from "vite-plus";

export default defineConfig({
  // The router plugin must run before the React plugin.
  plugins: lazyPlugins(() => [
    tanstackRouter({ target: "react", autoCodeSplitting: true }),
    react(),
  ]),
  server: {
    // `cf dev` in cloud/worker serves the API on 8787.
    proxy: { "/api": { target: "http://localhost:8787", ws: true } },
  },
});
