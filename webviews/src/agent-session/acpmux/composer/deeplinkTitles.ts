import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { type EditorState, Plugin, PluginKey, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import { Mapping } from "@milkdown/kit/prose/transform";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import type { CmuxLinkInfo } from "../chips/cmuxLinkResolve";
import { deeplinksKey } from "./deeplinkTokens";

// A cmux link in the draft drawn as what it names, as the sent message draws it
// (chips/CmuxLinkChip.tsx; Leo, 2026-11-08: "when I paste the URL link, when I do the right-click
// copy link to workspace thing, it should be able to render in the box that it is an actual chat
// that is there, like with the title and whatever"). Only decorations: the draft's text stays the
// link, so send, copy, paste and undo see exactly what was pasted. The link's own characters are
// hidden (markdownField.css `.is-titled-link`, display: none) between two widgets that take no
// input: the chip's front before them (`.is-titled-start`, the kind's icon on its ::before) and its
// title end after them (`.is-titled`, the title on its ::after with the sent chip's wash). The caret at either end of the link stands outside the chip, at the line's
// own height (Leo, 2026-11-09: "it's just weird that it doesn't have a caret": the link's characters
// had been drawn at no size under the chip, and the caret after them was drawn there, at no height).
// The chip acts as one character: ArrowLeft and ArrowRight step over it, Backspace and Delete take
// the whole link, and an edit that would run text into it (a paste or a typed word right after it,
// an attachment, a second link) leaves a space between, so the chip never turns back into its URL
// (Leo: "after I paste in another thing, it just becomes unformatted again"). A selection or caret
// inside the link (a drag, a value set from outside) still brings its text back to edit.
// The links come from deeplinkTokens.ts's decorations, so nothing reads the draft again here.

/// The class a titled link's chip draws with (markdownField.css).
export const TITLED_CLASS = "is-titled";
/// The class of a titled link's own characters, hidden under the chip (markdownField.css).
export const TITLED_LINK_CLASS = "is-titled-link";
/// The class of the chip's front, its kind icon, before the link's characters (markdownField.css).
export const TITLED_START_CLASS = "is-titled-start";

export type DeeplinkTitles = {
  /// What a link names now, from the page's stores; undefined keeps it a link.
  known(href: string): CmuxLinkInfo | undefined;
  /// Hears a change of anything `known` reads; returns its stop.
  subscribe(listener: () => void): () => void;
  /// The chip's label for `info` (its title, and another machine's name).
  label(info: CmuxLinkInfo): string;
  /// The CSS mask image of `info`'s kind icon (icons/iconMask.ts), or undefined for none.
  icon?(info: CmuxLinkInfo): string | undefined;
};

/// A link drawn as its chip: its range in the draft and its text there.
type Chip = { from: number; to: number; text: string };

const key = new PluginKey<number>("acpmuxDeeplinkTitles");

/// What ends a link (deeplinks.ts): a space, a bracket, or a leaf (an attachment, a line break).
const LINK_END = /[\s<>()"'`[\]￼]/;
/// What a link may not follow (deeplinks.ts's lookbehind).
const LINK_STUCK = /[\w/.:~@+-]/;
/// Sentence punctuation a link's end leaves as text (deeplinks.ts): "chip." stays the chip.
const LINK_TRAIL = /[.,;:!?*_]/;

/// The character of the textblock just after `pos` (a leaf reads as U+FFFC), or "" at its end.
function charAfter(doc: ProseNode, pos: number): string {
  const $pos = doc.resolve(pos);
  if (!$pos.parent.inlineContent || $pos.parentOffset >= $pos.parent.content.size) return "";
  return doc.textBetween(pos, pos + 1, undefined, "￼");
}

/// The character of the textblock just before `pos`, or "" at its start.
function charBefore(doc: ProseNode, pos: number): string {
  const $pos = doc.resolve(pos);
  if (!$pos.parent.inlineContent || $pos.parentOffset <= 0) return "";
  return doc.textBetween(pos - 1, pos, undefined, "￼");
}

/// The chip's title end: no text of its own (the title is its ::after), and no input.
function chipElement(title: string, kind: string, href: string, icon: string | undefined): HTMLElement {
  const chip = document.createElement("span");
  chip.className = TITLED_CLASS;
  chip.setAttribute("contenteditable", "false");
  chip.dataset.title = title;
  chip.dataset.kind = kind;
  chip.dataset.link = href;
  // The wash reaches back under the front's icon (markdownField.css).
  if (icon) chip.dataset.icon = "";
  return chip;
}

/// An empty image before the chip's front, as CodeMirror's widget buffer: WebKit draws no caret
/// before an element that takes no input at a line's start, so the caret there stands after this.
function caretBuffer(): HTMLElement {
  const buffer = document.createElement("img");
  buffer.className = "acpmux-caret-buffer";
  buffer.alt = "";
  buffer.setAttribute("aria-hidden", "true");
  return buffer;
}

/// The chip's front: the kind's icon on its ::before (markdownField.css), as the sent chip draws it.
/// A box of its own before the link's characters, so the caret before the chip stands beside a drawn
/// element in WebKit too, never against the hidden text alone (at a line's start WebKit drew none).
function chipStart(icon: string | undefined): HTMLElement {
  const start = document.createElement("span");
  start.className = TITLED_START_CLASS;
  start.setAttribute("contenteditable", "false");
  if (icon) {
    start.dataset.icon = "";
    start.style.setProperty("--cmux-link-icon", icon);
  }
  return start;
}

/// Draws each known link in the draft as its chip. `titles` undefined draws nothing.
export function deeplinkTitlesPlugin(titles: DeeplinkTitles | undefined): Plugin {
  let cached:
    | { links: DecorationSet; head: number; anchor: number; version: number; set: DecorationSet; chips: Chip[] }
    | undefined;
  const decorate = (state: EditorState): { set: DecorationSet; chips: Chip[] } => {
    const links = deeplinksKey.getState(state);
    if (!titles || !links) return { set: DecorationSet.empty, chips: [] };
    const version = key.getState(state) ?? 0;
    const { head, anchor } = state.selection;
    if (
      cached &&
      cached.links === links &&
      cached.head === head &&
      cached.anchor === anchor &&
      cached.version === version
    )
      return cached;
    const found = links.find(undefined, undefined, (spec) => typeof spec.deeplink === "string");
    const decorations: Decoration[] = [];
    const chips: Chip[] = [];
    for (const link of found) {
      // The caret or a selection inside the link: its text, to edit.
      const inside = (head > link.from && head < link.to) || (anchor > link.from && anchor < link.to);
      if (inside) continue;
      const href = link.spec.deeplink as string;
      const info = titles.known(href);
      if (!info) continue;
      const title = titles.label(info);
      const icon = titles.icon?.(info);
      decorations.push(
        // Before the position before the link (side -1): the caret there stands after it.
        Decoration.widget(link.from, caretBuffer, { side: -1, key: "caret-buffer", raw: true }),
        // After the position before the link (side 1): the caret there stands before the chip.
        Decoration.widget(link.from, () => chipStart(icon), { side: 1, key: `start\n${icon ?? ""}` }),
        Decoration.inline(link.from, link.to, { class: TITLED_LINK_CLASS }),
        // Before the position after the link (side -1): the caret there stands after the chip.
        Decoration.widget(link.to, () => chipElement(title, info.kind, href, icon), {
          side: -1,
          key: `${href}\n${title}\n${info.kind}\n${icon ?? ""}`,
        }),
      );
      chips.push({ from: link.from, to: link.to, text: state.doc.textBetween(link.from, link.to, undefined, "￼") });
    }
    const set = decorations.length ? DecorationSet.create(state.doc, decorations) : DecorationSet.empty;
    cached = { links, head, anchor, version, set, chips };
    return cached;
  };

  /// The chip whose `edge` ("from" or "to") is at `pos`.
  const chipAt = (state: EditorState, pos: number, edge: "from" | "to") =>
    decorate(state).chips.find((chip) => chip[edge] === pos);

  /// ArrowLeft/ArrowRight step over a chip as over one character; Backspace and Delete take it whole.
  const handleKeyDown = (view: EditorView, event: KeyboardEvent): boolean => {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return false;
    const { state } = view;
    const { selection } = state;
    if (!(selection instanceof TextSelection)) return false;
    const back = event.key === "ArrowLeft" || event.key === "Backspace";
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      // A selection without Shift collapses first, as the browser does; the chip is stepped over after.
      if (!event.shiftKey && !selection.empty) return false;
      const chip = chipAt(state, selection.head, back ? "to" : "from");
      if (!chip) return false;
      const next = back ? chip.from : chip.to;
      const anchor = event.shiftKey ? selection.anchor : next;
      view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, anchor, next)).scrollIntoView());
      return true;
    }
    if (event.key === "Backspace" || event.key === "Delete") {
      if (event.shiftKey || !selection.empty) return false;
      const { head } = selection;
      const chip = chipAt(state, head, back ? "to" : "from");
      if (chip) {
        view.dispatch(closeHistory(state.tr).delete(chip.from, chip.to).scrollIntoView());
        return true;
      }
      // The space that keeps a chip apart from the word after it (`keepChips` puts it back): the
      // key steps over it instead, so the next one takes the chip or the word.
      const space = back ? head - 1 : head;
      const edge = back ? chipAt(state, head - 1, "to") : chipAt(state, head, "to");
      if (edge && charAfter(state.doc, space) === " ") {
        const next = charAfter(state.doc, space + 1);
        if (next && !LINK_END.test(next)) {
          view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, back ? space : space + 1)));
          return true;
        }
      }
      return false;
    }
    return false;
  };

  /// The chips an input method's composition began next to, and the edits since: checked once it
  /// ends (its last step still carries the composition meta, so the check waits for `settle`).
  let composing: { chips: Chip[]; mapping: Mapping } | undefined;

  /// After an edit that ran text into a chip's link (typed or pasted right after it, an attachment
  /// placed there, a second link pasted against it), the space that keeps the chip a chip.
  const keepChips = (transactions: readonly Transaction[], previous: EditorState, state: EditorState) => {
    const settle = transactions.some((tr) => tr.getMeta(key) === "settle");
    if (!settle && !transactions.some((tr) => tr.docChanged)) return null;
    if (transactions.some((tr) => tr.getMeta("composition") !== undefined)) {
      composing ??= { chips: decorate(previous).chips, mapping: new Mapping() };
      for (const tr of transactions) composing.mapping.appendMapping(tr.mapping);
      return null;
    }
    let before: Chip[];
    const mapping = new Mapping();
    if (composing) {
      ({ chips: before } = composing);
      mapping.appendMapping(composing.mapping);
      composing = undefined;
    } else before = decorate(previous).chips;
    for (const tr of transactions) mapping.appendMapping(tr.mapping);
    if (!before.length) return null;
    const links = deeplinksKey.getState(state);
    if (!links) return null;
    const spaces = new Set<number>();
    for (const chip of before) {
      const from = mapping.mapResult(chip.from, 1);
      const to = mapping.mapResult(chip.to, -1);
      if (from.deleted || to.deleted || to.pos < from.pos) continue;
      // The link itself was edited (not only text around it): that edit is the person's.
      if (state.doc.textBetween(from.pos, to.pos, undefined, "\uFFFC") !== chip.text) continue;
      const still = links.find(from.pos, to.pos, (spec) => typeof spec.deeplink === "string");
      if (still.some((link) => link.from === from.pos && link.to === to.pos)) continue;
      // Past the sentence punctuation the link leaves as text ("chip." then a word: "chip. word").
      let end = to.pos;
      while (LINK_TRAIL.test(charAfter(state.doc, end))) end += 1;
      const after = charAfter(state.doc, end);
      if (after && !LINK_END.test(after)) spaces.add(end);
      const prior = charBefore(state.doc, from.pos);
      if (prior && LINK_STUCK.test(prior)) spaces.add(from.pos);
    }
    if (!spaces.size) return null;
    const tr = state.tr;
    const { anchor, head } = state.selection;
    // From the end, so each position is still where it was; a caret at a space's place stays before it.
    for (const pos of [...spaces].sort((a, b) => b - a)) tr.insertText(" ", pos);
    const keep = (pos: number) => tr.mapping.map(pos, spaces.has(pos) ? -1 : 1);
    if (state.selection instanceof TextSelection)
      tr.setSelection(TextSelection.create(tr.doc, keep(anchor), keep(head)));
    return tr;
  };

  return new Plugin({
    key,
    state: {
      init: () => 0,
      apply: (tr, value) => (tr.getMeta(key) ? value + 1 : value),
    },
    view: (view) => {
      // A rename, a new chat or a closed workspace redraws the chips (one transaction per change).
      const stop = titles?.subscribe(() => {
        if (!view.isDestroyed) view.dispatch(view.state.tr.setMeta(key, true).setMeta("addToHistory", false));
      });
      // A composition ended: once its text is in the document, the chips it ran into get their space.
      let settling: ReturnType<typeof setTimeout> | undefined;
      const ended = () => {
        clearTimeout(settling);
        settling = setTimeout(() => {
          if (!view.isDestroyed && !view.composing && composing) view.dispatch(view.state.tr.setMeta(key, "settle"));
        }, 0);
      };
      view.dom.addEventListener("compositionend", ended);
      return {
        destroy: () => {
          stop?.();
          clearTimeout(settling);
          view.dom.removeEventListener("compositionend", ended);
        },
      };
    },
    appendTransaction: keepChips,
    props: {
      decorations: (state) => decorate(state).set,
      handleKeyDown,
    },
  });
}
