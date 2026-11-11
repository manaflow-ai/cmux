// The caret on a line that holds an attachment is as tall as the text, never the chip (#40941:
// "after pasting an image the text caret becomes very tall"). A placed attachment is an atom in the
// line (composer/inlineNode.ts), a thumbnail two control rows tall, so the line's box is that tall.
// WebKit, the app's engine, draws the caret over the whole line box (its caret rect is the line's
// content top to bottom), so beside a thumbnail the caret ran the thumbnail's height, far above the
// words. No layout makes the chip both sit in the line and leave the line its text's height, so on
// such a line the field draws the caret itself: the native caret is clear on that paragraph only
// (markdownField.css .acpmux-md-caret-line) and a bar of the text's line height stands where the
// caret is, in the field's own caret color, blinking as the native one does. Every other line keeps
// the native caret.
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { type EditorState, Plugin, PluginKey, TextSelection } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import { INLINE_NODE } from "./inlineNode";

export const inlineCaretKey = new PluginKey("acpmux-inline-caret");

/// The paragraph the caret is in, when the caret is a plain caret in a paragraph that holds an
/// attachment: its position and node. Null for a range, a node selection, or a line of text alone.
function caretLine(state: EditorState): { pos: number; node: ProseNode } | null {
  const { selection } = state;
  if (!selection.empty || !(selection instanceof TextSelection)) return null;
  const { $head } = selection;
  const block = $head.parent;
  if ($head.depth < 1 || !block.isTextblock || block.type.spec.code) return null;
  let holds = false;
  block.forEach((child) => {
    if (child.type.name === INLINE_NODE) holds = true;
  });
  return holds ? { pos: $head.before(), node: block } : null;
}

function lineDecorations(state: EditorState): DecorationSet | null {
  const line = caretLine(state);
  if (!line) return null;
  return DecorationSet.create(state.doc, [
    Decoration.node(line.pos, line.pos + line.node.nodeSize, { class: "acpmux-md-caret-line" }),
  ]);
}

/// The paragraph's line height in CSS px.
function lineHeightOf(element: Element): number {
  const style = getComputedStyle(element);
  const height = parseFloat(style.lineHeight);
  return Number.isFinite(height) && height > 0 ? height : parseFloat(style.fontSize) * 1.2;
}

/// The vertical middle of the words on the line that spans `top`..`bottom` in `block`: the first
/// run of its own text (never a chip's label) whose box sits inside that band. Undefined when the
/// line holds no text (chips alone).
function textMiddleOnLine(block: HTMLElement, top: number, bottom: number): number | undefined {
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode: (node) =>
      node.nodeType === Node.ELEMENT_NODE
        ? (node as Element).hasAttribute("data-inline-attachment")
          ? NodeFilter.FILTER_REJECT
          : NodeFilter.FILTER_SKIP
        : NodeFilter.FILTER_ACCEPT,
  });
  const range = document.createRange();
  for (let text = walker.nextNode(); text; text = walker.nextNode()) {
    if (!text.textContent) continue;
    range.selectNodeContents(text);
    for (const rect of range.getClientRects()) {
      const middle = (rect.top + rect.bottom) / 2;
      if (rect.height > 0 && middle >= top && middle <= bottom) return middle;
    }
  }
  return undefined;
}

/// Where the drawn caret stands, in the viewport: its x and its top and bottom.
function caretPlace(view: EditorView, block: HTMLElement): { x: number; top: number; bottom: number } | null {
  const head = view.state.selection.head;
  const $head = view.state.doc.resolve(head);
  // Beside text, the text's own character (its box is the words' height); beside a chip alone, the
  // chip's edge.
  const side = $head.nodeAfter?.isText || !$head.nodeBefore ? 1 : -1;
  const at = view.coordsAtPos(head, side);
  const height = lineHeightOf(block);
  const tall = at.bottom - at.top > height * 1.25;
  let middle = (at.top + at.bottom) / 2;
  if (tall || at.bottom - at.top <= 0) {
    // A chip's box: the words on its line, else the line's foot, where a chip's line keeps its text
    // (markdownField.css .acpmux-md-inline, vertical-align: bottom).
    middle = textMiddleOnLine(block, at.top, at.bottom) ?? at.bottom - height / 2;
  }
  if (!Number.isFinite(middle) || !Number.isFinite(at.left)) return null;
  return { x: at.left, top: middle - height / 2, bottom: middle + height / 2 };
}

/// The plugin: the line decoration (native caret clear on that paragraph) and the drawn caret.
export function inlineCaretPlugin(): Plugin {
  return new Plugin({
    key: inlineCaretKey,
    props: { decorations: lineDecorations },
    view(view) {
      const caret = document.createElement("span");
      caret.className = "acpmux-md-caret";
      caret.setAttribute("aria-hidden", "true");
      let field: HTMLElement | null = null;
      let last = "";
      const hide = () => {
        caret.hidden = true;
        last = "";
      };
      hide();
      // perf-hot: one caret layout read per selection change, only on a line with an attachment composer-draft-typing
      const draw = () => {
        const line = caretLine(view.state);
        if (!line || !view.hasFocus() || view.composing) return hide();
        const block = view.nodeDOM(line.pos);
        if (!(block instanceof HTMLElement)) return hide();
        if (!field) {
          field = view.dom.closest<HTMLElement>(".acpmux-md-field") ?? view.dom.parentElement;
          field?.append(caret);
        }
        if (!field) return hide();
        const place = caretPlace(view, block);
        if (!place) return hide();
        const box = field.getBoundingClientRect();
        // In the field's scrolled content, so a scroll carries the caret with the text.
        const width = parseFloat(getComputedStyle(caret).width) || 2;
        const left = place.x - width / 2 - box.left - field.clientLeft + field.scrollLeft;
        const top = place.top - box.top - field.clientTop + field.scrollTop;
        const height = place.bottom - place.top;
        const color = getComputedStyle(view.dom).caretColor;
        const key = `${left}:${top}:${height}:${color}`;
        if (key === last && !caret.hidden) return;
        last = key;
        caret.style.transform = `translate(${left}px, ${top}px)`;
        caret.style.height = `${height}px`;
        caret.style.backgroundColor = color === "auto" ? getComputedStyle(view.dom).color : color;
        caret.hidden = false;
        // A caret that moved shows at once and starts its blink again, as the native one does.
        caret.style.animation = "none";
        void caret.offsetWidth;
        caret.style.animation = "";
      };
      const observer = typeof ResizeObserver === "function" ? new ResizeObserver(() => draw()) : undefined;
      observer?.observe(view.dom);
      view.dom.addEventListener("focus", draw);
      view.dom.addEventListener("blur", hide);
      view.dom.addEventListener("compositionstart", hide);
      view.dom.addEventListener("compositionend", draw);
      // A chip's picture loading grows its line without a transaction.
      view.dom.addEventListener("load", draw, true);
      return {
        update: draw,
        destroy() {
          observer?.disconnect();
          view.dom.removeEventListener("focus", draw);
          view.dom.removeEventListener("blur", hide);
          view.dom.removeEventListener("compositionstart", hide);
          view.dom.removeEventListener("compositionend", draw);
          view.dom.removeEventListener("load", draw, true);
          caret.remove();
        },
      };
    },
  });
}
