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

/** Whether `selector` names the shadow host (`:host`, `:host(...)`, alone or in a list's member). */
const namesHost = (selector) => /(^|[\s,>+~(]):host(?![-\w])/.test(selector);

/** The rules of `css` whose selectors name the page's roots, only those selectors, rewritten for the
 * copy's shadow tree, each inside clones of its at-rule ancestors; keyframes are left out. Then, unlayered
 * and last, `:host{--x:inherit}` for every custom property a page rule sets on `:host`: the page's sheet is
 * linked in the copy's shadow root, where `:host` names the copy's host, and the shared Tailwind theme sets
 * its variables on `:root, :host`, some as themselves (`--text-detail: var(--text-detail)`, ui/theme.generated.css
 * `@theme inline`). On the page an unlayered `:root` rule wins, but on the host only the layered theme rule
 * matched: the cycle left `--text-detail` unset across the copy, its folder trust ask drew at 16px against the
 * live page's 12, 4 px taller, and the swap never found the live page matching (relaunch-shift bench; Leo,
 * 2026-11-14: "too much render shift when the thing restarts to update"). The host is in the live page's body,
 * so inheriting gives the copy the live page's own values. */
export function snapshotCss(css) {
  const out = postcss.root();
  const hostVars = new Set();
  const parsed = postcss.parse(css);
  parsed.walkRules((rule) => {
    if (!rule.selectors.some(namesHost)) return;
    rule.walkDecls(/^--/, (decl) => {
      if (decl.parent === rule) hostVars.add(decl.prop);
    });
  });
  parsed.walkRules((rule) => {
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
  if (hostVars.size > 0)
    out.append(
      postcss.rule({
        selector: ":host",
        nodes: [...hostVars].sort((a, b) => a.localeCompare(b)).map((prop) => postcss.decl({ prop, value: "inherit" })),
      }),
    );
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
