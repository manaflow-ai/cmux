// Link behavior inside the editor: broken-link marks, the hover card and follow cursor, pasting
// URLs, the link popover (the `link` page command, Cmd-K) and reference-aware link edits. The page
// decides where a followed link goes (main.tsx); this file reports which href the user followed.
import type { Mark, MarkType, Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey, TextSelection, type EditorState } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import { findHeading, headingTargets, parseLink, pastedURL, relativeLinkPaths, type ResolvedLink } from "./links";
import { RAW_NODE, type ReferenceInfo } from "./sourceMap";

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

/** The window's size (jsdom and other hosts without a window size get the document's). */
function viewport(): { width: number; height: number } {
  const root = document.documentElement;
  return { width: globalThis.innerWidth ?? root.clientWidth, height: globalThis.innerHeight ?? root.clientHeight };
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
export function hoverCardPlugin(host: LinkHost, readOnly: () => boolean) {
  return $prose(
    () =>
      new Plugin({
        view(view) {
          const card = document.createElement("div");
          card.className = "md-link-card";
          card.setAttribute("role", "tooltip");
          card.hidden = true;
          const target = document.createElement("div");
          target.className = "md-link-card-target";
          const detail = document.createElement("div");
          detail.className = "md-link-card-detail";
          card.append(target, detail);
          document.body.append(card);
          let timer: ReturnType<typeof setTimeout> | null = null;
          let current: Element | null = null;
          const hide = () => {
            if (timer) clearTimeout(timer);
            timer = null;
            current = null;
            card.hidden = true;
          };
          const show = (element: Element) => {
            const href = element.getAttribute("href") ?? "";
            const info = element.matches("sup[data-type]")
              ? {
                  target: `[^${element.getAttribute("data-label") ?? ""}]`,
                  detail: host.linkLabel("footnote"),
                  state: "ok" as LinkState,
                }
              : linkCard(view.state.doc, href, host, readOnly());
            target.textContent = info.target;
            detail.textContent = info.detail;
            card.dataset.state = info.state;
            card.hidden = false;
            const rect = element.getBoundingClientRect();
            const width = Math.min(card.offsetWidth, viewport().width - 16);
            card.style.left = `${Math.max(8, Math.min(rect.left, viewport().width - width - 8))}px`;
            card.style.top = `${rect.bottom + 6 + card.offsetHeight > viewport().height ? rect.top - card.offsetHeight - 6 : rect.bottom + 6}px`;
          };
          const follow = (on: boolean) => view.dom.classList.toggle("md-follow", on);
          const over = (event: MouseEvent) => {
            follow(event.metaKey);
            const element = (event.target as Element | null)?.closest?.('a[href], sup[data-type="footnote_reference"]');
            if (element === current) return;
            hide();
            if (!element || !view.dom.contains(element)) return;
            current = element;
            timer = setTimeout(() => show(element), 250);
          };
          // Cmd shows the follow cursor; any other key (typing, the link popover) hides the card.
          const modifier = (event: KeyboardEvent) => {
            follow(event.metaKey);
            if (event.key !== "Meta") hide();
          };
          view.dom.addEventListener("mousemove", over);
          view.dom.addEventListener("mouseleave", hide);
          addEventListener("keydown", modifier, true);
          addEventListener("keyup", modifier, true);
          addEventListener("scroll", hide, true);
          return {
            update: () => {
              if (current && !view.dom.contains(current)) hide();
            },
            destroy: () => {
              hide();
              card.remove();
              view.dom.removeEventListener("mousemove", over);
              view.dom.removeEventListener("mouseleave", hide);
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
 * completion of `#headings` and workspace paths. Enter applies, Escape cancels.
 */
export class LinkPopover {
  private element: HTMLElement | null = null;

  constructor(
    private readonly view: EditorView,
    private readonly host: LinkHost,
  ) {}

  get open(): boolean {
    return this.element !== null;
  }

  show(): void {
    this.close();
    document.querySelectorAll<HTMLElement>(".md-link-card").forEach((card) => (card.hidden = true));
    const { state } = this.view;
    const { from, to } = state.selection;
    const around = linkRangeAt(state, from);
    const range =
      around && (state.selection.empty || (from >= around.from && to <= around.to))
        ? around
        : { from, to, mark: undefined };
    const popover = document.createElement("div");
    popover.className = "md-link-popover";
    const input = document.createElement("input");
    input.type = "text";
    input.className = "md-link-input";
    input.spellcheck = false;
    input.placeholder = this.host.linkLabel("linkPlaceholder");
    input.setAttribute("aria-label", this.host.linkLabel("linkPlaceholder"));
    input.value = String(range.mark?.attrs.href ?? "");
    const list = document.createElement("ul");
    list.className = "md-link-suggestions";
    list.setAttribute("role", "listbox");
    popover.append(input, list);
    document.body.append(popover);
    this.element = popover;
    const coords = this.view.coordsAtPos(range.from);
    popover.style.left = `${Math.max(8, Math.min(coords.left, viewport().width - popover.offsetWidth - 8))}px`;
    popover.style.top = `${coords.bottom + 6}px`;

    let items: string[] = [];
    let active = -1;
    let query = 0;
    const render = () => {
      list.replaceChildren(
        ...items.map((item, index) => {
          const li = document.createElement("li");
          li.textContent = item;
          li.setAttribute("role", "option");
          li.setAttribute("aria-selected", String(index === active));
          li.addEventListener("mousedown", (event) => {
            event.preventDefault();
            input.value = item;
            apply();
          });
          return li;
        }),
      );
      list.hidden = items.length === 0;
    };
    const suggest = async () => {
      const value = input.value;
      const ticket = ++query;
      let next: string[];
      if (value.startsWith("#")) {
        const wanted = value.slice(1).toLowerCase();
        next = headingTargets(this.view.state.doc)
          .filter((heading) => heading.slug.includes(wanted) || heading.text.toLowerCase().includes(wanted))
          .map((heading) => `#${heading.slug}`);
      } else if (!/^[a-z][a-z0-9+.-]*:/i.test(value) && this.host.listFiles) {
        next = await this.host.listFiles(value).catch(() => []);
      } else next = [];
      if (ticket !== query || !this.element) return;
      items = next.slice(0, 12);
      active = -1;
      render();
    };
    const apply = () => {
      const href = input.value.trim();
      this.close();
      applyLink(this.view, range.from, range.to, href, range.mark);
      this.view.focus();
    };
    input.addEventListener("input", () => void suggest());
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        this.close();
        this.view.focus();
      } else if (event.key === "Enter") {
        event.preventDefault();
        if (active >= 0 && items[active]) input.value = items[active];
        apply();
      } else if ((event.key === "ArrowDown" || event.key === "ArrowUp") && items.length) {
        event.preventDefault();
        active = (active + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
        render();
      } else if (event.key === "Tab" && items.length) {
        event.preventDefault();
        input.value = items[active >= 0 ? active : 0];
        void suggest();
      }
    });
    input.addEventListener("blur", () => setTimeout(() => this.close(), 0));
    input.focus();
    input.select();
    render();
    void suggest();
  }

  close(): void {
    this.element?.remove();
    this.element = null;
  }
}

/** Selects nothing: puts the caret at `pos` (used after following a footnote). */
export function caretAt(view: EditorView, pos: number): void {
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
}
