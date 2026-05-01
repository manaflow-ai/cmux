import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  base: "/remote/",
  plugins: [vue()],
  build: {
    outDir: "../Resources/RemoteWeb",
    emptyOutDir: true,
    assetsDir: "assets",
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: (assetInfo) => {
          if (assetInfo.name?.endsWith(".css")) {
            return "assets/style.css";
          }
          return "assets/[name][extname]";
        },
      },
    },
  },
});
