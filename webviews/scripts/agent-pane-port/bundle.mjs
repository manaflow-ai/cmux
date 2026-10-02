#!/usr/bin/env node
// Bundles the ported agent pane (src/agent-session-port) into one self-contained HTML page:
//   node scripts/agent-pane-port/bundle.mjs <out.html>
// scripts/cmux-next/build-agent-pane-port-web.sh calls it and compares or installs the result.
//
// `shiki` resolves to the trimmed copy in src/agent-session-port/shiki (JavaScript regex
// engine, curated grammars). Pierre's theme collections (every Shiki and Pierre theme,
// about 1.6 MB) are stubbed: the pane registers its own theme and never loads one by name.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const port = path.join(webviews, "src/agent-session-port");
const out = process.argv[2];
if (!out) throw new Error("usage: bundle.mjs <out.html>");

const stubThemeCollections = {
  name: "stub-theme-collections",
  setup(b) {
    b.onResolve({ filter: /^@shikijs\/themes\/|^@pierre\/theme\/[a-z-]+$/ }, (args) => ({
      path: args.path,
      namespace: "stub-theme",
    }));
    b.onLoad({ filter: /.*/, namespace: "stub-theme" }, (args) => ({
      contents: `throw new Error(${JSON.stringify(`theme ${args.path} is not bundled in the agent pane`)});`,
      loader: "js",
    }));
  },
};

const result = await build({
  entryPoints: [path.join(port, "main.tsx")],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  minify: true,
  legalComments: "none",
  alias: { shiki: path.join(port, "shiki") },
  plugins: [stubThemeCollections],
  write: false,
  outdir: "/out",
  logLevel: "warning",
});
const js = result.outputFiles.find((file) => file.path.endsWith(".js")).text;
const css = result.outputFiles.find((file) => file.path.endsWith(".css"))?.text ?? "";
// Inline script and style, loopback WebSocket only. No remote loads, no eval.
const csp =
  "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src ws://127.0.0.1:* ws://localhost:*";
const html = [
  "<!doctype html>",
  '<html lang="en">',
  "<head>",
  '<meta charset="utf-8" />',
  `<meta http-equiv="Content-Security-Policy" content="${csp}" />`,
  '<meta name="viewport" content="width=device-width, initial-scale=1" />',
  "<title>cmux Agent</title>",
  "<style>",
  css.replace(/<\/style/gi, "<\\/style"),
  "</style>",
  "</head>",
  "<body>",
  '<main id="root"></main>',
  '<script type="module">',
  js.replace(/<\/script/gi, "<\\/script").replace(/<!--/g, "<\\!--"),
  "</script>",
  "</body>",
  "</html>",
  "",
].join("\n");
fs.writeFileSync(out, html);
