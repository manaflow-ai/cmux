// Prints KaTeX's stylesheet for the agent pane with its fonts inlined as woff2 data URLs.
// The pane's CSP allows fonts only from data: (build-agent-pane-web.sh), and WebKit reads
// woff2, so the woff and ttf fallbacks are dropped.
//
//   node scripts/agent-pane/katex-css.mjs > katex.css
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const dist = path.dirname(require.resolve("katex/dist/katex.min.css"));
const css = readFileSync(path.join(dist, "katex.min.css"), "utf8");

let fonts = 0;
const inlined = css.replace(
  /src:url\((fonts\/[^)]+\.woff2)\) format\("woff2"\)(?:,url\([^)]+\) format\("[^"]+"\))*/g,
  (_, file) => {
    fonts += 1;
    const data = readFileSync(path.join(dist, file)).toString("base64");
    return `src:url(data:font/woff2;base64,${data}) format("woff2")`;
  },
);
if (!fonts || /url\(fonts\//.test(inlined)) {
  console.error("katex-css: KaTeX's @font-face rules changed; update the pattern");
  process.exit(1);
}
process.stdout.write(`${inlined}\n`);
