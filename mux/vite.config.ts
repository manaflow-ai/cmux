import { defineConfig } from "vite-plus";

// vp check reads fmt and lint only from this root config.
export default defineConfig({
  fmt: {
    ignorePatterns: ["**/routeTree.gen.ts"],
  },
  lint: {
    ignorePatterns: ["**/routeTree.gen.ts"],
    plugins: ["react", "typescript", "oxc"],
    jsPlugins: [{ name: "vite-plus", specifier: "vite-plus/oxlint-plugin" }],
    rules: {
      "vite-plus/prefer-vite-plus-imports": "error",
      "react/rules-of-hooks": "error",
      "react/only-export-components": ["warn", { allowConstantExport: true }],
    },
    overrides: [
      {
        // Route files export `Route`; autoCodeSplitting moves their components
        // into separate chunks, so Fast Refresh still works.
        files: ["apps/web/src/routes/**"],
        rules: { "react/only-export-components": "off" },
      },
    ],
    options: { typeAware: true, typeCheck: true },
  },
  run: {
    cache: true,
  },
});
