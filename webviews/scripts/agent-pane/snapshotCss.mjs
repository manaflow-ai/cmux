// The agent page's sheet for the chat's drawn copy (chatSnapshot/paint.ts): the page's own rules with
// `html`, `body` and `:root` in each selector naming the copy's stand-ins (`shadowSelector`), so the
// copy cascades in its shadow tree as the page did. build-agent-pane-web.sh writes it beside the page's
// sheet as `pane-copy.css`, a file every chat page of the renderer shares: the copy links it, and
// Blink parses it once per renderer instead of once per page (it was a constructed sheet of the whole
// page sheet per chat).
//
//   bun scripts/agent-pane/snapshotCss.mjs pane.css pane-copy.css
import fs from "node:fs";
import postcss from "postcss";
import { shadowSelector } from "../../src/agent-session/acpmux/chatSnapshot/shared.ts";

/** `css` with every style rule's selector rewritten for the copy's shadow tree; keyframes keep theirs. */
export function snapshotCss(css) {
  const root = postcss.parse(css);
  root.walkRules((rule) => {
    if (rule.parent?.type === "atrule" && /keyframes$/i.test(rule.parent.name)) return;
    const next = shadowSelector(rule.selector);
    if (next !== rule.selector) rule.selector = next;
  });
  return root.toString();
}

if (import.meta.main) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) {
    console.error("usage: bun scripts/agent-pane/snapshotCss.mjs PAGE_CSS COPY_CSS");
    process.exit(2);
  }
  fs.writeFileSync(output, snapshotCss(fs.readFileSync(input, "utf8")));
}
