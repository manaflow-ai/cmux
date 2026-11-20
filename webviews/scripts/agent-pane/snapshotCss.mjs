// The agent page's extra sheet for the chat's drawn copy (chatSnapshot/paint.ts). The copy draws in a
// shadow root under the page's own `pane.css`, linked there too, so the renderer's one parse of it
// serves the copy as well. Rules whose selectors name `html`, `body` or `:root` match nothing in a
// shadow tree, so this sheet carries only those selectors, rewritten for the copy's stand-ins
// (`shadowSelector`), inside the same @media, @supports and @layer blocks, so they cascade in the
// page's layers as the page had them. A custom property set on a stand-in itself is left out: the copy's
// host is in the live page's <body>, so the live root's and body's variables (the same theme and look,
// shared.ts `fitsDocument`) inherit into the copy. A selector with `:focus` is left out too: the copy is
// inert and never holds focus (the focus-ring gate adds a root selector to every `:focus-visible`).
// build-agent-pane-web.sh writes it beside the page's
// sheet as `pane-copy.css`, minified (tens of KB, where a whole rewritten copy of the sheet was 1.9 MB).
//
//   bun scripts/agent-pane/snapshotCss.mjs pane.css pane-copy.css
import { transformSync } from "esbuild";
import fs from "node:fs";
import postcss from "postcss";
import { shadowSelector } from "../../src/agent-session/acpmux/chatSnapshot/shared.ts";

/** Whether `selector` is one compound (no descendant, child or sibling combinator outside brackets and
 * parentheses): it matches the stand-in it names, not an element inside the copy. */
function namesStandIn(selector) {
  let depth = 0;
  for (const char of selector.trim()) {
    if (char === "[" || char === "(") depth += 1;
    else if (char === "]" || char === ")") depth -= 1;
    else if (depth === 0 && /[\s>+~]/.test(char)) return false;
  }
  return true;
}

/** The rules of `css` whose selectors name the page's roots, only those selectors, rewritten for the
 * copy's shadow tree, each inside clones of its at-rule ancestors; keyframes are left out. */
export function snapshotCss(css) {
  const out = postcss.root();
  postcss.parse(css).walkRules((rule) => {
    const ancestors = [];
    for (let parent = rule.parent; parent && parent.type !== "root"; parent = parent.parent) {
      if (parent.type !== "atrule") return; // a nested style rule: its parent carries it
      if (/keyframes$/i.test(parent.name)) return;
      ancestors.unshift(parent);
    }
    const selectors = rule.selectors
      .map(shadowSelector)
      .filter((next, at) => next !== rule.selectors[at] && !next.includes(":focus"));
    if (selectors.length === 0) return;
    const copy = rule.clone({ selectors });
    // Every selector names a stand-in itself (no combinator): its variables inherit from the live page.
    if (selectors.every(namesStandIn)) copy.walkDecls(/^--/, (decl) => decl.remove());
    if (!copy.nodes?.length) return;
    let into = out;
    for (const atRule of ancestors) {
      const shell = atRule.clone({ nodes: [] });
      into.append(shell);
      into = shell;
    }
    into.append(copy);
  });
  return transformSync(out.toString(), { loader: "css", minify: true }).code;
}

if (import.meta.main) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) {
    console.error("usage: bun scripts/agent-pane/snapshotCss.mjs PAGE_CSS COPY_CSS");
    process.exit(2);
  }
  fs.writeFileSync(output, snapshotCss(fs.readFileSync(input, "utf8")));
}
