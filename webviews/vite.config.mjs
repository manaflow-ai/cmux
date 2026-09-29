import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

const outDir = process.env.CMUX_WEBVIEWS_OUT_DIR ?? "../Resources/markdown-viewer/webviews-app";

export default defineConfig({
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
        // The diff surface statically imports `@pierre/diffs` (renderer,
        // worker pool manager, shiki core), which lands in one `diff-vendor`
        // chunk. Everything shiki resolves on demand (TextMate grammars,
        // bundled themes, the Oniguruma WASM blob, Pierre's own themes) stays
        // a dynamic import so each becomes its own stably named lazy chunk
        // that the diff viewer custom scheme registers per token and the page
        // fetches only for the languages present in the diff. Collapsing them
        // into `diff-vendor` evaluates every grammar on open (~10MB). The
        // eager set is budgeted by `scripts/check-webviews-diff-budget.mjs`.
        // The worker keeps its own vendored copy of shiki under
        // `Resources/markdown-viewer/diff-viewer/worker-pool`; main-thread
        // grammars are resolved here and posted to it.
        manualChunks(id) {
          const shikiLanguage = id.match(/\/@shikijs\/langs\/dist\/([^/]+)\.mjs$/);
          if (shikiLanguage) {
            return `shiki-lang-${shikiLanguage[1]}`;
          }
          const shikiTheme = id.match(/\/@shikijs\/themes\/dist\/([^/]+)\.mjs$/);
          if (shikiTheme) {
            return `shiki-theme-${shikiTheme[1]}`;
          }
          if (id.includes("/shiki/dist/wasm.mjs") || id.includes("/@shikijs/engine-oniguruma/dist/wasm-inlined.mjs")) {
            return "shiki-wasm";
          }
          const pierreTheme = id.match(/\/@pierre\/theme\/dist\/(pierre-[^/]+)\.mjs$/);
          if (pierreTheme) {
            return `pierre-theme-${pierreTheme[1]}`;
          }
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
