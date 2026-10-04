import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite-plus";
import { cmuxCheckConfig } from "../config/vite-plus/check";
import { cmuxDevServer, DEV_SERVER_PORT } from "./dev-server/plugins";

const outDir = process.env.CMUX_WEBVIEWS_OUT_DIR ?? "../Resources/markdown-viewer/webviews-app";

export default defineConfig({
  // `vp check` reads `lint` and `fmt` from here; `vite build` ignores them.
  // ts-rs emits src/diff/generated; scripts/generate-diff-sidecar-types.sh --check
  // owns it. Stylesheets are inlined verbatim into the shipped agent pane, so
  // reformatting them would change the bundle for no behavior change.
  // The handoff schema is a published wire fixture; schema.test.ts verifies its exact bytes.
  ...cmuxCheckConfig({
    fmtIgnorePatterns: [
      "src/diff/generated/**",
      // scripts/pane-protocol-codegen.ts --check owns these bytes.
      "src/protocol/generated/**",
      // Byte-identical copy of the Rust lane's emitted IR.
      "src/protocol/ir/**",
      "**/*.css",
      "src/agent-session/acpmux/handoff/schema/acpmux-schema.json",
      "src/agent-session/acpmux/icons/cmuxIcons.json",
      // scripts/agent-icons/generate.py --check owns these bytes.
      "src/agent-session/shared/agentBrands.generated.ts",
      // scripts/icon-picker/gen-emoji-data.mjs --check owns these bytes.
      "src/icon-picker/generated/**",
      // The markdown round-trip corpus: real files whose exact bytes the editor must preserve.
      "test/fixtures/markdown-roundtrip/**",
    ],
  }),
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  // `bun run dev`: every surface on one port (dev-server/plugins.ts). Build ignores it.
  server: { host: "127.0.0.1", port: DEV_SERVER_PORT, strictPort: true },
  plugins: [
    // Serve-only dev hosts (diff sidecar, markdown shell, agent pane pages); never in the build.
    ...cmuxDevServer(),
    react({
      babel: {
        // React Compiler. React 19 ships the required react/compiler-runtime.
        plugins: [["babel-plugin-react-compiler", { target: "19" }]],
      },
    }),
    tailwindcss(),
    {
      // Vite writes root-absolute script URLs into `diff-page.html` and `markdown-page.html`; make
      // them relative to the page so the entry and its chunks resolve under any base
      // (cmux-page://cmux.diff/ and cmux.markdown/ serve the webviews-app directory as their root).
      name: "cmux-diff-page-relative-entry",
      apply: "build",
      transformIndexHtml: {
        order: "post",
        handler: (html: string) => html.replace(/(src|href)="\/(chunks|assets)\//g, '$1="./$2/'),
      },
    },
    {
      // `@pierre/diffs` declares `sideEffects: false`, which is right for the
      // main-thread exports but tree-shakes the worker entry (a self-registering
      // `onmessage` script with no exports) down to an empty chunk.
      name: "cmux-diff-worker-side-effects",
      transform(code, id) {
        if (id.endsWith("/@pierre/diffs/dist/worker/worker.js")) {
          return { code, map: null, moduleSideEffects: true };
        }
        return null;
      },
    },
  ],
  build: {
    emptyOutDir: true,
    outDir,
    // The macOS app supplies its own host HTML (the CLI builds the diff viewer
    // page; build-webviews-app.sh writes agent-session.html) and loads
    // `main.mjs` as the module entry, so there is no Vite HTML entry. We drive
    // the build from a single JS entry via `rolldownOptions.input` instead of
    // library mode. Dropping `build.lib` + `inlineDynamicImports` lets Rolldown
    // split each surface (diff viewer vs agent session) and shared vendor code
    // into separate chunks that load on demand via relative `import()`. Both
    // serving paths already handle sibling chunks: the diff viewer custom
    // scheme registers every emitted `.js`/`.mjs`, and the agent-session file
    // load grants read access to the whole output directory.
    modulePreload: false,
    rolldownOptions: {
      // `diff-page.html` is the shared page host's diff entry (cmux-page://cmux.diff/): an HTML input
      // whose module entry is chunks/diff-page.mjs, sharing every chunk, the worker and the WASM.
      // `markdown-page.html` is the markdown editor's entry (cmux-page://cmux.markdown/), the same way.
      input: {
        main: "src/main.tsx",
        "diff-worker": "src/diff-worker.ts",
        "diff-page": "diff-page.html",
        "markdown-page": "markdown-page.html",
      },
      output: {
        format: "es",
        // `main.mjs` is the page entry the host HTML loads; the worker entry
        // sits under `chunks/` so `diffSurface.mjs` can spawn it as a sibling.
        entryFileNames: (chunk: { name: string }) => (chunk.name === "main" ? "main.mjs" : "chunks/[name].mjs"),
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
        // The highlight worker (`src/diff-worker.ts`, emitted as
        // `chunks/diff-worker.mjs`) is a second entry of this same graph, so
        // shiki core lives once in `shiki-core` (imported by both threads)
        // and the WASM chunk is one file shared by the page and every worker.
        // Grammars are resolved on the main thread and posted to the workers.
        codeSplitting: {
          groups: [
            // Lazy chunks take only their own module. Rolldown groups capture
            // dependencies by default, which would fold a grammar that another
            // grammar embeds into whichever language chunk claims it first.
            { name: lazyChunkName, debugName: "lazy", priority: 10, includeDependenciesRecursively: false },
            // Shared vendor chunks keep Rollup's manualChunks behavior: their
            // otherwise unassigned dependencies (hast utilities under shiki,
            // for example) land in the same chunk. One group per chunk, in
            // this order: `shiki-core` first so `diff-vendor` cannot capture
            // shiki (which the worker needs without the renderer), and
            // `vendor` before `diff-vendor` so React stays in `vendor` and the
            // agent session does not load the diff renderer at startup.
            // `markdown-vendor` (Milkdown, ProseMirror, remark) is shared by the agent pane's
            // composer and the markdown editor page.
            ...["shiki-core", "vendor", "diff-vendor", "markdown-vendor"].map((name, index) => ({
              name,
              test: (id: string) => sharedChunkName(id) === name,
              priority: 4 - index,
              // Only what both use: the editor page's own Milkdown modules stay in its chunk, so
              // the agent pane does not load them.
              ...(name === "markdown-vendor" ? { minShareCount: 2 } : {}),
            })),
          ],
        },
      },
    },
  },
});

function lazyChunkName(id: string): string | null {
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
    return "preload-helper";
  }
  return null;
}

function sharedChunkName(id: string): string | null {
  // The highlight worker entry stays in its own entry chunk; routing it
  // into `diff-vendor` would make the worker evaluate the main-thread
  // renderer (and React) on start.
  if (id.endsWith("/@pierre/diffs/dist/worker/worker.js")) {
    return null;
  }
  if (!id.includes("node_modules")) {
    return null;
  }
  if (
    id.includes("/shiki/") ||
    id.includes("/@shikijs/") ||
    id.includes("/oniguruma-parser/") ||
    id.includes("/oniguruma-to-es/") ||
    id.includes("/node_modules/diff/")
  ) {
    return "shiki-core";
  }
  if (id.includes("/@pierre/")) {
    return "diff-vendor";
  }
  if (
    /\/node_modules\/(@milkdown|prosemirror-[a-z-]+|remark[a-z-]*|micromark[a-z-]*|mdast-util-[a-z-]+|unified|unist-util-[a-z-]+|orderedmap|rope-sequence|w3c-keyname)\//.test(
      id,
    )
  ) {
    return "markdown-vendor";
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
  return null;
}
