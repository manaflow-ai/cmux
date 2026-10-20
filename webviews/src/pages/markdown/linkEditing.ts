// Link behavior inside the editor, after Google Docs' link bubble: the caret entering a link shows
// a bubble under it (its URL, where it goes, Open, Copy link, Edit, Remove), never the pointer
// passing over it; Edit and the `link` page command (Cmd-K) open a Text and URL form; Option-Return
// follows the link at the caret; a URL pasted over a selection links it and a typed bare URL links
// itself. Also broken-link marks, the Cmd follow cursor and reference-aware link edits. The page
// decides where a followed link goes (main.tsx); this file reports which href the user followed.
import type { Mark, MarkType, Node as ProseNode } from "@milkdown/kit/prose/model";
import { closeHistory } from "@milkdown/kit/prose/history";
import { Plugin, PluginKey, TextSelection, type EditorState, type Transaction } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import type { UiVirtualAnchor } from "../../ui/Popover";
import { findHeading, headingTargets, parseLink, pastedURL, relativeLinkPaths, type ResolvedLink } from "./links";
import { RAW_NODE, type ReferenceInfo } from "./sourceMap";
import type { LinkBubbleState, LinkOverlays } from "./overlays";

export type LinkLabel =
  | "followHint"
  | "clickHint"
  | "broken"
  | "noHeading"
  | "checking"
  | "opensBrowser"
  | "opensInCmux"
  | "opensFile"
  | "opensMail"
  | "linkPlaceholder"
  | "footnote"
  | "bubble"
  | "open"
  | "copy"
  | "copied"
  | "edit"
  | "remove"
  | "text"
  | "textPlaceholder"
  | "url"
  | "apply"
  | "insertTitle"
  | "editTitle";

/** What the link features need from the page. */
export interface LinkHost {
  /** The cached answer for a relative path; undefined while unchecked. */
  resolved(path: string): ResolvedLink | undefined;
  /** Asks the host about these relative paths (batched; `refreshLinks` runs when they answer). */
  requestLinks(paths: Iterable<string>): void;
  /** Completion for the URL field: workspace paths relative to the file, starting with `prefix`. */
  listFiles?(prefix: string): Promise<string[]>;
  /** Puts text on the clipboard (default: the page's clipboard, see `copyText`). */
  copyText?(text: string): Promise<void>;
  linkLabel(key: LinkLabel): string;
}

const linkKey = new PluginKey<DecorationSet>("cmuxMarkdownLinks");

/** Marks links whose target is missing (`md-link-broken`) and asks the host about new ones. */
export function brokenLinkPlugin(host: LinkHost) {
  return $prose(() => {
    const decorate = (doc: ProseNode): DecorationSet => {
      host.requestLinks(relativeLinkPaths(doc));
      const decorations: Decoration[] = [];
      doc.descendants((node, pos) => {
        if (!node.isText) return true;
        const mark = node.marks.find((candidate) => candidate.type.name === "link");
        if (!mark) return false;
        if (linkState(doc, String(mark.attrs.href ?? ""), host) === "broken") {
          decorations.push(Decoration.inline(pos, pos + node.nodeSize, { class: "md-link-broken" }));
        }
        return false;
      });
      return DecorationSet.create(doc, decorations);
    };
    return new Plugin<DecorationSet>({
      key: linkKey,
      state: {
        init: (_config, state) => decorate(state.doc),
        apply: (tr, previous, _old, state) =>
          tr.docChanged || tr.getMeta(linkKey) ? decorate(state.doc) : previous.map(tr.mapping, tr.doc),
      },
      props: { decorations: (state) => linkKey.getState(state) },
    });
  });
}

/** Re-checks link decorations (the host answered a resolve batch). */
export function refreshLinks(view: EditorView): void {
  view.dispatch(view.state.tr.setMeta(linkKey, "refresh").setMeta("addToHistory", false));
}

export type LinkState = "ok" | "broken" | "checking" | "external";

/** Whether a link's target exists: anchors against this file's headings, paths through the host. */
export function linkState(doc: ProseNode, href: string, host: LinkHost): LinkState {
  const link = parseLink(href);
  if (link.kind === "anchor") return findHeading(doc, link.anchor) ? "ok" : "broken";
  if (link.kind === "external" || link.kind === "mail" || link.kind === "app") return "external";
  if (link.kind === "unsafe") return "broken";
  const resolved = host.resolved(link.path);
  if (!resolved) return "checking";
  return resolved.exists ? "ok" : "broken";
}

/** The bubble's lines for an href: where it goes, and how to follow it. */
export function linkCard(
  doc: ProseNode,
  href: string,
  host: LinkHost,
  readOnly: boolean,
): { target: string; detail: string; state: LinkState } {
  const link = parseLink(href);
  const state = linkState(doc, href, host);
  const hint = host.linkLabel(readOnly ? "clickHint" : "followHint");
  if (link.kind === "anchor") {
    const heading = findHeading(doc, link.anchor);
    return {
      target: heading ? `#${heading.slug}  ${heading.text}` : href,
      detail: heading ? hint : host.linkLabel("noHeading"),
      state,
    };
  }
  if (link.kind === "external") return { target: href, detail: `${host.linkLabel("opensBrowser")} · ${hint}`, state };
  if (link.kind === "app") return { target: href, detail: `${host.linkLabel("opensInCmux")} · ${hint}`, state };
  if (link.kind === "mail") return { target: href, detail: `${host.linkLabel("opensMail")} · ${hint}`, state };
  const resolved = host.resolved(link.path);
  const target = (resolved?.path ?? link.path) + (link.anchor ? `#${link.anchor}` : "");
  if (state === "broken") return { target, detail: host.linkLabel("broken"), state };
  if (state === "checking") return { target, detail: host.linkLabel("checking"), state };
  return { target, detail: link.kind === "file" ? `${host.linkLabel("opensFile")} · ${hint}` : hint, state };
}

/** How a link is spelled in the file when it is an autolink: a bare URL (GFM) or `<url>`. */
export type AutolinkSpelling = "literal" | "angle";

/**
 * Copies `text`: the async clipboard, else `fallback` (a hidden textarea the bubble renders) and
 * the copy command, which a page on a custom scheme still allows during a click.
 */
export async function copyText(text: string, fallback: HTMLTextAreaElement | null): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    // Not a secure context, or no permission: fall through to the textarea.
  }
  if (!fallback) throw new Error("Clipboard API unavailable");
  fallback.value = text;
  fallback.select();
  if (!document.execCommand("copy")) throw new Error("Clipboard copy failed");
}

/**
 * The Cmd follow cursor: holding Cmd over the editor turns links into pointers (`md-follow`),
 * since Cmd-click follows and a plain click places the caret (and shows the bubble).
 */
export function followCursorPlugin() {
  return $prose(
    () =>
      new Plugin({
        view(view) {
          const follow = (event: MouseEvent | KeyboardEvent) => view.dom.classList.toggle("md-follow", event.metaKey);
          view.dom.addEventListener("mousemove", follow);
          addEventListener("keydown", follow, true); // ui-allow: the follow cursor tracks the Meta key
          addEventListener("keyup", follow, true); // ui-allow: the follow cursor tracks the Meta key
          return {
            destroy: () => {
              view.dom.removeEventListener("mousemove", follow);
              removeEventListener("keydown", follow, true);
              removeEventListener("keyup", follow, true);
            },
          };
        },
      }),
  );
}

/** What the link bubble needs besides the link host. */
export interface LinkBubbleOptions {
  host: LinkHost;
  overlays: LinkOverlays;
  readOnly(): boolean;
  /** Follows an href (the page's router; the same as Cmd-click). */
  openLink(href: string): void;
}

/** Where the editor finds the bubble its plugin made (for the `link` page command). */
export interface LinkBubbleSlot {
  current: LinkBubble | null;
}

/**
 * The link bubble (Google Docs' model). The caret entering a link shows the view bubble under it at
 * once; the pointer passing over a link shows nothing. Option-Return follows the link at the caret,
 * Escape hides the bubble until the caret leaves that link. The bubble's Edit and the `link` page
 * command (Cmd-K) open the edit form.
 */
export function linkBubblePlugin(options: LinkBubbleOptions, slot: LinkBubbleSlot) {
  return $prose(
    () =>
      new Plugin({
        props: {
          handleKeyDown(view, event) {
            const bubble = slot.current;
            if (!bubble) return false;
            if (event.key === "Enter" && event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey)
              return bubble.openAtCaret();
            if (event.key === "Escape") return bubble.dismiss();
            return false;
          },
        },
        view(view) {
          const bubble = new LinkBubble(view, options);
          slot.current = bubble;
          const refresh = () => bubble.update();
          view.dom.addEventListener("focus", refresh);
          view.dom.addEventListener("blur", refresh);
          return {
            update: refresh,
            destroy: () => {
              view.dom.removeEventListener("focus", refresh);
              view.dom.removeEventListener("blur", refresh);
              bubble.destroy();
              if (slot.current === bubble) slot.current = null;
            },
          };
        },
      }),
  );
}

interface LinkRange {
  from: number;
  to: number;
  mark?: Mark;
}

/** The bubble's controller: decides when it shows and carries out its actions. */
export class LinkBubble {
  private opened = 0;
  /** The link the view bubble shows (start and href): one opening while the caret moves or types in it. */
  private shown: string | null = null;
  /** What the shown bubble was drawn from, to redraw it in place when the link's text or element changes. */
  private drawn: { to: number; anchor: Element | null } | null = null;
  /** The link Escape hid the bubble for, until the caret leaves it. */
  private dismissed: string | null = null;
  private editing = false;

  constructor(
    private readonly view: EditorView,
    private readonly options: LinkBubbleOptions,
  ) {}

  /** The link around an empty caret in a focused, editable editor. */
  private caretLink(): (LinkRange & { mark: Mark }) | null {
    const { state } = this.view;
    if (this.options.readOnly() || !state.selection.empty || !this.view.hasFocus()) return null;
    const range = linkRangeAt(state, state.selection.from);
    if (!range || range.from === range.to) return null;
    return range;
  }

  /** Shows, keeps or hides the view bubble for the caret (every editor update, focus and blur). */
  update(): void {
    if (this.editing) return;
    const range = this.caretLink();
    const key = range ? `${range.from}:${String(range.mark.attrs.href ?? "")}` : null;
    if (key !== this.dismissed) this.dismissed = null;
    if (!range || key === this.dismissed) {
      this.hide();
      return;
    }
    const same = key === this.shown;
    if (same && this.drawn?.to === range.to && this.drawn.anchor?.isConnected) return;
    this.shown = key;
    this.showView(range, same);
  }

  private anchorElement(range: LinkRange): Element | null {
    try {
      const { node } = this.view.domAtPos(range.from + 1);
      const element = node instanceof Element ? node : node.parentElement;
      return element?.closest("a[href]") ?? element ?? null;
    } catch {
      return null;
    }
  }

  /** A box over `from..to` read when the bubble is placed (it follows layout changes). */
  private rangeAnchor(range: LinkRange): UiVirtualAnchor {
    const view = this.view;
    return {
      contextElement: view.dom,
      getBoundingClientRect: () => {
        let left = 0;
        let top = 0;
        let right = 0;
        let bottom = 0;
        try {
          const start = view.coordsAtPos(range.from);
          const end = view.coordsAtPos(range.to);
          const sameLine = Math.abs(start.top - end.top) < 2;
          left = start.left;
          top = start.top;
          right = sameLine ? Math.max(end.right, start.left) : start.left;
          bottom = start.bottom;
        } catch {
          const box = view.dom.getBoundingClientRect();
          ({ left, top, right, bottom } = box);
        }
        return DOMRect.fromRect({ x: left, y: top, width: right - left, height: bottom - top });
      },
    };
  }

  private base(range: LinkRange, href: string, keepId = false): Omit<LinkBubbleState, "mode" | "anchor" | "inserting"> {
    const { host } = this.options;
    const doc = this.view.state.doc;
    const card = linkCard(doc, href, host, this.options.readOnly());
    return {
      id: keepId ? this.opened : ++this.opened,
      href,
      text: doc.textBetween(range.from, range.to, " "),
      info: card,
      label: (key) => host.linkLabel(key),
      suggest: (value) => this.suggest(value),
      open: () => {
        if (href) this.options.openLink(href);
      },
      copy: (fallback) => {
        void (host.copyText ? host.copyText(href) : copyText(href, fallback ?? null)).catch(() => {});
      },
      edit: () => this.openEdit(range),
      remove: () => this.remove(range),
      apply: (text, next) => this.apply(range, text, next),
      cancel: () => this.closeEdit(),
    };
  }

  /** Shows the view bubble; `inPlace` keeps its id (the same link changed), so it redraws without a new fade. */
  private showView(range: LinkRange & { mark: Mark }, inPlace = false): void {
    const href = String(range.mark.attrs.href ?? "");
    const element = this.anchorElement(range);
    this.drawn = { to: range.to, anchor: element };
    this.options.overlays.setBubble({
      ...this.base(range, href, inPlace),
      mode: "view",
      anchor: element ?? this.rangeAnchor(range),
      inserting: false,
    });
  }

  /** The edit form on the link at the caret or the selection (the `link` page command, Cmd-K). */
  editAtSelection(): void {
    if (this.options.readOnly()) return;
    const { state } = this.view;
    const { from, to } = state.selection;
    const around = linkRangeAt(state, from);
    const range: LinkRange =
      around && (state.selection.empty || (from >= around.from && to <= around.to))
        ? around
        : { from, to, mark: undefined };
    this.openEdit(range);
  }

  private openEdit(range: LinkRange): void {
    const href = String(range.mark?.attrs.href ?? "");
    this.editing = true;
    this.shown = null;
    this.drawn = null;
    this.options.overlays.setBubble({
      ...this.base(range, href),
      mode: "edit",
      anchor: this.rangeAnchor(range),
      inserting: !range.mark,
    });
  }

  private closeEdit(): void {
    if (!this.editing) return;
    this.editing = false;
    this.options.overlays.setBubble(null);
    this.view.focus();
    this.update();
  }

  private apply(range: LinkRange, text: string, href: string): void {
    this.editing = false;
    this.options.overlays.setBubble(null);
    applyLinkEdit(this.view, range.from, range.to, text, href.trim(), range.mark);
    this.view.focus();
    this.update();
  }

  private remove(range: LinkRange): void {
    this.editing = false;
    this.shown = null;
    const linkType = this.view.state.schema.marks.link as MarkType;
    this.view.dispatch(this.view.state.tr.removeMark(range.from, range.to, linkType).scrollIntoView());
    this.options.overlays.setBubble(null);
    this.view.focus();
  }

  /** Option-Return: follows the link at the caret. */
  openAtCaret(): boolean {
    const range = this.caretLink();
    if (!range) return false;
    const href = String(range.mark.attrs.href ?? "");
    if (href) this.options.openLink(href);
    return true;
  }

  /** Escape: hides the view bubble until the caret leaves this link. */
  dismiss(): boolean {
    if (this.editing || !this.shown) return false;
    this.dismissed = this.shown;
    this.hide();
    return true;
  }

  private hide(): void {
    if (this.editing) return;
    this.shown = null;
    this.drawn = null;
    if (this.options.overlays.getState().bubble) this.options.overlays.setBubble(null);
  }

  private async suggest(value: string): Promise<string[]> {
    if (value.startsWith("#")) {
      const wanted = value.slice(1).toLowerCase();
      return headingTargets(this.view.state.doc)
        .filter((heading) => heading.slug.includes(wanted) || heading.text.toLowerCase().includes(wanted))
        .map((heading) => `#${heading.slug}`);
    }
    const files = this.options.host.listFiles;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(value) && files) return files(value).catch(() => []);
    return [];
  }

  destroy(): void {
    this.editing = false;
    this.hide();
  }
}

/** Pasting one URL: over a selection it links the selection; alone it inserts it as a link. */
export function pasteLinkPlugin(readOnly: () => boolean) {
  return $prose(
    () =>
      new Plugin({
        props: {
          handlePaste(view, event, slice) {
            if (readOnly()) return false;
            const plain =
              event.clipboardData?.getData("text/plain") || slice.content.textBetween(0, slice.content.size, "\n");
            const url = pastedURL(plain);
            if (!url) return false;
            const { state } = view;
            const { $from } = state.selection;
            if ($from.parent.type.spec.code) return false;
            const link = state.schema.marks.link;
            if (!link) return false;
            const mark = link.create({ href: url, title: null });
            const tr = state.selection.empty
              ? state.tr.replaceSelectionWith(state.schema.text(url, [mark]), false)
              : state.tr
                  .removeMark(state.selection.from, state.selection.to, link)
                  .addMark(state.selection.from, state.selection.to, mark);
            view.dispatch(tr.scrollIntoView());
            return true;
          },
        },
      }),
  );
}

/** A URL at the end of the text before the caret (GFM's `http(s)://` and `www.` autolinks). */
const TYPED_URL = /(?:^|[\s(*_~])((?:https?:\/\/|www\.)[^\s<>]+)$/i;

/** The URL GFM links in `candidate`: trailing punctuation and unbalanced closing parens dropped. */
export function trimTypedURL(candidate: string): string {
  let url = candidate.replace(/[.,:;!?"'*_~]+$/, "");
  while (url.endsWith(")") && (url.match(/\)/g)?.length ?? 0) > (url.match(/\(/g)?.length ?? 0)) {
    url = url.slice(0, -1).replace(/[.,:;!?"'*_~]+$/, "");
  }
  return url;
}

/**
 * The transaction that links the bare URL just before `pos` (typing a space or Return after it),
 * spelled as a bare URL in the file; null when there is none, it is in code or already linked.
 */
export function autolinkBefore(state: EditorState, pos: number): Transaction | null {
  const link = state.schema.marks.link;
  const $pos = state.doc.resolve(pos);
  if (!link || $pos.parent.type.spec.code || !$pos.parent.isTextblock) return null;
  const before = $pos.parent.textBetween(Math.max(0, $pos.parentOffset - 500), $pos.parentOffset, undefined, "￼");
  const match = TYPED_URL.exec(before);
  if (!match) return null;
  const url = trimTypedURL(match[1]);
  if (!/^(https?:\/\/[^/\s]+\.[^\s]|https?:\/\/localhost|www\.[^.\s]+\.[^\s])/i.test(url)) return null;
  const start = pos - match[1].length;
  const end = start + url.length;
  let blocked = false;
  state.doc.nodesBetween(start, end, (node) => {
    if (node.isText && node.marks.some((mark) => mark.type === link || mark.type.spec.code)) blocked = true;
  });
  if (blocked) return null;
  const href = /^www\./i.test(url) ? `http://${url}` : url;
  return state.tr.addMark(start, end, link.create({ href, title: null, autolink: "literal" }));
}

/**
 * A typed bare URL links itself when a space or Return follows it (Google Docs, GFM). The link is
 * its own undo step: Cmd-Z right after takes the link (and the space) back, leaving the URL text.
 */
export function autolinkPlugin(readOnly: () => boolean) {
  return $prose(
    () =>
      new Plugin({
        props: {
          handleTextInput(view, from, to, text) {
            if (readOnly() || !/^\s$/.test(text) || from !== to) return false;
            const tr = autolinkBefore(view.state, from);
            if (!tr) return false;
            view.dispatch(closeHistory(tr.insertText(text, from, to)));
            return true;
          },
          handleKeyDown(view, event) {
            if (readOnly() || event.key !== "Enter" || event.altKey || event.metaKey || event.ctrlKey) return false;
            const { selection } = view.state;
            if (!selection.empty) return false;
            const tr = autolinkBefore(view.state, selection.from);
            if (tr) view.dispatch(closeHistory(tr));
            return false;
          },
        },
      }),
  );
}

/** The range and mark of the link around `pos` (the whole link, across text nodes). */
export function linkRangeAt(state: EditorState, pos: number): { from: number; to: number; mark: Mark } | null {
  const linkType = state.schema.marks.link;
  const $pos = state.doc.resolve(pos);
  const parent = $pos.parent;
  const start = $pos.start();
  let found: { from: number; to: number; mark: Mark } | null = null;
  let offset = start;
  const children: Array<{ from: number; to: number; mark?: Mark }> = [];
  parent.forEach((child) => {
    children.push({ from: offset, to: offset + child.nodeSize, mark: linkType.isInSet(child.marks) ?? undefined });
    offset += child.nodeSize;
  });
  for (let index = 0; index < children.length; index++) {
    const child = children[index];
    if (!child.mark || pos < child.from || pos > child.to) continue;
    let from = child.from;
    let to = child.to;
    for (let back = index - 1; back >= 0 && children[back].mark?.eq(child.mark); back--) from = children[back].from;
    for (let next = index + 1; next < children.length && children[next].mark?.eq(child.mark); next++)
      to = children[next].to;
    found = { from, to, mark: child.mark };
    if (pos > child.from && pos < child.to) break;
  }
  return found;
}

/**
 * Applies the edit form: `text` replaces the link's text when it changed (an empty text uses the
 * URL), `href` sets the link (empty removes it). A reference link keeps its reference: its
 * definition and every link using it get the new URL. With an empty range the text is inserted as
 * a new link. One transaction, so one undo step.
 */
export function applyLinkEdit(
  view: EditorView,
  from: number,
  to: number,
  text: string,
  href: string,
  existing?: Mark,
): void {
  const { state } = view;
  const linkType = state.schema.marks.link as MarkType;
  if (!href && !existing) return;
  const current = state.doc.textBetween(from, to, " ");
  const wanted = text || current || href;
  let tr = state.tr;
  let end = to;
  if (wanted !== current) {
    const marks = (from < to ? state.doc.resolve(from + 1).marks() : state.doc.resolve(from).marks()).filter(
      (mark) => mark.type !== linkType,
    );
    const kept = existing ? [...marks, existing] : marks;
    tr = tr.replaceWith(from, to, state.schema.text(wanted, kept));
    end = from + wanted.length;
  }
  const reference = existing?.attrs.reference as ReferenceInfo | null | undefined;
  if (!href) {
    tr = tr.removeMark(from, end, linkType);
  } else if (reference && existing && href !== existing.attrs.href) {
    if (!updateReference(tr, reference, href))
      tr = tr.removeMark(from, end, linkType).addMark(from, end, linkType.create({ href, title: null }));
  } else if (existing && href === existing.attrs.href) {
    if (!tr.docChanged) return;
  } else {
    tr = tr
      .removeMark(from, end, linkType)
      .addMark(from, end, linkType.create({ href, title: existing?.attrs.title ?? null }));
  }
  view.dispatch(tr.setSelection(TextSelection.create(tr.doc, end)).scrollIntoView());
}

/** Sets the link on `from..to` to `href` (empty removes it), keeping the text. */
export function applyLink(view: EditorView, from: number, to: number, href: string, existing?: Mark): void {
  applyLinkEdit(view, from, to, "", href, existing);
}

const normalizeLabel = (label: string) => label.trim().toLowerCase().replace(/\s+/g, " ");

/**
 * Points reference `reference` at `href` on `tr`: the definition block's line and every link mark
 * using that reference. False (and `tr` unchanged) when the definition is not in the document.
 */
export function updateReference(tr: Transaction, reference: ReferenceInfo, href: string): boolean {
  const linkType = tr.doc.type.schema.marks.link;
  const id = normalizeLabel(reference.identifier);
  const destination = /[\s<>()]/.test(href) ? `<${href.replace(/>/g, "%3E")}>` : href;
  const edits: Array<{ from: number; to: number; text: string }> = [];
  tr.doc.descendants((node, pos) => {
    if (node.type.name !== RAW_NODE || node.attrs.kind !== "definition") return node.isBlock;
    const text = node.textContent;
    const next = text.replace(
      /^(\s*\[([^\]]+)\]:[ \t]*)(<[^>]*>|\S+)/gm,
      (line, lead: string, label: string, _url: string) =>
        normalizeLabel(label) === id ? `${lead}${destination}` : line,
    );
    if (next !== text) edits.push({ from: pos + 1, to: pos + node.nodeSize - 1, text: next });
    return false;
  });
  if (edits.length === 0) return false;
  for (const edit of edits.reverse()) tr.replaceWith(edit.from, edit.to, tr.doc.type.schema.text(edit.text));
  const marks: Array<{ from: number; to: number; mark: Mark }> = [];
  tr.doc.descendants((node, pos) => {
    if (!node.isText) return true;
    const mark = node.marks.find((candidate) => candidate.type === linkType);
    const ref = mark?.attrs.reference as ReferenceInfo | null | undefined;
    if (mark && ref && normalizeLabel(ref.identifier) === id) marks.push({ from: pos, to: pos + node.nodeSize, mark });
    return false;
  });
  for (const { from, to, mark } of marks)
    tr.removeMark(from, to, linkType).addMark(from, to, linkType.create({ ...mark.attrs, href }));
  return true;
}

/** Selects nothing: puts the caret at `pos` (used after following a footnote). */
export function caretAt(view: EditorView, pos: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
}
