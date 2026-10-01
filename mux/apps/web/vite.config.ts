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
    // The local form (mux/local) serves the API on 47820; MUX_API_URL points
    // at another server, e.g. `cf dev` in cloud/worker on http://localhost:8787.
    proxy: { "/api": { target: process.env.MUX_API_URL ?? "http://127.0.0.1:47820", ws: true } },
  },
});
