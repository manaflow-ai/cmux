// Writes a page's one stylesheet from its sheets, in the order given (one path per line in
// <list>, relative to webviews/ or absolute), to stdout. build-agent-pane-web.sh builds the agent
// pane's page styles with it.
//
//   bun scripts/agent-pane/page-css.mjs <list>         # the stylesheet
//   bun scripts/agent-pane/page-css.mjs --files <list>  # the files it is written from, in order
//
// An @import never loads in the page (mid-stylesheet the browser drops it, and the page's CSP
// loads no style file), so none is written: a sheet's relative `@import "./x.css"` is inlined
// just before the sheet (where a browser puts an imported sheet), and an import of a package
// (shared/styles.css's `@import "tailwindcss"`, which only Vite resolves) is dropped. A sheet goes
// in once, the first time it is named or imported.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const IMPORT = /^@import\s+(?:url\()?["']([^"']+)["']\)?[^;\n]*;[ \t]*\r?\n?/gm;

/** The page's stylesheet for `sheets` (paths relative to `root`, or absolute), and its files in order. */
export function pageCss(sheets, root) {
  const files = [];
  let css = "";
  const add = (file) => {
    if (files.includes(file)) return;
    const text = readFileSync(file, "utf8");
    for (const [, target] of text.matchAll(IMPORT))
      if (target.startsWith("./") || target.startsWith("../")) add(path.resolve(path.dirname(file), target));
    files.push(file);
    css += text.replace(IMPORT, "");
  };
  for (const sheet of sheets) add(path.resolve(root, sheet));
  return { css, files };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const filesOnly = args[0] === "--files";
  const list = filesOnly ? args[1] : args[0];
  if (!list) {
    console.error("usage: page-css.mjs [--files] <list>");
    process.exit(2);
  }
  const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
  const { css, files } = pageCss(readFileSync(list, "utf8").split("\n").filter(Boolean), webviews);
  process.stdout.write(filesOnly ? files.map((file) => file + "\n").join("") : css);
}
