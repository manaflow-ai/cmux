import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import { deeplinks } from "./deeplinks";

// cmux deeplinks in the draft (Leo, 2026-11-03: "hm i wonder if those should be rendered the
// deeplinks within the composer too..."): a cmux app link (`cmux://workspace/ws_…`,
// `cmux-nightly://agent/…`, in any build's scheme) or a web deeplink (`https://cmux.com/deeplink/…`)
// draws as a link, as the sent prompt draws it (conversation/PromptText.tsx). The look is a
// decoration, so the draft's text stays the URL: send, copy and undo see exactly what was typed.
// An edit reads again only the textblocks it changed, never the whole prompt per key.

/// The class a deeplink draws with (markdownField.css).
export const DEEPLINK_CLASS = "acpmux-deeplink";

export type DeeplinkLook = "link" | "chip" | "plain";

const key = new PluginKey<DecorationSet>("acpmuxDeeplinks");

/// The decorations of the deeplinks in the textblock at `pos`, the old ones there taken out first.
function redecorate(set: DecorationSet, doc: ProseNode, block: ProseNode, pos: number, look: DeeplinkLook) {
  const start = pos + 1;
  const end = start + block.content.size;
  const old = set.find(start, end);
  const next = old.length ? set.remove(old) : set;
  // A leaf (a line break, a placed attachment) is one position: one character that ends a link.
  const text = block.textBetween(0, block.content.size, undefined, "￼");
  const found = deeplinks(text);
  if (!found.length) return next;
  return next.add(
    doc,
    found.map((link) =>
      Decoration.inline(start + link.start, start + link.end, {
        class: `${DEEPLINK_CLASS} is-${look}`,
        "data-deeplink": link.href,
      }),
    ),
  );
}

/// Runs `visit` on each textblock (not code) that `from...to` touches.
function eachTextblock(doc: ProseNode, from: number, to: number, visit: (block: ProseNode, pos: number) => void) {
  const size = doc.content.size;
  doc.nodesBetween(Math.max(0, Math.min(from, size)), Math.max(0, Math.min(to, size)), (node, pos) => {
    if (!node.isTextblock) return true;
    if (!node.type.spec.code) visit(node, pos);
    return false;
  });
}

/// Draws each cmux deeplink in the draft with `look` (composer/deeplinkLook.experiment.ts); `plain`
/// draws nothing.
export function deeplinkTokensPlugin(look: DeeplinkLook): Plugin {
  const decorateAll = (doc: ProseNode) => {
    let set = DecorationSet.empty;
    if (look === "plain") return set;
    doc.descendants((node, pos) => {
      if (!node.isTextblock) return true;
      if (!node.type.spec.code) set = redecorate(set, doc, node, pos, look);
      return false;
    });
    return set;
  };
  return new Plugin({
    key,
    state: {
      init: (_config, state) => decorateAll(state.doc),
      apply: (tr, value, _old, state) => {
        if (!tr.docChanged || look === "plain") return value;
        const { doc } = state;
        let set = value.map(tr.mapping, doc);
        tr.mapping.maps.forEach((map, index) => {
          const later = tr.mapping.slice(index + 1);
          map.forEach((_oldFrom, _oldTo, newFrom, newTo) => {
            eachTextblock(doc, later.map(newFrom, -1), later.map(newTo, 1), (block, pos) => {
              set = redecorate(set, doc, block, pos, look);
            });
          });
        });
        return set;
      },
    },
    props: {
      decorations: (state) => key.getState(state),
    },
  });
}
