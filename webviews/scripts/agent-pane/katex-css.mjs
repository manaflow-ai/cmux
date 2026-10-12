// Prints KaTeX's stylesheet for the agent pane with its fonts inlined as woff2 data URLs.
// The pane's CSP allows fonts only from data: (build-agent-pane-web.sh), and WebKit reads
// woff2, so the woff and ttf fallbacks are dropped.
//
// With --script it prints a classic script that adds the sheet to the page instead: the pane
// loads it with KaTeX (conversation/Math.tsx), so the page does not parse the fonts before its
// first frame (bd cx-z9kz0). The CSP allows same-origin scripts and inline styles.
//
//   node scripts/agent-pane/katex-css.mjs [--script] > katex.css
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
if (process.argv.includes("--script")) {
  // A script file of its own, never inside HTML, so the sheet needs no </script> escaping.
  const sheet = JSON.stringify(inlined);
  process.stdout.write(
    `(() => {\n  const style = document.createElement("style");\n  style.dataset.katex = "";\n  style.textContent = ${sheet};\n  document.head.append(style);\n})();\n`,
  );
} else {
  process.stdout.write(`${inlined}\n`);
}
