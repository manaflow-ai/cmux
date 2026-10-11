// Link behavior inside the editor: broken-link marks, the hover card and follow cursor, pasting
// URLs, the link popover (the `link` page command, Cmd-K) and reference-aware link edits. The page
// decides where a followed link goes (main.tsx); this file reports which href the user followed.
import type { Mark, MarkType, Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey, TextSelection, type EditorState } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import { findHeading, headingTargets, parseLink, pastedURL, relativeLinkPaths, type ResolvedLink } from "./links";
import { RAW_NODE, type ReferenceInfo } from "./sourceMap";
import type { LinkCardInfo, LinkOverlays } from "./overlays";

export type LinkLabel =
  | "followHint"
  | "clickHint"
  | "broken"
  | "noHeading"
  | "checking"
  | "opensBrowser"
  | "opensFile"
  | "opensMail"
  | "linkPlaceholder"
  | "footnote";

/** What the link features need from the page. */
export interface LinkHost {
  /** The cached answer for a relative path; undefined while unchecked. */
  resolved(path: string): ResolvedLink | undefined;
  /** Asks the host about these relative paths (batched; `refreshLinks` runs when they answer). */
  requestLinks(paths: Iterable<string>): void;
  /** Completion for the popover: workspace paths relative to the file, starting with `prefix`. */
  listFiles?(prefix: string): Promise<string[]>;
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
  if (link.kind === "external" || link.kind === "mail") return "external";
  if (link.kind === "unsafe") return "broken";
  const resolved = host.resolved(link.path);
  if (!resolved) return "checking";
  return resolved.exists ? "ok" : "broken";
}

/** The hover card's lines for an href: where it goes, and how to follow it. */
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
  if (link.kind === "mail") return { target: href, detail: `${host.linkLabel("opensMail")} · ${hint}`, state };
  const resolved = host.resolved(link.path);
  const target = (resolved?.path ?? link.path) + (link.anchor ? `#${link.anchor}` : "");
  if (state === "broken") return { target, detail: host.linkLabel("broken"), state };
  if (state === "checking") return { target, detail: host.linkLabel("checking"), state };
  return { target, detail: link.kind === "file" ? `${host.linkLabel("opensFile")} · ${hint}` : hint, state };
}

/**
 * The hover card and the follow cursor. Hovering a link shows its card; holding Cmd over the
 * editor turns links into pointers (`md-follow`), since Cmd-click follows and a plain click edits.
 */
export function hoverCardPlugin(host: LinkHost, readOnly: () => boolean, overlays: LinkOverlays) {
  return $prose(
    () =>
      new Plugin({
        view(view) {
          let timer: ReturnType<typeof setTimeout> | null = null;
          let current: Element | null = null;
          // What showed the card: the pointer over a link, or the caret inside one.
          let by: "pointer" | "caret" | null = null;
          const render = (anchor: Element | null, info: LinkCardInfo | null) =>
            overlays.setCard(anchor && info ? { anchor, info } : null);
          const hide = () => {
            if (timer) clearTimeout(timer);
            timer = null;
            current = null;
            by = null;
            render(null, null);
          };
          const show = (element: Element) => {
            const href = element.getAttribute("href") ?? "";
            const info: LinkCardInfo = element.matches("sup[data-type]")
              ? {
                  target: `[^${element.getAttribute("data-label") ?? ""}]`,
                  detail: host.linkLabel("footnote"),
                  state: "ok",
                }
              : linkCard(view.state.doc, href, host, readOnly());
            render(element, info);
          };
          const schedule = (element: Element, source: "pointer" | "caret") => {
            if (element === current) return;
            hide();
            current = element;
            by = source;
            timer = setTimeout(() => show(element), 250);
          };
          const follow = (on: boolean) => view.dom.classList.toggle("md-follow", on);
          const over = (event: MouseEvent) => {
            follow(event.metaKey);
            const element = (event.target as Element | null)?.closest?.('a[href], sup[data-type="footnote_reference"]');
            if (element === current) return;
            if (!element || !view.dom.contains(element)) {
              if (by === "pointer") hide();
              return;
            }
            schedule(element, "pointer");
          };
          // The link around the caret, so keyboard users get the same card.
          const caretLink = (): Element | null => {
            const { selection } = view.state;
            if (!selection.empty || !view.hasFocus()) return null;
            const range = linkRangeAt(view.state, selection.from);
            if (!range || range.from === range.to) return null;
            const { node } = view.domAtPos(range.from + 1);
            const element = node instanceof Element ? node : node.parentElement;
            return element?.closest("a[href]") ?? null;
          };
          // ui-allow: the editor's follow cursor tracks the Meta key; any other key hides the card.
          const modifier = (event: KeyboardEvent) => {
            follow(event.metaKey);
            if (event.key !== "Meta" && by === "pointer") hide();
          };
          view.dom.addEventListener("mousemove", over);
          view.dom.addEventListener("mouseleave", () => by === "pointer" && hide());
          addEventListener("keydown", modifier, true); // ui-allow: follow cursor (see above)
          addEventListener("keyup", modifier, true); // ui-allow: follow cursor (see above)
          addEventListener("scroll", hide, true);
          return {
            update: () => {
              if (current && !view.dom.contains(current)) hide();
              const link = caretLink();
              if (link) schedule(link, "caret");
              else if (by === "caret") hide();
            },
            destroy: () => {
              hide();
              view.dom.removeEventListener("mousemove", over);
              removeEventListener("keydown", modifier, true);
              removeEventListener("keyup", modifier, true);
              removeEventListener("scroll", hide, true);
            },
          };
        },
      }),
  );
}

/** Pasting one URL: over a selection it links the selection; alone it inserts it as a link. */
export function pasteLinkPlugin(readOnly: () => boolean) {
  return $prose(
    () =>
      new Plugin({
        props: {
          handlePaste(view, event) {
            if (readOnly()) return false;
            const url = pastedURL(event.clipboardData?.getData("text/plain") ?? "");
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
 * Sets the link on `from..to` to `href` (empty removes it). A reference link keeps its reference:
 * its definition and every link using it get the new URL. With an empty range the href is
 * inserted as linked text.
 */
export function applyLink(view: EditorView, from: number, to: number, href: string, existing?: Mark): void {
  const { state } = view;
  const linkType = state.schema.marks.link as MarkType;
  let tr = state.tr;
  const reference = existing?.attrs.reference as ReferenceInfo | null | undefined;
  if (!href) {
    tr = tr.removeMark(from, to, linkType);
  } else if (reference && existing && href !== existing.attrs.href) {
    tr =
      updateReference(state, reference, href) ??
      tr.removeMark(from, to, linkType).addMark(from, to, linkType.create({ href, title: null }));
  } else if (existing && href === existing.attrs.href) {
    return;
  } else if (from === to) {
    tr = tr.insert(from, state.schema.text(href, [linkType.create({ href, title: null })]));
  } else {
    tr = tr.removeMark(from, to, linkType).addMark(from, to, linkType.create({ href, title: null }));
  }
  view.dispatch(tr.scrollIntoView());
}

const normalizeLabel = (label: string) => label.trim().toLowerCase().replace(/\s+/g, " ");

/**
 * The transaction that points reference `reference` at `href`: the definition block's line and
 * every link mark using that reference. Null when the definition is not in the document.
 */
export function updateReference(state: EditorState, reference: ReferenceInfo, href: string) {
  const linkType = state.schema.marks.link;
  const id = normalizeLabel(reference.identifier);
  let tr = state.tr;
  let updated = false;
  const destination = /[\s<>()]/.test(href) ? `<${href.replace(/>/g, "%3E")}>` : href;
  state.doc.descendants((node, pos) => {
    if (node.type.name !== RAW_NODE || node.attrs.kind !== "definition") return node.isBlock;
    const text = node.textContent;
    const next = text.replace(
      /^(\s*\[([^\]]+)\]:[ \t]*)(<[^>]*>|\S+)/gm,
      (line, lead: string, label: string, _url: string) =>
        normalizeLabel(label) === id ? `${lead}${destination}` : line,
    );
    if (next !== text) {
      tr = tr.replaceWith(tr.mapping.map(pos + 1), tr.mapping.map(pos + node.nodeSize - 1), state.schema.text(next));
      updated = true;
    }
    return false;
  });
  if (!updated) return null;
  tr.doc.descendants((node, pos) => {
    if (!node.isText) return true;
    const mark = node.marks.find((candidate) => candidate.type === linkType);
    const ref = mark?.attrs.reference as ReferenceInfo | null | undefined;
    if (mark && ref && normalizeLabel(ref.identifier) === id) {
      tr = tr
        .removeMark(pos, pos + node.nodeSize, linkType)
        .addMark(pos, pos + node.nodeSize, linkType.create({ ...mark.attrs, href }));
    }
    return false;
  });
  return tr;
}

/**
 * The link popover (the `link` page command, Cmd-K): a URL field over the selection with
 * completion of `#headings` and workspace paths (ui Popover + Combobox, linkOverlays.tsx). Enter
 * applies, Escape cancels, focus leaving the field closes it; focus returns to the editor.
 */
export class LinkPopover {
  private opened = 0;

  constructor(
    private readonly view: EditorView,
    private readonly host: LinkHost,
    private readonly overlays: LinkOverlays,
  ) {}

  get open(): boolean {
    return this.overlays.getState().popover !== null;
  }

  show(): void {
    this.close();
    const { state } = this.view;
    const { from, to } = state.selection;
    const around = linkRangeAt(state, from);
    const range =
      around && (state.selection.empty || (from >= around.from && to <= around.to))
        ? around
        : { from, to, mark: undefined };
    const coords = this.view.coordsAtPos(range.from);
    let done = false;
    const finish = (href: string | null) => {
      if (done) return;
      done = true;
      this.close();
      if (href !== null) applyLink(this.view, range.from, range.to, href, range.mark);
      this.view.focus();
    };
    this.overlays.setCard(null);
    this.overlays.setPopover({
      id: ++this.opened,
      anchor: { left: coords.left, top: coords.top, right: coords.left, bottom: coords.bottom },
      initial: String(range.mark?.attrs.href ?? ""),
      label: this.host.linkLabel("linkPlaceholder"),
      placeholder: this.host.linkLabel("linkPlaceholder"),
      suggest: (value) => this.suggest(value),
      onApply: (href) => finish(href),
      onCancel: () => finish(null),
    });
  }

  private async suggest(value: string): Promise<string[]> {
    if (value.startsWith("#")) {
      const wanted = value.slice(1).toLowerCase();
      return headingTargets(this.view.state.doc)
        .filter((heading) => heading.slug.includes(wanted) || heading.text.toLowerCase().includes(wanted))
        .map((heading) => `#${heading.slug}`);
    }
    if (!/^[a-z][a-z0-9+.-]*:/i.test(value) && this.host.listFiles) return this.host.listFiles(value).catch(() => []);
    return [];
  }

  close(): void {
    this.overlays.setPopover(null);
  }
}

/** Selects nothing: puts the caret at `pos` (used after following a footnote). */
export function caretAt(view: EditorView, pos: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
}
