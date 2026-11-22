// The static gallery (src/gallery): `bun run gallery:build` writes a plain HTML folder
// (index.html, frame.html, chunks/, assets/) that any static server or file host can serve, with
// the shipped build settings (React Compiler, production React, the same chunking and the diff
// worker). `CMUX_GALLERY_OUT_DIR` names the output (default dist/gallery).
import type { Plugin } from "vite-plus";
import base from "./vite.config";
import { galleryModules } from "./dev-server/galleryHost";

const outDir = process.env.CMUX_GALLERY_OUT_DIR ?? "dist/gallery";

/** The HTML inputs live in src/gallery; the output keeps them at the folder's top. */
const flattenPages: Plugin = {
  name: "cmux-gallery-flat-pages",
  apply: "build",
  enforce: "post",
  generateBundle(_, bundle) {
    for (const item of Object.values(bundle))
      if (item.type === "asset" && item.fileName.startsWith("src/gallery/") && item.fileName.endsWith(".html")) {
        item.fileName = item.fileName.slice("src/gallery/".length);
        // Vite wrote the page's URLs relative to src/gallery/; it now sits beside chunks/ and assets/.
        item.source = String(item.source).replace(/((?:src|href)=")(?:\.\.\/)+(chunks|assets)\//g, "$1./$2/");
      }
  },
};

export default {
  ...base,
  base: "./",
  plugins: [...(base.plugins ?? []), galleryModules(), flattenPages],
  build: {
    ...base.build,
    outDir,
    emptyOutDir: true,
    rolldownOptions: {
      ...base.build?.rolldownOptions,
      input: {
        gallery: "src/gallery/index.html",
        "gallery-frame": "src/gallery/frame.html",
        "diff-worker": "src/diff-worker.ts",
      },
    },
  },
};
