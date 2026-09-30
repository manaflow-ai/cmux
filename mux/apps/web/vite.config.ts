import { tanstackRouter } from "@tanstack/router-plugin/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, lazyPlugins } from "vite-plus";

export default defineConfig({
  // The router plugin must run before the React plugin.
  plugins: lazyPlugins(() => [
    tanstackRouter({ target: "react", autoCodeSplitting: true }),
    react(),
  ]),
});
