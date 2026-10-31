// The markdown editor core: Milkdown (ProseMirror with remark) configured for files, without UI
// chrome. It loads a file through the source map (sourceMap.ts) and serializes with it, so a block
// the user did not edit is written back byte for byte. The page (MarkdownPage.tsx) owns saving.
import {
  Editor,
  editorViewCtx,
  editorViewOptionsCtx,
  remarkCtx,
  remarkStringifyOptionsCtx,
  rootCtx,
  schemaCtx,
  serializerCtx,
} from "@milkdown/kit/core";
import { clipboard } from "@milkdown/kit/plugin/clipboard";
import { history } from "@milkdown/kit/plugin/history";
import { commonmark, imageSchema, linkSchema } from "@milkdown/kit/preset/commonmark";
import { gfm } from "@milkdown/kit/preset/gfm";
import type { Mark, Node as ProseNode, Schema } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey, TextSelection, type EditorState, type Transaction } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet, type EditorView, type NodeViewConstructor } from "@milkdown/kit/prose/view";
import { ParserState, type SerializerState } from "@milkdown/kit/transformer";
import { $nodeSchema, $prose } from "@milkdown/kit/utils";
import "../../markdown-task-checkbox.css";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { TaskCheckbox } from "../../ui/TaskCheckbox";
import {
  autolinkPlugin,
  brokenLinkPlugin,
  caretAt,
  followCursorPlugin,
  linkBubblePlugin,
  pasteLinkPlugin,
  refreshLinks,
  type AutolinkSpelling,
  type LinkBubbleSlot,
  type LinkHost,
} from "./linkEditing";
import { findHeading } from "./links";
import { githubReferences } from "../../githubReferences";
import { LinkOverlays } from "./overlays";
import {
  RAW_NODE,
  parseSourceMap,
  rawNode,
  serializeWithSourceMap,
  sourceMapNodes,
  type MdastRoot,
  type RawKind,
  type RemarkLike,
  type SourceMap,
} from "./sourceMap";
import { quoteLines } from "./selectionQuote";
import {
  commentDecorations,
  commentMarkersKey,
  commentMarkersPlugin,
  topIndexForLine,
  type ViewerComment,
} from "./comments";
import { NearCodeBlocks } from "./nearCode";
import { imageSize, obsidianSyntaxPlugin } from "./obsidian";
import { paddingSelectPlugin } from "./paddingSelect";
import { isPointerSelecting, pointerChanged, pointerSelectPlugin } from "./pointerSelect";
import {
  ResizableTableView,
  tableClipboard,
  tableDragOutPlugin,
  tableTextSelectPlugin,
  tableKeyDown,
  tableViewAt,
  type TableWidths,
} from "./tables";

/** What the editor needs from its page: links, images, code colors, diagrams and labels. */
export interface MarkdownEditorHost {
  /** Opens a link the user activated (Cmd-click, or a click when read only). */
  openLink(href: string): void;
  /** The URL an image source loads from (relative sources go through the host). */
  imageURL(src: string): string;
  /** Approves every guarded web image in the current document; called only by its visible button. */
  loadRemoteImages?(): Promise<void>;
  /** Refreshes blocked image views when the current document receives or loses approval. */
  observeRemoteImages?(refresh: () => void): () => void;
  /** Code token decorations for a code block; `null` while its grammar loads (then `refresh`). */
  highlight?(code: string, language: string, refresh: () => void): CodeToken[] | null;
  /** Renders a diagram block (mermaid, vega-lite, vega) into `target`. */
  renderDiagram?(language: string, source: string, target: HTMLElement): void;
  /** A label for a raw block kind, a diagram error and similar page strings. */
  label(key: EditorLabel): string;
  /** Sanitized HTML for an HTML block's preview. */
  htmlPreview?(html: string): DocumentFragment | null;
  /** The workspace's GitHub `owner/repo`, used for bare issue references. */
  githubRepository?: string;
  /** Link checks, the link bubble's strings, path completion and copying. */
  links?: LinkHost;
  /**
   * Column widths the user dragged, kept per file (a view setting, never written to the file: the
   * host keeps them in the file's extended attribute, MARKDOWN-TABLE-WIDTHS-DESIGN.md).
   */
  tableWidths?: TableWidths;
  /** Delete on a comment card: the host forgets comment `id` and sends the list again. */
  deleteComment?(id: string): void;
}

export type EditorLabel =
  | "frontmatter"
  | "html"
  | "definition"
  | "source"
  | "plainText"
  | "document"
  | "remoteImageBlocked"
  | "remoteImageLoad"
  | "comment"
  | "deleteComment";

/** One colored token of a code block, by offset into its text. */
export interface CodeToken {
  from: number;
  to: number;
  style: string;
}

export interface MarkdownEditorOptions {
  root: HTMLElement;
  host: MarkdownEditorHost;
  readOnly?: boolean;
  /** Called for every document change the user made (not loads or editor normalization). */
  onUserEdit?(): void;
  /** Where the link bubble's state goes (the page renders it: LinkOverlayHost). */
  overlays?: LinkOverlays;
}

/** The languages a diagram node view renders. */
export const DIAGRAM_LANGUAGES = new Set(["mermaid", "vega-lite", "vegalite", "vega"]);

const LOAD_META = "cmuxMarkdownLoad";

/** The raw block: text the editor keeps verbatim (front matter, definitions, HTML blocks). */
const rawSchema = $nodeSchema(RAW_NODE, () => ({
  content: "text*",
  group: "block",
  marks: "",
  code: true,
  defining: true,
  attrs: { kind: { default: "source" } },
  parseDOM: [
    {
      tag: "pre[data-cmux-raw]",
      preserveWhitespace: "full" as const,
      getAttrs: (dom: HTMLElement) => ({ kind: dom.dataset.cmuxRaw ?? "source" }),
    },
  ],
  toDOM: (node: ProseNode) => ["pre", { "data-cmux-raw": node.attrs.kind }, ["code", 0]],
  parseMarkdown: {
    match: (node: { type: string }) => node.type === "cmuxRaw",
    runner: () => {},
  },
  toMarkdown: {
    match: (node: ProseNode) => node.type.name === RAW_NODE,
    runner: (state: SerializerState, node: ProseNode) => {
      const text = node.textContent;
      state.addNode("html", undefined, node.attrs.kind === "frontmatter" ? `---\n${text}\n---` : text);
    },
  },
}));

type ReferenceData = { data?: { cmuxReference?: unknown; cmuxAutolink?: AutolinkSpelling } };

/** The mdast node a bare-URL autolink is written as (`literalAutolinkHandler` writes it verbatim). */
const LITERAL_AUTOLINK = "cmuxLiteralAutolink";

/**
 * Text as remark writes it, but an Obsidian `[[wikilink]]` (or `![[embed]]`) stays as typed:
 * remark escapes every `[` it writes, which turned `[[note]]` into `\[\[note]]` on an edit.
 */
function textHandler(
  node: { value?: unknown },
  _parent: unknown,
  state: { safe(value: string, info: unknown): string },
  info: unknown,
): string {
  return state.safe(String(node.value ?? ""), info).replace(/\\\[\\\[([^\]\n]*?)\]\]/g, "[[$1]]");
}

/** Writes a bare-URL autolink as its text: the default `link` handler would write `<url>`. */
function literalAutolinkHandler(node: { value?: unknown }): string {
  return String(node.value ?? "");
}

/**
 * Links keep their spelling through edits: a reference (`[text][ref]`) is written back as a
 * reference, a bare URL (GFM autolink) as a bare URL, `<url>` as `<url>`, the rest inline.
 */
const referenceLinkSchema = linkSchema.extendSchema((previous) => (ctx) => {
  const base = previous(ctx);
  return {
    ...base,
    attrs: { ...base.attrs, reference: { default: null }, autolink: { default: null } },
    // The reference and spelling are markdown-only; the anchor gets the base attributes.
    toDOM: (mark: Mark) => base.toDOM!(mark.type.create({ href: mark.attrs.href, title: mark.attrs.title }), true),
    parseMarkdown: {
      match: base.parseMarkdown.match,
      runner: (state, node, markType) => {
        state.openMark(markType, {
          href: node.url as string,
          title: (node.title as string | null) ?? null,
          reference: (node as ReferenceData).data?.cmuxReference ?? null,
          autolink: (node as ReferenceData).data?.cmuxAutolink ?? null,
        });
        state.next(node.children);
        state.closeMark(markType);
      },
    },
    toMarkdown: {
      match: base.toMarkdown.match,
      runner: (state, mark, node) => {
        const reference = mark.attrs.reference as Record<string, string> | null;
        const href = String(mark.attrs.href ?? "");
        const text = node.textContent;
        // A bare URL stays bare while its text is still the URL (GFM adds `http://` to `www.`).
        if (mark.attrs.autolink === "literal" && !mark.attrs.title && (text === href || `http://${text}` === href)) {
          state.withMark(mark, LITERAL_AUTOLINK, undefined, { value: text });
          return;
        }
        if (!reference) return base.toMarkdown.runner(state, mark, node);
        // `[text]` and `[text][]` use the text as the label: once the text changes, write the
        // full form `[text][label]` so the link keeps its definition.
        const same = (a: string, b: string) =>
          a.trim().toLowerCase().replace(/\s+/g, " ") === b.trim().toLowerCase().replace(/\s+/g, " ");
        const referenceType =
          reference.referenceType !== "full" && !same(node.textContent, reference.label)
            ? "full"
            : reference.referenceType;
        state.withMark(mark, "linkReference", undefined, { ...reference, referenceType });
      },
    },
  };
});

/** Images keep a reference (`![alt][ref]`) the same way. */
const referenceImageSchema = imageSchema.extendSchema((previous) => (ctx) => {
  const base = previous(ctx);
  return {
    ...base,
    attrs: { ...base.attrs, reference: { default: null } },
    parseMarkdown: {
      match: base.parseMarkdown.match,
      runner: (state, node, type) => {
        state.addNode(type, {
          src: node.url as string,
          alt: node.alt as string,
          title: node.title as string,
          reference: (node as ReferenceData).data?.cmuxReference ?? null,
        });
      },
    },
    toMarkdown: {
      match: base.toMarkdown.match,
      runner: (state, node) => {
        const reference = node.attrs.reference as Record<string, string> | null;
        if (reference) state.addNode("imageReference", undefined, undefined, { ...reference, alt: node.attrs.alt });
        else base.toMarkdown.runner(state, node);
      },
    },
  };
});

export class MarkdownEditor {
  private editor: Editor | null = null;
  private view: EditorView | null = null;
  private schema: Schema | null = null;
  private remark: RemarkLike | null = null;
  private serializeDoc: ((doc: ProseNode) => string) | null = null;
  private baseline: SourceMap = { text: "", blocks: [] };
  /** The file's viewer comments, drawn again after each load. */
  private comments: ViewerComment[] = [];
  private readOnly: boolean;
  private eol = "\n";

  /** The link overlays' state; the page renders it with LinkOverlayHost. */
  readonly overlays: LinkOverlays;

  constructor(private readonly options: MarkdownEditorOptions) {
    this.readOnly = options.readOnly ?? false;
    this.overlays = options.overlays ?? new LinkOverlays();
  }

  async create(): Promise<void> {
    const { root, host } = this.options;
    const editor = Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, root);
        // Blocks the user edits are written in the most common markdown spelling.
        ctx.update(remarkStringifyOptionsCtx, (options) => ({
          ...options,
          bullet: "-" as const,
          emphasis: "_" as const,
          strong: "*" as const,
          fence: "`" as const,
          rule: "-" as const,
          listItemIndent: "one" as const,
          incrementListMarker: true,
          handlers: { ...options.handlers, [LITERAL_AUTOLINK]: literalAutolinkHandler, text: textHandler },
        }));
        ctx.update(editorViewOptionsCtx, (options) => ({
          ...options,
          editable: () => !this.readOnly,
          // The editable region's accessible name and kind (a multi-line text field).
          attributes: {
            class: "md-prose",
            spellcheck: "true",
            "aria-label": host.label("document"),
            "aria-multiline": "true",
            role: "textbox",
          },
          nodeViews: nodeViews(host),
          // Cmd-click on a link or footnote follows it (the DOM click below); here it must not
          // also make ProseMirror select the clicked node, as a modifier click does.
          handleClick: (_view, _pos, event) =>
            event.metaKey &&
            !!(event.target as Element | null)?.closest?.(
              'a[href], sup[data-type="footnote_reference"], .md-wikilink[data-href]',
            ),
          // Obsidian's table keys (tables.ts): before every plugin's keymap.
          handleKeyDown: (view, event) => tableKeyDown(view, event, this.schema),
          handleDOMEvents: {
            click: (_view, event) => this.handleClick(event),
            auxclick: (_view, event) => this.handleClick(event),
            // A cell selection copies as a Markdown table (and an HTML one for spreadsheets).
            copy: (view, event) => tableClipboard(view, event, (cell) => this.inlineMarkdown(cell), true),
            cut: (view, event) => tableClipboard(view, event, (cell) => this.inlineMarkdown(cell), this.readOnly),
          },
        }));
      })
      // Before gfm's table editing: its Shift-click handler would end the event first.
      .use(tableTextSelectPlugin)
      .use(commonmark)
      .use(gfm)
      .use(referenceLinkSchema)
      .use(referenceImageSchema)
      .use(history)
      // Before Milkdown's clipboard, so a pasted URL becomes a link.
      .use(pasteLinkPlugin(() => this.readOnly))
      .use(autolinkPlugin(() => this.readOnly))
      .use(clipboard)
      .use(rawSchema)
      .use(pointerSelectPlugin)
      .use(paddingSelectPlugin)
      .use(tableDragOutPlugin)
      .use(activeBlockPlugin)
      .use(taskCheckboxPlugin())
      .use(githubReferencePlugin(() => host.githubRepository))
      .use(obsidianSyntaxPlugin(host))
      .use(userEditPlugin(() => this.options.onUserEdit?.()))
      .use(codeHighlightPlugin(host))
      .use(commentMarkersPlugin());
    if (host.links)
      editor
        .use(brokenLinkPlugin(host.links))
        .use(followCursorPlugin())
        .use(
          linkBubblePlugin(
            {
              host: host.links,
              overlays: this.overlays,
              readOnly: () => this.readOnly,
              openLink: (href) => host.openLink(href),
            },
            this.bubble,
          ),
        );
    await editor.create();
    this.editor = editor;
    editor.action((ctx) => {
      this.view = ctx.get(editorViewCtx);
      this.schema = ctx.get(schemaCtx);
      this.remark = ctx.get(remarkCtx) as unknown as RemarkLike;
      this.serializeDoc = ctx.get(serializerCtx);
    });
  }

  /** A table cell's content as Markdown on one line (copying cells as a Markdown table). */
  private inlineMarkdown(cell: ProseNode): string {
    if (!this.schema || !this.serializeDoc) return cell.textContent;
    const blocks: ProseNode[] = [];
    cell.forEach((child) => blocks.push(child));
    return this.serializeDoc(this.schema.topNodeType.create(null, blocks)).trim();
  }

  private handleClick(event: MouseEvent): boolean {
    const target = event.target as Element | null;
    if (event.type === "click" && this.toggleTask(target, event)) return true;
    if (event.type === "click" && this.followFootnote(target, event)) return true;
    // A [[wikilink]] opens its note as a link does: Cmd-click, or a click when read only.
    const wikilink = target?.closest?.(".md-wikilink[data-href]");
    if (wikilink && event.type === "click" && (event.metaKey || this.readOnly)) {
      event.preventDefault();
      this.options.host.openLink(wikilink.getAttribute("data-href") ?? "");
      return true;
    }
    const anchor = target?.closest?.("a[href]");
    if (!anchor) return false;
    // A link never navigates the page. It opens with Cmd-click, or a plain click when read only.
    event.preventDefault();
    if (event.type === "click" && (event.metaKey || this.readOnly)) {
      this.options.host.openLink(anchor.getAttribute("href") ?? "");
      return true;
    }
    return false;
  }

  /**
   * Footnotes jump both ways: following a reference (Cmd-click, or a click when read only) goes to
   * its definition, and a click on a definition's label goes back to the first reference.
   */
  private followFootnote(target: Element | null, event: MouseEvent): boolean {
    const root = this.view?.dom;
    if (!root || !target) return false;
    const reference = target.closest?.('sup[data-type="footnote_reference"]');
    if (reference && (event.metaKey || this.readOnly)) {
      const label = reference.getAttribute("data-label") ?? "";
      const definition = [...root.querySelectorAll('[data-type="footnote_definition"]')].find(
        (element) => element.getAttribute("data-label") === label,
      );
      if (!definition) return false;
      event.preventDefault();
      this.scrollTo(definition);
      return true;
    }
    const term = target.closest?.('[data-type="footnote_definition"] > dt');
    if (term) {
      const label = term.parentElement?.getAttribute("data-label") ?? "";
      const first = [...root.querySelectorAll('sup[data-type="footnote_reference"]')].find(
        (element) => element.getAttribute("data-label") === label,
      );
      if (!first) return false;
      event.preventDefault();
      this.scrollTo(first);
      const view = this.view!;
      caretAt(view, view.posAtDOM(first, 0) + 1);
      return true;
    }
    return false;
  }

  private scrollTo(element: Element): void {
    const reduce = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
    element.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
  }

  /** Scrolls to the heading a `#anchor` names (GitHub slugs, with `-1` for repeats). */
  scrollToAnchor(anchor: string): boolean {
    const view = this.view;
    if (!view) return false;
    const heading = findHeading(view.state.doc, anchor);
    const dom = heading ? view.nodeDOM(heading.pos) : null;
    if (!(dom instanceof Element)) return false;
    this.scrollTo(dom);
    return true;
  }

  /** Re-checks broken-link marks (the host answered). */
  refreshLinks(): void {
    if (this.view && this.options.host.links) refreshLinks(this.view);
  }

  private readonly bubble: LinkBubbleSlot = { current: null };

  /** The link bubble's edit form on the selection or the link at the caret (the `link` page command, Cmd-K). */
  openLinkPopover(): void {
    if (!this.view || !this.options.host.links || this.readOnly) return;
    this.bubble.current?.editAtSelection();
  }

  /** Forgets every table's column widths in the file (the `resetTableWidths` page command). */
  resetTableWidths(): void {
    this.options.host.tableWidths?.clear();
  }

  /**
   * Forgets the column widths of the table around `target` (the table's right-click Reset Column
   * Widths); false when `target` is in no table.
   */
  resetTableWidthsAt(target: Element | null): boolean {
    const view = tableViewAt(target);
    view?.resetWidths();
    return !!view;
  }

  /** The index among the document's tables of the table around `target`, or null. */
  tableIndexAt(target: Element | null): number | null {
    const wrapper = target?.closest?.(".tableWrapper");
    if (!wrapper || !this.view?.dom.contains(wrapper)) return null;
    const index = [...this.view.dom.querySelectorAll(".tableWrapper")].indexOf(wrapper);
    return index >= 0 ? index : null;
  }

  /** A click on a task item's box (left of its text) checks or unchecks it. */
  private toggleTask(target: Element | null, event: MouseEvent): boolean {
    const item = target?.closest?.('li[data-item-type="task"]');
    const checkbox = target?.closest?.(".cmux-markdown-checkbox");
    const view = this.view;
    if (!item || !view || this.readOnly || (!checkbox && event.clientX >= item.getBoundingClientRect().left))
      return false;
    const inside = view.posAtDOM(item, 0);
    const $pos = view.state.doc.resolve(inside);
    for (let depth = $pos.depth; depth > 0; depth--) {
      const node = $pos.node(depth);
      if (node.type.name !== "list_item" || node.attrs.checked == null) continue;
      view.dispatch(
        view.state.tr.setNodeMarkup($pos.before(depth), undefined, { ...node.attrs, checked: !node.attrs.checked }),
      );
      event.preventDefault();
      return true;
    }
    return false;
  }

  /** Replaces the document with `text`, which becomes the save baseline. Not undoable. */
  load(text: string): void {
    const { view, schema, remark } = this.required();
    this.eol = /\r\n/.test(text.slice(0, text.indexOf("\n") + 1)) ? "\r\n" : "\n";
    const map = parseSourceMap(
      text,
      remark,
      (root) => buildNodes(schema, root),
      (kind: RawKind, value: string) => rawNode(schema, kind, value),
    );
    const nodes = sourceMapNodes(map);
    // Only the blocks that differ are replaced (a reload from disk): the selection maps through the
    // change and stays on its words, and the blocks that did not change keep their DOM.
    const before = this.topNodes();
    const after = nodes.length ? [...nodes] : [schema.nodes.paragraph.create()];
    let head = 0;
    while (head < before.length && head < after.length && sameBlock(before[head]!, after[head]!)) head++;
    let tail = 0;
    while (
      tail < before.length - head &&
      tail < after.length - head &&
      sameBlock(before[before.length - 1 - tail]!, after[after.length - 1 - tail]!)
    )
      tail++;
    if (head < before.length - tail || head < after.length - tail) {
      let from = 0;
      for (let index = 0; index < head; index++) from += before[index]!.nodeSize;
      let to = from;
      for (let index = head; index < before.length - tail; index++) to += before[index]!.nodeSize;
      const tr = view.state.tr.replaceWith(from, to, after.slice(head, after.length - tail));
      tr.setMeta(LOAD_META, true).setMeta("addToHistory", false);
      view.dispatch(tr);
    }
    // The baseline is the document as the editor holds it after its own normalization.
    const current = this.topNodes();
    let index = 0;
    this.baseline = {
      text,
      blocks: map.blocks.map((block) => ({ ...block, nodes: block.nodes.map(() => current[index++] ?? null) })),
    };
    if (index !== current.length || this.baseline.blocks.some((block) => block.nodes.includes(null as never))) {
      this.baseline = map;
    }
    // The lines moved with the new text: the markers go where their lines are now.
    if (this.comments.length) this.setComments(this.comments);
  }

  /** The markdown for the current document, and its source map (the next baseline after a save). */
  snapshot(): SourceMap {
    const { schema } = this.required();
    const serialize = this.serializeDoc!;
    return serializeWithSourceMap(this.baseline, this.topNodes(), (nodes) => {
      const text = serialize(schema.topNodeType.create(null, [...nodes]));
      return this.eol === "\n" ? text : text.replace(/\r?\n/g, this.eol);
    });
  }

  /** Makes `map` (a snapshot that was saved) the baseline. */
  commit(map: SourceMap): void {
    this.baseline = map;
  }

  /**
   * The selection's text and the source lines that hold it (viewer comments,
   * viewer-comments-DESIGN.md), null with nothing selected. Lines count in the current document,
   * which is the file after the next save.
   */
  selectionQuote(): { text: string; startLine?: number; endLine?: number } | null {
    const view = this.view;
    if (!view || !this.serializeDoc) return null;
    const { from, to, empty } = view.state.selection;
    if (empty) return null;
    const doc = view.state.doc;
    const text = doc.textBetween(from, to, "\n", "\n");
    if (!text.trim()) return null;
    const lines = quoteLines(
      this.snapshot(),
      doc.resolve(from).index(0),
      doc.resolve(Math.max(from, to - 1)).index(0),
      text,
    );
    return lines ? { text, ...lines } : { text };
  }

  /** Shows `comments` as margin markers (viewer-comments-DESIGN.md "Comments in the viewer"). */
  setComments(comments: readonly ViewerComment[]): void {
    this.comments = [...comments];
    const view = this.view;
    if (!view || !this.serializeDoc) return;
    const map = this.comments.length ? this.snapshot() : null;
    const host = { label: this.options.host.label, deleteComment: this.options.host.deleteComment };
    const set = commentDecorations(
      view.state.doc,
      this.comments,
      (line) => (map ? topIndexForLine(map, line) : null),
      host,
    );
    view.dispatch(view.state.tr.setMeta(commentMarkersKey, set).setMeta("addToHistory", false));
  }

  /** The baseline text: what the file held at the last load or save. */
  baselineText(): string {
    return this.baseline.text;
  }

  /** Recomputes code colors (the code theme changed). */
  refreshHighlight(): void {
    const view = this.view;
    if (view) view.dispatch(view.state.tr.setMeta(highlightKey, "refresh").setMeta("addToHistory", false));
  }

  setReadOnly(readOnly: boolean): void {
    this.readOnly = readOnly;
    this.view?.setProps({ editable: () => !readOnly });
  }

  focus(): void {
    this.view?.focus();
  }

  /** The editor view, for tests and the page's find. */
  editorView(): EditorView | null {
    return this.view;
  }

  async destroy(): Promise<void> {
    await this.editor?.destroy();
    this.editor = null;
    this.view = null;
  }

  private topNodes(): ProseNode[] {
    const nodes: ProseNode[] = [];
    this.required().view.state.doc.forEach((node) => nodes.push(node));
    return nodes;
  }

  private required(): { view: EditorView; schema: Schema; remark: RemarkLike } {
    if (!this.view || !this.schema || !this.remark) throw new Error("markdown editor is not created");
    return { view: this.view, schema: this.schema, remark: this.remark };
  }
}

/**
 * Whether a loaded block is the one the editor holds: equal, or a heading that differs only in the
 * `id` the editor derives after a load (a fresh parse has none yet).
 */
function sameBlock(held: ProseNode, loaded: ProseNode): boolean {
  if (held.eq(loaded)) return true;
  if (held.type !== loaded.type || held.type.name !== "heading" || !held.content.eq(loaded.content)) return false;
  return held.attrs.level === loaded.attrs.level && (!loaded.attrs.id || loaded.attrs.id === held.attrs.id);
}

/** ProseMirror nodes for a transformed mdast root, with Milkdown's parser state. */
function buildNodes(schema: Schema, root: MdastRoot): ProseNode[] {
  const State = ParserState as unknown as new (schema: Schema) => {
    next(node: unknown): unknown;
    toDoc(): ProseNode;
  };
  const state = new State(schema);
  state.next(root);
  const doc = state.toDoc();
  const nodes: ProseNode[] = [];
  doc.forEach((node) => nodes.push(node));
  return nodes;
}

const activeKey = new PluginKey<DecorationSet>("cmuxMarkdownActive");

const taskCheckboxKey = new PluginKey<DecorationSet>("cmuxMarkdownTaskCheckbox");

const githubReferenceKey = new PluginKey<DecorationSet>("cmuxMarkdownGithubReferences");

/** Renders GitHub issue references without changing the Markdown source or editor marks. */
function githubReferencePlugin(repository: () => string | undefined) {
  return $prose(
    () =>
      new Plugin<DecorationSet>({
        key: githubReferenceKey,
        state: {
          init: (_config, state) => githubReferenceDecorations(state.doc, repository()),
          apply: (tr, previous, _old, state) =>
            tr.docChanged ? githubReferenceDecorations(state.doc, repository()) : previous.map(tr.mapping, state.doc),
        },
        props: { decorations: (state) => githubReferenceKey.getState(state) },
      }),
  );
}

function githubReferenceDecorations(doc: ProseNode, repository?: string): DecorationSet {
  const decorations: Decoration[] = [];
  doc.descendants((node, pos, parent) => {
    if (parent?.type.spec.code) return false;
    if (!node.isText) return true;
    if (node.marks.some((mark) => mark.type.name === "link" || mark.type.spec.code)) return false;
    for (const reference of githubReferences(node.text!, repository)) {
      decorations.push(
        Decoration.inline(pos + reference.start, pos + reference.end, {
          nodeName: "a",
          href: reference.href,
          title: reference.href,
          class: "md-github-reference",
        }),
      );
    }
    return false;
  });
  return DecorationSet.create(doc, decorations);
}

/** Draws the same custom task checkbox as the agent reply renderer. It is a widget rather than a
 * pseudo-element so the task state is exposed to assistive technology in the rich editor. */
function taskCheckboxPlugin() {
  const checkbox = (checked: boolean): HTMLElement => {
    const template = document.createElement("template");
    template.innerHTML = renderToStaticMarkup(createElement(TaskCheckbox, { checked }));
    const element = template.content.firstElementChild;
    if (!(element instanceof HTMLElement)) throw new Error("task checkbox primitive did not render an element");
    element.contentEditable = "false";
    return element;
  };

  const decorations = (doc: ProseNode): DecorationSet => {
    const result: Decoration[] = [];
    doc.descendants((node, pos) => {
      if (node.type.name === "list_item" && node.attrs.checked != null) {
        result.push(Decoration.widget(pos + 2, () => checkbox(Boolean(node.attrs.checked)), { side: -1 }));
      }
      return true;
    });
    return DecorationSet.create(doc, result);
  };

  return $prose(
    () =>
      new Plugin<DecorationSet>({
        key: taskCheckboxKey,
        state: {
          init: (_config, state) => decorations(state.doc),
          apply: (tr, previous, _old, state) =>
            tr.docChanged ? decorations(state.doc) : previous.map(tr.mapping, state.doc),
        },
        props: {
          decorations: (state) => taskCheckboxKey.getState(state),
        },
      }),
  );
}

/** The top-level block holding the selection's head, as a decoration (`md-active`). */
function activeBlock(state: EditorState): DecorationSet {
  const { $head, from } = state.selection;
  // A node selection of a top-level block sits at depth 0, before the block.
  const start = $head.depth >= 1 ? $head.before(1) : from;
  const node = state.doc.nodeAt(start);
  if (!node) return DecorationSet.empty;
  return DecorationSet.create(state.doc, [Decoration.node(start, start + node.nodeSize, { class: "md-active" })]);
}

/**
 * Marks the top-level block holding the selection `md-active` (diagrams and HTML show source).
 * While the button is down it stays on the block it was on (pointerSelect.ts): a diagram's source
 * opening under a drag moved the text below it.
 */
const activeBlockPlugin = $prose(
  () =>
    new Plugin<DecorationSet>({
      key: activeKey,
      state: {
        init: (_config, state) => activeBlock(state),
        apply: (tr, previous, _old, state) =>
          isPointerSelecting(state) && !pointerChanged(tr) ? previous.map(tr.mapping, state.doc) : activeBlock(state),
      },
      props: {
        decorations: (state) => activeKey.getState(state),
      },
    }),
);

/**
 * A document change the user made. Not a load, an appended fix, or a change kept out of the undo
 * history: the editor's own normalization (heading ids sync after a load) dispatches those.
 */
function isUserEdit(tr: Transaction): boolean {
  return (
    tr.docChanged &&
    !tr.getMeta(LOAD_META) &&
    !tr.getMeta("appendedTransaction") &&
    tr.getMeta("addToHistory") !== false
  );
}

/** Reports document changes the user made (`isUserEdit`). */
function userEditPlugin(onUserEdit: () => void) {
  return $prose(
    () =>
      new Plugin({
        appendTransaction(transactions: readonly Transaction[]) {
          if (transactions.some(isUserEdit)) onUserEdit();
          return null;
        },
      }),
  );
}

/** The code colors, and the positions of the code blocks near the viewport (null: all of them). */
type HighlightState = { decorations: DecorationSet; near: readonly number[] | null };
type HighlightMeta = "refresh" | { near: number[] };

const highlightKey = new PluginKey<HighlightState>("cmuxMarkdownHighlight");

/** The editor's near-viewport watcher (nearCode.ts), made by its first code block. */
const nearWatchers = new WeakMap<EditorView, NearCodeBlocks>();
function nearCodeBlocks(view: EditorView): NearCodeBlocks | null {
  if (!NearCodeBlocks.supported) return null;
  let watcher = nearWatchers.get(view);
  if (!watcher) {
    watcher = new NearCodeBlocks(view.dom, (near) => {
      if (!view.isDestroyed)
        view.dispatch(
          view.state.tr.setMeta(highlightKey, { near } satisfies HighlightMeta).setMeta("addToHistory", false),
        );
    });
    nearWatchers.set(view, watcher);
  }
  return watcher;
}

/** Whether the code block at `pos` is colored now (near the viewport, or every block is). */
function codeBlockNear(state: EditorState, pos: number | undefined): boolean {
  const near = highlightKey.getState(state)?.near;
  return near === null || near === undefined || (pos !== undefined && near.includes(pos));
}

/**
 * Colors code blocks with the host's highlighter (shiki, the diff viewer's terminal theme): only the
 * blocks near the viewport (nearCode.ts), so a long file with code in many languages loads and
 * tokenizes only the grammars the reader sees. Near positions map through edits, so a block keeps
 * its colors while it is edited.
 */
function codeHighlightPlugin(host: MarkdownEditorHost) {
  return $prose(() => {
    const decorate = (doc: ProseNode, near: readonly number[] | null, refresh: () => void): DecorationSet => {
      if (!host.highlight) return DecorationSet.empty;
      if (near?.length === 0) return DecorationSet.empty;
      const nearSet = near && new Set(near);
      const decorations: Decoration[] = [];
      doc.descendants((node, pos) => {
        if (node.type.name !== "code_block") return true;
        const language = String(node.attrs.language ?? "").toLowerCase();
        if (!language || DIAGRAM_LANGUAGES.has(language) || (nearSet && !nearSet.has(pos))) return false;
        // Marks the block near, so a block that stops being near (a reload replaced it with an equal
        // node) no longer matches its decorations: ProseMirror updates its view, which watches it again.
        if (nearSet) decorations.push(Decoration.node(pos, pos + node.nodeSize, { "data-near": "" }));
        const tokens = host.highlight!(node.textContent, language, refresh);
        for (const token of tokens ?? []) {
          decorations.push(Decoration.inline(pos + 1 + token.from, pos + 1 + token.to, { style: token.style }));
        }
        return false;
      });
      return DecorationSet.create(doc, decorations);
    };
    let view: EditorView | null = null;
    const refresh = () => {
      if (view) view.dispatch(view.state.tr.setMeta(highlightKey, "refresh").setMeta("addToHistory", false));
    };
    return new Plugin<HighlightState>({
      key: highlightKey,
      state: {
        init: (_config, state) => {
          const near = NearCodeBlocks.supported ? [] : null;
          return { near, decorations: decorate(state.doc, near, refresh) };
        },
        apply: (tr, previous, _old, state) => {
          const meta = tr.getMeta(highlightKey) as HighlightMeta | undefined;
          let near = previous.near;
          if (near && tr.docChanged)
            near = near.flatMap((pos) => {
              const mapped = tr.mapping.mapResult(pos, 1);
              return mapped.deleted ? [] : [mapped.pos];
            });
          if (near && typeof meta === "object") near = [...new Set([...near, ...meta.near])];
          if (!tr.docChanged && !meta) return { near, decorations: previous.decorations.map(tr.mapping, tr.doc) };
          return { near, decorations: decorate(state.doc, near, refresh) };
        },
      },
      view(editorView) {
        view = editorView;
        return {
          destroy: () => {
            nearWatchers.get(editorView)?.disconnect();
            nearWatchers.delete(editorView);
            view = null;
          },
        };
      },
      props: {
        decorations: (state) => highlightKey.getState(state)?.decorations,
      },
    });
  });
}

/** The node views: code blocks (language label, diagrams), raw blocks and images. */
function nodeViews(host: MarkdownEditorHost): Record<string, NodeViewConstructor> {
  return {
    code_block: (node, view, getPos) => new CodeBlockView(node, view, getPos, host),
    [RAW_NODE]: (node, view, getPos) => new RawBlockView(node, view, getPos, host),
    // Each table sits in prosemirror-tables' `.tableWrapper` (its min-width 100px a column), the
    // box a wide table scrolls sideways in (styles.css, MARKDOWN-TABLE-SCROLL), with a resize
    // handle on each column's edge (tables.ts). gfm's plugins leave out columnResizing, which
    // would write widths into the document, so the editor names its own view here.
    table: (node, view, getPos) => new ResizableTableView(node, view, getPos, host.tableWidths, 100),
    image: (node) => {
      const dom = document.createElement("span");
      dom.className = "md-image-node";
      dom.contentEditable = "false";
      let current = node;
      const apply = (next: ProseNode) => {
        current = next;
        const source = String(next.attrs.src ?? "");
        const resolved = host.imageURL(source);
        // Obsidian's size suffix: `![alt|300](src)` or `|300x200`.
        const alt = String(next.attrs.alt ?? "");
        const sized = /^(.*?)\|\s*(\d+(?:\s*x\s*\d+)?)\s*$/.exec(alt);
        const size = imageSize(sized?.[2]);
        const plainAlt = sized ? sized[1]!.trim() : alt;
        if (!resolved && /^https?:\/\//i.test(source.trim())) {
          dom.replaceChildren(markdownRemoteImagePlaceholder(host, source, plainAlt));
          return;
        }
        const img = document.createElement("img");
        if (resolved) img.src = resolved;
        img.alt = plainAlt;
        if (size.width) img.setAttribute("width", String(size.width));
        if (size.height) img.setAttribute("height", String(size.height));
        if (next.attrs.title) img.title = String(next.attrs.title);
        dom.replaceChildren(img);
      };
      apply(node);
      const stop = host.observeRemoteImages?.(() => apply(current));
      return {
        dom,
        update: (next) => {
          if (next.type !== node.type) return false;
          apply(next);
          return true;
        },
        stopEvent: (event) => event.target instanceof Element && !!event.target.closest("button"),
        ignoreMutation: () => true,
        destroy: () => stop?.(),
      };
    },
  };
}

/** The visible control in place of a remote image. Its click approves the whole document. */
export function markdownRemoteImagePlaceholder(host: MarkdownEditorHost, source: string, alt: string): HTMLElement {
  const placeholder = document.createElement("span");
  placeholder.className = "md-remote-image-placeholder";
  placeholder.title = source;
  const label = document.createElement("span");
  label.textContent = alt || host.label("remoteImageBlocked");
  const button = document.createElement("button");
  button.type = "button";
  button.className = "md-button";
  button.textContent = host.label("remoteImageLoad");
  button.addEventListener("mousedown", (event) => event.preventDefault());
  button.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    button.disabled = true;
    void host.loadRemoteImages?.().catch((error: unknown) => {
      button.disabled = false;
      console.warn("cmux markdown remote images", error);
    });
  });
  placeholder.append(label, button);
  return placeholder;
}

/** Puts the caret at the start of a node's text, so clicking a preview edits its source. */
function selectInside(view: EditorView, getPos: () => number | undefined): void {
  const pos = getPos();
  if (pos === undefined) return;
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos + 1))));
  view.focus();
}

class CodeBlockView {
  readonly dom: HTMLElement;
  readonly contentDOM: HTMLElement;
  private readonly label: HTMLElement;
  private readonly preview: HTMLElement;
  private language = "";
  private source = "";
  private renderTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private node: ProseNode,
    private readonly view: EditorView,
    private readonly getPos: () => number | undefined,
    private readonly host: MarkdownEditorHost,
  ) {
    this.dom = document.createElement("div");
    this.dom.className = "md-code";
    this.label = document.createElement("span");
    this.label.className = "md-code-language";
    this.label.contentEditable = "false";
    this.preview = document.createElement("div");
    this.preview.className = "md-diagram";
    this.preview.contentEditable = "false";
    this.preview.addEventListener("mousedown", (event) => {
      event.preventDefault();
      selectInside(this.view, this.getPos);
    });
    const pre = document.createElement("pre");
    this.contentDOM = document.createElement("code");
    pre.append(this.contentDOM);
    this.dom.append(this.label, this.preview, pre);
    this.apply(node);
    // Colored once it comes near the viewport (codeHighlightPlugin).
    nearCodeBlocks(view)?.watch(this.dom, getPos);
  }

  private apply(node: ProseNode): void {
    const language = String(node.attrs.language ?? "");
    const diagram = DIAGRAM_LANGUAGES.has(language.toLowerCase());
    this.dom.classList.toggle("md-code-diagram", diagram);
    this.label.textContent = language || this.host.label("plainText");
    this.dom.dataset.language = language;
    if (!diagram) {
      this.preview.replaceChildren();
      this.language = language;
      this.source = node.textContent;
      return;
    }
    if (language === this.language && node.textContent === this.source) return;
    const first = this.language !== language || !this.source;
    this.language = language;
    this.source = node.textContent;
    if (this.renderTimer) clearTimeout(this.renderTimer);
    // Typing in a diagram's source re-renders once the typing pauses.
    const render = () => this.host.renderDiagram?.(this.language.toLowerCase(), this.source, this.preview);
    if (first) render();
    else this.renderTimer = setTimeout(render, 300);
  }

  update(node: ProseNode): boolean {
    if (node.type !== this.node.type) return false;
    this.node = node;
    this.apply(node);
    // A block replaced in place (a reload from disk) lost its near position: watch it again.
    if (!codeBlockNear(this.view.state, this.getPos())) nearCodeBlocks(this.view)?.watch(this.dom, this.getPos);
    return true;
  }

  stopEvent(event: Event): boolean {
    return this.preview.contains(event.target as Node) || this.label.contains(event.target as Node);
  }

  ignoreMutation(mutation: MutationRecord | { type: string; target: Node }): boolean {
    return !this.contentDOM.contains(mutation.target) || mutation.type === "attributes";
  }

  destroy(): void {
    if (this.renderTimer) clearTimeout(this.renderTimer);
    nearWatchers.get(this.view)?.forget(this.dom);
  }
}

class RawBlockView {
  readonly dom: HTMLElement;
  readonly contentDOM: HTMLElement;
  private readonly header: HTMLButtonElement;
  private readonly preview: HTMLElement;
  private html = "";
  private readonly stopRemoteImages: (() => void) | undefined;

  constructor(
    private node: ProseNode,
    private readonly view: EditorView,
    private readonly getPos: () => number | undefined,
    private readonly host: MarkdownEditorHost,
  ) {
    const kind = String(node.attrs.kind) as RawKind;
    this.dom = document.createElement("div");
    this.dom.className = `md-raw md-raw-${kind}`;
    this.header = document.createElement("button");
    this.header.type = "button";
    this.header.className = "md-raw-label";
    this.header.contentEditable = "false";
    this.header.textContent = host.label(kind);
    this.header.addEventListener("mousedown", (event) => event.preventDefault());
    this.header.addEventListener("click", () => {
      // Front matter is folded by default, as in the classic viewer.
      if (kind === "frontmatter") this.dom.classList.toggle("md-open");
      else selectInside(this.view, this.getPos);
    });
    this.preview = document.createElement("div");
    this.preview.className = "md-raw-preview";
    this.preview.contentEditable = "false";
    this.preview.addEventListener("mousedown", (event) => {
      if ((event.target as Element).closest?.("a[href], summary, button")) return;
      event.preventDefault();
      selectInside(this.view, this.getPos);
    });
    // A link in a preview never navigates the page; a click opens it through the host.
    this.preview.addEventListener("click", (event) => {
      const anchor = (event.target as Element).closest?.("a[href]");
      if (!anchor) return;
      event.preventDefault();
      host.openLink(anchor.getAttribute("href") ?? "");
    });
    const pre = document.createElement("pre");
    this.contentDOM = document.createElement("code");
    pre.append(this.contentDOM);
    this.dom.append(this.header, this.preview, pre);
    this.renderPreview(node);
    this.stopRemoteImages = host.observeRemoteImages?.(() => {
      this.html = "";
      this.renderPreview(this.node);
    });
  }

  private renderPreview(node: ProseNode): void {
    if (node.attrs.kind !== "html") return;
    const html = node.textContent;
    if (html === this.html) return;
    this.html = html;
    const fragment = this.host.htmlPreview?.(html);
    this.preview.replaceChildren(...(fragment ? [fragment] : []));
    this.dom.classList.toggle("md-raw-has-preview", !!fragment && this.preview.childNodes.length > 0);
  }

  update(node: ProseNode): boolean {
    if (node.type !== this.node.type || node.attrs.kind !== this.node.attrs.kind) return false;
    this.node = node;
    this.renderPreview(node);
    return true;
  }

  stopEvent(event: Event): boolean {
    return this.header.contains(event.target as Node) || this.preview.contains(event.target as Node);
  }

  ignoreMutation(mutation: MutationRecord | { type: string; target: Node }): boolean {
    return !this.contentDOM.contains(mutation.target) || mutation.type === "attributes";
  }

  destroy(): void {
    this.stopRemoteImages?.();
  }
}
