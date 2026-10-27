// esbuild plugin for the agent pane: KaTeX's stylesheet becomes a module that adds it to the page
// as a <style>, with its fonts inlined as woff2 data URLs. conversation/katexStyle.ts imports the
// stylesheet beside KaTeX, only when a reply first draws math, so the module lands in that chunk
// and a chat without math never parses ~300 KB of fonts. The pane's CSP allows inline style and
// fonts only from data: (build-agent-pane-web.sh), and WebKit reads woff2, so the woff and ttf
// fallbacks are dropped.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);

/** KaTeX's stylesheet with its fonts inlined. */
export function katexCss() {
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
  if (!fonts || /url\(fonts\//.test(inlined))
    throw new Error("katexStylePlugin: KaTeX's @font-face rules changed; update the pattern");
  return inlined;
}

/**
 * With `split` (the agent pane, and the pages' multi-entry run in scripts/pages/build-pages.mjs),
 * the stylesheet's module adds it to the page; KaTeX's chunk carries it. A bundle without chunks
 * gets an empty module instead, so its one script does not carry ~350 KB of fonts for math it
 * draws unstyled.
 */
export function katexStylePlugin({ split }) {
  return {
    name: "katex-style",
    setup(build) {
      build.onResolve({ filter: /^katex\/dist\/katex\.min\.css$/ }, () => ({
        path: "katex-style.js",
        namespace: "katex-style",
      }));
      build.onLoad({ filter: /.*/, namespace: "katex-style" }, () => ({
        contents: split
          ? `const style = document.createElement("style");\nstyle.dataset.katex = "";\nstyle.textContent = ${JSON.stringify(katexCss())};\ndocument.head.append(style);\n`
          : "",
        loader: "js",
      }));
    },
  };
}
