import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";

// The prompt's `@` mentions as inline chips (composerV2.css): the `@path` the @ picker writes
// (mentionItems.ts mentionText, quoted when the path has a space), or one typed by hand, gets a
// decoration with a class. The draft's text stays what was written: send, copy and undo see plain
// text. An edit reads again only the textblocks it changed, never the whole prompt per key. The
// chips draw only while the composer refresh is on (the box carries `data-composer-v2`); with it
// off the editor shows no decoration, so its DOM is as before.

/// The class a mention draws with (composerV2.css).
export const MENTION_CHIP_CLASS = "acpmux-mention-chip";

/// The switch's attribute on the composer box (ComposerBox.tsx).
const V2_BOX = "[data-composer-v2]";

const key = new PluginKey<DecorationSet>("acpmuxMentionChips");

/// An `@` at a line's start or after a space or an opening bracket (an `@` inside a word, an email
/// address, is no mention), then a quoted path or a run with no space. A leaf in the text (a line
/// break, a placed attachment) reads as U+FFFC and ends the run.
const MENTION = /(^|[\s([])@("[^"\n￼]+"|[^\s"@￼]+)/g;
/// Sentence punctuation after a bare mention is not part of its path.
const TRAILING = /[.,;:!?)\]]+$/;

/// The mentions in `text`, as [start, end) offsets.
export function mentionRanges(text: string): [number, number][] {
  const out: [number, number][] = [];
  if (!text.includes("@")) return out;
  MENTION.lastIndex = 0;
  for (let found = MENTION.exec(text); found; found = MENTION.exec(text)) {
    const body = found[2]!.startsWith('"') ? found[2]! : found[2]!.replace(TRAILING, "");
    if (!body) continue;
    const start = found.index + found[1]!.length;
    out.push([start, start + 1 + body.length]);
  }
  return out;
}

/// The decorations of the mentions in the textblock at `pos`, the old ones there taken out first.
/// A mention in a code span stays code.
function redecorate(set: DecorationSet, doc: ProseNode, block: ProseNode, pos: number): DecorationSet {
  const start = pos + 1;
  const end = start + block.content.size;
  const old = set.find(start, end);
  const next = old.length ? set.remove(old) : set;
  const text = block.textBetween(0, block.content.size, undefined, "￼");
  const found = mentionRanges(text).filter(
    ([from]) =>
      !doc
        .resolve(start + from + 1)
        .marks()
        .some((mark) => mark.type.spec.code),
  );
  if (!found.length) return next;
  return next.add(
    doc,
    found.map(([from, to]) => Decoration.inline(start + from, start + to, { class: MENTION_CHIP_CLASS })),
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

function decorateAll(doc: ProseNode): DecorationSet {
  let set = DecorationSet.empty;
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    if (!node.type.spec.code) set = redecorate(set, doc, node, pos);
    return false;
  });
  return set;
}

/// Marks each `@` mention in the draft while the composer box carries the refresh's attribute.
export function mentionChipsPlugin(): Plugin {
  // Per editor ($prose makes one plugin per editor): whether its box has the refresh on, read on
  // each view update (one `closest` walk, the box's depth) and when the view is made.
  let on = false;
  const read = (view: EditorView) => {
    const now = view.dom.closest(V2_BOX) !== null;
    if (now === on) return;
    on = now;
    // Draw (or drop) the chips with no transaction: the same state, its decorations read again.
    queueMicrotask(() => {
      if (!view.isDestroyed) view.updateState(view.state);
    });
  };
  return new Plugin({
    key,
    state: {
      init: (_config, state) => decorateAll(state.doc),
      apply: (tr, value, _old, state) => {
        if (!tr.docChanged) return value;
        const { doc } = state;
        let set = value.map(tr.mapping, doc);
        tr.mapping.maps.forEach((map, index) => {
          const later = tr.mapping.slice(index + 1);
          map.forEach((_oldFrom, _oldTo, newFrom, newTo) => {
            eachTextblock(doc, later.map(newFrom, -1), later.map(newTo, 1), (block, pos) => {
              set = redecorate(set, doc, block, pos);
            });
          });
        });
        return set;
      },
    },
    view: (view) => {
      read(view);
      return { update: read };
    },
    props: {
      decorations: (state) => (on ? key.getState(state) : undefined),
    },
  });
}
