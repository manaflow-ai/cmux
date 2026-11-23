// The agent page's sheet ships without its source comments. They were 638 KB of the 1.96 MB
// pane.css, and every renderer that opens a chat tokenizes the whole file before the page's first
// style pass (Blink's ParseAuthorStyleSheet). Rules and their order are untouched: only comment
// nodes go, so a rule reads in the page as it reads in its source sheet. A `/*!` comment (a license
// notice, Tailwind's) stays.
//
//   bun scripts/agent-pane/paneCssComments.mjs pane.css   # rewrites the file in place
import { readFile, writeFile } from "node:fs/promises";
import postcss from "postcss";

/** `css` with every comment removed except `/*!` notices. */
export function withoutComments(css) {
  const root = postcss.parse(css);
  root.walkComments((comment) => {
    if (!comment.text.startsWith("!")) comment.remove();
  });
  return root.toString();
}

if (import.meta.main ?? process.argv[1]?.endsWith("paneCssComments.mjs")) {
  const files = process.argv.slice(2);
  if (!files.length) {
    console.error("usage: paneCssComments.mjs <file.css>...");
    process.exit(2);
  }
  for (const file of files) await writeFile(file, withoutComments(await readFile(file, "utf8")));
}
