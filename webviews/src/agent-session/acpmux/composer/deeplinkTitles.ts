import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { type EditorState, Plugin, PluginKey, TextSelection, type Transaction } from "@milkdown/kit/prose/state";
import { Mapping } from "@milkdown/kit/prose/transform";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import type { CmuxLinkInfo } from "../chips/cmuxLinkResolve";
import { deeplinksKey } from "./deeplinkTokens";
import { TOOL_HREF_PREFIX } from "../toolMentions";
import { focusRoute } from "../../../ui/focusRoute";

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
// (Leo: "after I paste in another thing, it just becomes unformatted again"). A caret or selection end
// inside the link (a value set from outside) still brings its text back to edit. The pointer treats
// the chip as one character (Lucas, 2026-11-23/24: "when trying to select text it looks very weird",
// "make it work like this", a Codex recording): a press on its left half puts the caret before it,
// on its right half after it, a drag from there steps over it whole, and a double-click selects it.
// The press is the plugin's, not the browser's: the link's characters are hidden, so WebKit placed a
// press on the chip at either end, and a drag from a selected chip moved the draft (drag and drop).
// A selection across the chip draws it as selected text (markdownField.css, `data-selected`).
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
  /// A full-color picture's URL drawn in place of the icon mask (a built-in tool's, toolMentions.ts `image`).
  image?(info: CmuxLinkInfo): string | undefined;
};

/// A link drawn as its chip: its range in the draft, its text there, and whether a selection covers it.
type Chip = { from: number; to: number; text: string; selected: boolean };

/// `version` counts redraws asked from outside (a rename, a composition's end); `typed` is whether the
/// last change to the caret was an edit (typing, a paste) and not a click, an arrow or a drag.
type TitlesState = { version: number; typed: boolean };

const key = new PluginKey<TitlesState>("acpmuxDeeplinkTitles");

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

/// The chip's front: the kind's icon on its ::before (markdownField.css), as the sent chip draws it.
/// A box of its own before the link's characters, so the caret before the chip stands beside a drawn
/// element in WebKit too, never against the hidden text alone (at a line's start WebKit drew none).
function chipStart(icon: string | undefined, image = false): HTMLElement {
  const start = document.createElement("span");
  start.className = TITLED_START_CLASS;
  start.setAttribute("contenteditable", "false");
  if (icon) {
    start.dataset.icon = "";
    // A picture draws as itself, not as a mask in the text color (markdownField.css).
    if (image) start.dataset.image = "";
    start.style.setProperty("--cmux-link-icon", icon);
  }
  return start;
}

/// Whether the caret was last moved by typing: an edit that ends at the caret (a letter, a paste) is;
/// a click, an arrow or a drag that moves it is not; an edit elsewhere (an attachment taken out) and a
/// caret put back where it was (a focus restored) leave it as it was.
function typedAfter(tr: Transaction, before: EditorState, typed: boolean): boolean {
  const { head, empty } = tr.selection;
  if (tr.docChanged) {
    let atCaret = false;
    tr.mapping.maps.forEach((map, index) =>
      map.forEach((_oldStart, _oldEnd, _newStart, newEnd) => {
        if (tr.mapping.slice(index + 1).map(newEnd) === head) atCaret = true;
      }),
    );
    return atCaret || typed;
  }
  if (!tr.selectionSet) return typed;
  return empty && head === before.selection.head && before.selection.empty ? typed : false;
}

/// Draws each known link in the draft as its chip. `titles` undefined draws nothing.
export function deeplinkTitlesPlugin(titles: DeeplinkTitles | undefined): Plugin {
  let cached:
    | {
        links: DecorationSet;
        head: number;
        anchor: number;
        version: number;
        typed: boolean;
        set: DecorationSet;
        chips: Chip[];
      }
    | undefined;
  const decorate = (state: EditorState): { set: DecorationSet; chips: Chip[] } => {
    const links = deeplinksKey.getState(state);
    if (!titles || !links) return { set: DecorationSet.empty, chips: [] };
    const { version, typed } = key.getState(state) ?? { version: 0, typed: false };
    const { head, anchor, from, to, empty } = state.selection;
    if (
      cached &&
      cached.links === links &&
      cached.head === head &&
      cached.anchor === anchor &&
      cached.version === version &&
      cached.typed === typed
    )
      return cached;
    const found = links.find(undefined, undefined, (spec) => typeof spec.deeplink === "string");
    const decorations: Decoration[] = [];
    const chips: Chip[] = [];
    for (const link of found) {
      const href = link.spec.deeplink as string;
      // The caret or a selection end inside the link: its text, to edit. A tool's word (`@computer-use`,
      // toolMentions.ts) also stays text while it is being typed, the caret at its end: it may still be
      // typed on (`@computer-user`), and a badge there would get a space put after it (`keepChips`).
      // A caret put there by a click or an arrow, or a drag that starts there, keeps the badge.
      const tool = href.startsWith(TOOL_HREF_PREFIX) && empty && typed && head === link.to;
      const inside = (head > link.from && head < link.to) || (anchor > link.from && anchor < link.to);
      if (inside || tool) continue;
      const info = titles.known(href);
      if (!info) continue;
      const title = titles.label(info);
      const image = titles.image?.(info);
      const icon = image ? `url("${image}")` : titles.icon?.(info);
      const selected = !empty && from <= link.from && to >= link.to;
      decorations.push(
        // After the position before the link (side 1): the caret there stands before the chip.
        Decoration.widget(link.from, () => chipStart(icon, image !== undefined), {
          side: 1,
          key: `start\n${icon ?? ""}`,
        }),
        Decoration.inline(link.from, link.to, { class: TITLED_LINK_CLASS }),
        // Before the position after the link (side -1): the caret there stands after the chip.
        // Its key leaves out `selected`: a new element under a drag lost WebKit's place in it. The
        // plugin's view marks the element instead (`markSelected`).
        Decoration.widget(link.to, () => chipElement(title, info.kind, href, icon), {
          side: -1,
          key: `${href}\n${title}\n${info.kind}\n${icon ?? ""}`,
          selected,
        }),
      );
      chips.push({
        from: link.from,
        to: link.to,
        text: state.doc.textBetween(link.from, link.to, undefined, "￼"),
        selected,
      });
    }
    const set = decorations.length ? DecorationSet.create(state.doc, decorations) : DecorationSet.empty;
    cached = { links, head, anchor, version, typed, set, chips };
    return cached;
  };

  /// Marks each chip's title end a selection covers (markdownField.css draws it as selected text).
  const markSelected = (view: EditorView) => {
    const { chips } = decorate(view.state);
    for (const end of view.dom.querySelectorAll<HTMLElement>(`.${TITLED_CLASS}`)) {
      const at = view.posAtDOM(end, 0);
      const on = chips.some((chip) => chip.to === at && chip.selected);
      if (on !== "selected" in end.dataset) {
        if (on) end.dataset.selected = "";
        else delete end.dataset.selected;
      }
    }
  };

  /// The chip a pointer is over (its front or its title end), and the boxes it is drawn in.
  const chipUnder = (view: EditorView, target: EventTarget | null) => {
    if (!(target instanceof Element)) return undefined;
    const part = target.closest(`.${TITLED_START_CLASS}, .${TITLED_CLASS}`);
    if (!part || !view.dom.contains(part)) return undefined;
    const front = part.classList.contains(TITLED_START_CLASS);
    const at = view.posAtDOM(part, 0);
    const chip = decorate(view.state).chips.find((each) => (front ? each.from : each.to) === at);
    if (!chip) return undefined;
    // Its two parts, drawn as one chip: the front (the icon) and the title end (the wash and title).
    const rects: DOMRect[] = [];
    for (const each of view.dom.querySelectorAll(`.${TITLED_START_CLASS}, .${TITLED_CLASS}`)) {
      const edge = each.classList.contains(TITLED_START_CLASS) ? chip.from : chip.to;
      if (view.posAtDOM(each, 0) === edge) rects.push(...each.getClientRects());
    }
    return rects.length ? { chip, rects } : undefined;
  };

  /// The end of a chip a pointer at `x`, `y` stands at: before it on its left half, after it on its
  /// right. A title that wraps is halved on the pointer's line alone.
  const sideOf = (hit: { chip: Chip; rects: DOMRect[] }, x: number, y: number) => {
    const line = hit.rects.filter((rect) => y >= rect.top && y <= rect.bottom);
    const rects = line.length ? line : hit.rects;
    const left = Math.min(...rects.map((rect) => rect.left));
    const right = Math.max(...rects.map((rect) => rect.right));
    return x < (left + right) / 2 ? hit.chip.from : hit.chip.to;
  };

  /// The draft position under a dragging pointer: a chip as one character, never inside its word.
  /// Past the field's edge it is the field's nearest point (as a drag of selected text goes on outside
  /// it), and that point is tested for a chip too: the field's first chip starts at its left edge, so
  /// a drag out past it to the left ended after it and dropped it from the selection.
  const posAtPointer = (view: EditorView, event: MouseEvent): number | undefined => {
    const box = view.dom.getBoundingClientRect();
    const left = Math.min(Math.max(event.clientX, box.left + 1), box.right - 1);
    const top = Math.min(Math.max(event.clientY, box.top + 1), box.bottom - 1);
    const under =
      left === event.clientX && top === event.clientY ? event.target : view.root.elementFromPoint(left, top);
    const hit = chipUnder(view, under);
    if (hit) return sideOf(hit, left, top);
    const pos = view.posAtCoords({ left, top })?.pos;
    if (pos === undefined) return undefined;
    const chip = decorate(view.state).chips.find((each) => pos > each.from && pos < each.to);
    if (!chip) return pos;
    return pos - chip.from < chip.to - pos ? chip.from : chip.to;
  };

  /// A press in a draft with a chip: the caret under the pointer (on a chip, at its nearer end), then a
  /// drag selects from there, the chip as one character. WebKit's own drag went wrong across a chip
  /// (out past it to the left it selected the end of the line), so the plugin moves the selection for
  /// a single press anywhere in the draft's text; a draft without a chip keeps the browser's, as do a
  /// double or triple press on text (a word, a paragraph) and a press on an attachment.
  const press = (view: EditorView, event: MouseEvent): boolean => {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.altKey || event.detail > 2) return false;
    if (!decorate(view.state).chips.length) return false;
    const hit = chipUnder(view, event.target);
    if (!hit) {
      if (event.detail !== 1) return false;
      const target = event.target instanceof Element ? event.target : null;
      if (!target || target.closest('[contenteditable="false"]')) return false;
    }
    const at = hit ? sideOf(hit, event.clientX, event.clientY) : posAtPointer(view, event);
    if (at === undefined) return false;
    event.preventDefault();
    // The press's own focus went with its default (prevented, so WebKit draws no selection of its own).
    focusRoute(view, "person", "a press in the draft takes the caret there");
    const { selection } = view.state;
    if (hit && event.detail === 2) {
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, hit.chip.from, hit.chip.to)));
      return true;
    }
    const anchor = event.shiftKey && selection instanceof TextSelection ? selection.anchor : at;
    // `between`: a position between blocks (their gap, a rule, below the last) moves into text.
    const select = (head: number) => {
      const { state } = view;
      const next = TextSelection.between(state.doc.resolve(anchor), state.doc.resolve(head));
      if (!next.eq(state.selection)) view.dispatch(state.tr.setSelection(next).scrollIntoView());
    };
    select(at);
    // The positions are this draft's: a key pressed with the button down ends the drag.
    const doc = view.state.doc;
    const page = view.dom.ownerDocument;
    const stop = () => {
      page.removeEventListener("mousemove", move, true);
      page.removeEventListener("mouseup", stop, true);
    };
    const move = (moved: MouseEvent) => {
      // A release outside the window never reached the page: no button down is the drag's end too.
      if (view.isDestroyed || moved.buttons === 0 || view.state.doc !== doc) return stop();
      const head = posAtPointer(view, moved);
      if (head !== undefined) select(head);
    };
    page.addEventListener("mousemove", move, true);
    page.addEventListener("mouseup", stop, true);
    return true;
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
      init: (): TitlesState => ({ version: 0, typed: false }),
      apply: (tr, value, before): TitlesState => {
        const version = tr.getMeta(key) ? value.version + 1 : value.version;
        const typed = typedAfter(tr, before, value.typed);
        return version === value.version && typed === value.typed ? value : { version, typed };
      },
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
      markSelected(view);
      return {
        update: (next) => markSelected(next),
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
      handleDOMEvents: { mousedown: press },
    },
  });
}
