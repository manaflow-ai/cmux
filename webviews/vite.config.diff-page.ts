import { defineConfig } from "vite-plus";
import base from "./vite.config";

// The diff viewer page of the shared page host (`cmux-page://cmux.diff/`, plans/cmux-next/diff-host.md
// S3). Same graph and chunk layout as the classic webviews app (vite.config.ts): `main.mjs`, the
// highlight worker at `chunks/diff-worker.mjs` beside the surface chunk that spawns it, and one lazy
// chunk per shiki grammar, theme and the Oniguruma WASM. Only the entry differs: the diff surface
// alone, so the agent session never ships here. scripts/cmux-next/build-diff-page-web.sh runs it and
// writes `index.html`.
const outDir =
  process.env.CMUX_DIFF_PAGE_OUT_DIR ?? "../Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/diff";

export default defineConfig({
  ...base,
  build: {
    ...base.build,
    outDir,
    rolldownOptions: {
      ...base.build?.rolldownOptions,
      input: { main: "src/pages/diff/main.tsx", "diff-worker": "src/diff-worker.ts" },
    },
  },
});
