import { defineConfig } from "vite";

// cmux embeds this bundle in the macOS app via a WKURLSchemeHandler.
// Output all assets relative to the index.html so they resolve under any scheme.
export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2022",
    sourcemap: false,
    chunkSizeWarningLimit: 6000,
    rollupOptions: {
      output: {
        // Keep asset paths deterministic so Swift can reference workers by name.
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
});
