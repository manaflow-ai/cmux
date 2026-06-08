import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

const outDir = process.env.CMUX_WEBVIEWS_OUT_DIR ?? "../Resources/markdown-viewer/webviews-app";

export default defineConfig({
  // Relative asset base. The bundle is served from a sub-path (the diff viewer
  // custom scheme serves under `<token>/assets/cmux-webviews-app/`, and the
  // app-bundle file load is nested too), so asset URLs (e.g. Monaco's emitted
  // worker) must be relative, not rooted at `/`.
  base: "./",
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  plugins: [
    react({
      babel: {
        // React Compiler. React 19 ships the required react/compiler-runtime.
        plugins: [["babel-plugin-react-compiler", { target: "19" }]],
      },
    }),
    tailwindcss(),
  ],
  build: {
    emptyOutDir: true,
    minify: "esbuild",
    outDir,
    // The macOS app supplies its own host HTML (the CLI builds the diff viewer
    // page; build-webviews-app.sh writes agent-session.html) and loads
    // `main.mjs` as the module entry, so there is no Vite HTML entry. We drive
    // the build from a single JS entry via `rollupOptions.input` instead of
    // library mode. Dropping `build.lib` + `inlineDynamicImports` lets Rollup
    // split each surface (diff viewer vs agent session) and shared vendor code
    // into separate chunks that load on demand via relative `import()`. Both
    // serving paths already handle sibling chunks: the diff viewer custom
    // scheme registers every emitted `.js`/`.mjs`, and the agent-session file
    // load grants read access to the whole output directory.
    modulePreload: false,
    // Monaco's `?worker` import builds a worker bundle. Emit it as an ES module
    // worker with a stable name (no hash) so `new Worker(url, {type:"module"})`
    // works and the file overwrites in place in the diff viewer asset cache,
    // matching the main bundle's stable-name policy above.
    worker: {
      format: "es",
      rollupOptions: {
        output: {
          entryFileNames: "chunks/[name].mjs",
          chunkFileNames: "chunks/[name].mjs",
          assetFileNames: "assets/[name][extname]",
        },
      },
    },
    rollupOptions: {
      input: { main: "src/main.tsx" },
      output: {
        format: "es",
        entryFileNames: "main.mjs",
        // Stable (un-hashed) chunk names. The diff viewer copies these into its
        // long-lived `/tmp/cmux-diff-viewer-$uid/assets/cmux-webviews-app`
        // cache and overwrites in place via a size+mtime check; content hashes
        // would instead orphan a new ~10MB diff-vendor copy there on every
        // rebuild since nothing prunes that dir. The bundle is served via the
        // diff viewer custom scheme (fresh per-token registration) and a
        // versioned app-bundle file load, so content-hash cache-busting buys
        // nothing here. The chunk set is small and explicitly named, so stable
        // names do not collide.
        chunkFileNames: "chunks/[name].mjs",
        assetFileNames: "assets/[name][extname]",
        // Collapse the diff syntax-highlighting vendor (`@pierre/diffs` +
        // shiki, including its ~300 dynamically-imported TextMate grammars)
        // into one lazy chunk loaded only by the diff surface. Left split,
        // shiki emits hundreds of grammar files that both duplicate the
        // vendored diff worker grammars and push the diff viewer custom
        // scheme's per-token allowlist toward its 1024-file cap. Per-grammar
        // lazy loading (and de-duplicating against the worker copy) is a
        // follow-up once the allowlist cap is revisited.
        manualChunks(id) {
          // Vite's dynamic-import preload helper is the one module the slim
          // entry statically imports. Pin it to the always-shared `vendor`
          // chunk so Rollup never co-locates it with a surface vendor chunk,
          // which would make the entry statically pull that chunk (e.g. the
          // agent session eagerly loading the 10MB diff vendor bundle).
          if (id.includes("vite/preload-helper")) {
            return "vendor";
          }
          if (!id.includes("node_modules")) {
            return undefined;
          }
          if (
            id.includes("/@pierre/") ||
            id.includes("/shiki/") ||
            id.includes("/@shikijs/") ||
            id.includes("/oniguruma-parser/") ||
            id.includes("/oniguruma-to-es/")
          ) {
            return "diff-vendor";
          }
          // Collapse Monaco into one lazy chunk loaded only by the editor
          // surface (same rationale as diff-vendor): keep the entry/agent/diff
          // surfaces free of Monaco and the emitted-file count well under the
          // diff viewer allowlist cap.
          if (id.includes("/monaco-editor/")) {
            return "monaco-vendor";
          }
          // Framework code both surfaces share. Pinning it to a stable `vendor`
          // chunk name keeps the shared chunk from being renamed (and rehashed)
          // whenever an unrelated shared module changes.
          if (
            id.includes("/react/") ||
            id.includes("/react-dom/") ||
            id.includes("/react-compiler-runtime/") ||
            id.includes("/scheduler/") ||
            id.includes("/@tanstack/")
          ) {
            return "vendor";
          }
          return undefined;
        },
      },
    },
  },
});
