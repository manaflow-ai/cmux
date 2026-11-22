import { reactWithCompiler } from "./reactCompiler.mjs";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Dev server for the Settings page (src/pages/settings) with hot reload. Outside the app the page
// runs on the in-memory fake transport (src/pages/settings/fakeTransport.ts). Serve only: the
// shipped page is built by scripts/cmux-next/build-pages-web.sh (PAGES) into one self-contained
// index.html.
const webviewsRoot = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const repoRoot = path.resolve(webviewsRoot, "..");

export default defineConfig({
  root: path.join(webviewsRoot, "src/pages/settings"),
  server: {
    host: "127.0.0.1",
    port: 4177,
    strictPort: true,
    // The page imports the schema from schemas/settings at the repository root.
    fs: { allow: [webviewsRoot, path.join(repoRoot, "schemas/settings")] },
  },
  plugins: [...reactWithCompiler()],
});
