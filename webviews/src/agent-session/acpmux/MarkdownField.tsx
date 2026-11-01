import React, { useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef } from "react";
import { PASTE_FILE_CHARS } from "./pastedText";
import { escapeDefinitions, insertReplyQuote } from "./quoteReply";
import { pasteIsOnlyFileNames } from "./attachments";
import { COMPOSER_READY_EVENT } from "./composerFocus";
import { liftInlineImages, withoutMarkdownImages } from "./inlineImages";
import { isImeKeyEvent } from "../../pages/shared/imeKeys";
import { activeFormats, applyFormat, type MarkdownFormat } from "./markdownFormat";
import "./markdownField.css";
import { followScrollEdges } from "./summary/scrollEdges";
import {
  inlineAttachmentNode,
  inlineIds,
  inlinePlugin,
  insertInline,
  orderInline,
  placeTokensIn,
  removeInline,
  type SelectionPart,
  selectionParts,
  sliceHoldsInline,
  wholeSelected,
  withTextMarksEscaped,
} from "./composer/inlineNode";
import { followActionsWidth } from "./composerScrollLane";
import { caretInView } from "./composer/caretInView";
import { MINIMAL_SCROLLER_ATTRIBUTE, followShownScrollerFade } from "../../scrollers";
import {
  Editor,
  defaultValueCtx,
  editorViewCtx,
  editorViewOptionsCtx,
  parserCtx,
  remarkCtx,
  remarkStringifyOptionsCtx,
  rootCtx,
  serializerCtx,
} from "@milkdown/kit/core";
import { commonmark } from "@milkdown/kit/preset/commonmark";
import { gfm } from "@milkdown/kit/preset/gfm";
import { history } from "@milkdown/kit/plugin/history";
import { clipboard } from "@milkdown/kit/plugin/clipboard";
import { baseKeymap, chainCommands, lift, selectAll } from "@milkdown/kit/prose/commands";
import { redo, redoDepth, undo, undoDepth } from "@milkdown/kit/prose/history";
import { keymap } from "@milkdown/kit/prose/keymap";
import { splitListItem } from "@milkdown/kit/prose/schema-list";
import { type EditorState, Plugin, Selection, TextSelection } from "@milkdown/kit/prose/state";
import { Fragment, type Node as ProseNode, Slice } from "@milkdown/kit/prose/model";
import type { EditorView } from "@milkdown/kit/prose/view";
import type { RemarkParser } from "@milkdown/kit/transformer";
import { $prose, getMarkdown, replaceAll } from "@milkdown/kit/utils";

/// What the composer drives the field with, in place of a textarea's DOM API.
export type MarkdownFieldHandle = {
  focus(): void;
  /// Puts the caret `offset` characters into the prompt's first paragraph.
  setCaret(offset: number): void;
  /// The prompt as markdown, as the field holds it now.
  value(): string;
  /// The caret's offset in the first paragraph.
  caret(): number;
  /// Replaces the prompt as typing would: the composer hears it through `onChange`.
  /// False when the editor is not made yet (it mounts a moment after the field): nothing changed,
  /// and the caller sets the field's `value` instead.
  type(markdown: string): boolean;
  /// Appends a reply quote after the draft, regardless of selection; leaves a reply paragraph.
  quoteReply(markdown: string): boolean;
  /// The prompt as plain text (blocks joined by newlines) and the selection's offsets into it,
  /// for dictation, which splices words at the cursor.
  text(): PlainPrompt;
  /// Whether Backspace here would do nothing: an empty caret at the very start of a plain first
  /// paragraph (a heading, list item or quote there takes Backspace to lift itself).
  atStart(): boolean;
  /// Rewrites the plain text to `value` as one undoable edit of the span that changed, then
  /// selects `selectionStart...selectionEnd`; the composer hears it through `onChange`.
  writeText(value: string, selectionStart: number, selectionEnd: number): void;
  /// Whether the prompt has focus.
  focused(): boolean;
  /// The field's element, which composition events from the prompt pass through.
  element(): HTMLElement | null;
  /// The prompt as plain text (no Markdown markers or escaping), blocks joined by newlines.
  plainText(): string;
  /// Inserts `text` at the caret as typing would: through `onBeforeInput` first (tests, automation).
  insertTyped(text: string): void;
  /// Pastes `text` as the clipboard would: through `onBeforeInput` first.
  pasteText(text: string): void;
  /// Replaces the prompt without reporting it as the user's edit (a new tab adopted, a chat sent).
  reset(markdown?: string): void;
  /// `markdown` (the field's value) as the agent gets it: the characters the user typed, with
  /// markdown syntax only where the field formatted it (`**bold**`, a code span, a list).
  agentText(markdown: string): string;
  /// Applies or removes a Markdown format at the selection (a surface's format toolbar).
  format(format: MarkdownFormat, href?: string): void;
  /// The formats active at the selection, for the toolbar's pressed states.
  formats(): Set<MarkdownFormat>;
  /// The field's own history (its context menu's Undo and Redo): whether there is an edit to
  /// undo or redo, and doing it.
  history(): { undo: boolean; redo: boolean };
  undo(): void;
  redo(): void;
  /// Selects the whole prompt (its context menu's Select All).
  selectAll(): void;
  /// Inserts `text` at the selection as a paste of plain text goes in, with no surface rule run on it
  /// (a copy's own runs of text put back in order, composer/composerCopy.ts).
  insertText(text: string): void;
  /// Places attachments `ids` at the caret, in the text (composer/inlineNode.ts); false where they
  /// cannot go (a code block, an editor not made yet).
  insertInline(ids: readonly string[]): boolean;
  /// Takes attachment `id` out of the text; `caret`, the caret goes where it was.
  removeInline(id: string, caret?: boolean): void;
  /// Puts the attachments placed in the text in `ids`' order, each place in the text kept.
  orderInline(ids: readonly string[]): void;
  /// The ids of the attachments placed in the text, from its nodes alone (text shaped like a token
  /// is text), in order, each once; undefined before the editor is made.
  inlineIds(): string[] | undefined;
};

export type PlainPrompt = { value: string; selectionStart: number; selectionEnd: number };

/// The field's handle, also on its element as `acpmuxMarkdownField` for tests and tools that
/// drive the prompt the way a textarea's value would be set.
export type MarkdownFieldElement = HTMLDivElement & { acpmuxMarkdownField?: MarkdownFieldHandle };

export type MarkdownFieldProps = {
  /// The prompt as markdown. A value the field did not emit itself (cleared after a send, a
  /// command the menu wrote) replaces the document.
  value: string;
  /// The new markdown, and the caret's offset in the first paragraph (where `/` commands live).
  onChange(markdown: string, caret: number): void;
  onCaret?(caret: number): void;
  /// Runs before the editor's own keys; preventDefault keeps the editor from handling the key.
  onKeyDown?(event: KeyboardEvent): void;
  onCompositionChange?(composing: boolean): void;
  /// Typed or pasted text before the editor inserts it, and whether the prompt was empty, an IME
  /// composition runs and it is a paste (then `data` is the clipboard's plain text as copied); true
  /// consumes it (the new tab's "!" rule converts the tab instead, the composer makes a huge paste a chip).
  onBeforeInput?(data: string, state: { empty: boolean; composing: boolean; paste: boolean }): boolean;
  /// Enter (with `cmd` for Cmd-Enter) that `onKeyDown` did not take; unset, Enter is the editor's.
  onSubmit?(markdown: string, modifiers: { cmd: boolean }): void;
  /// A new paragraph or line the browser inserts on its own, not from a key the field handled: the
  /// Return an input method or Dictation passes on (keyCode 229, which every key handler leaves to
  /// it), or that 229 Return itself once no composition runs or just ended. Set, the field never
  /// adds that line and this runs instead, as Return would.
  onReturnInput?(): void;
  /// The user's first edit (the new tab's `newTab.touched`).
  onFirstInput?(): void;
  /// The editor is made, once per field: the handle's methods act from here on (none did before),
  /// the value given so far is its document, and its placed attachments are their nodes. Called in
  /// the same task as `editor.current` and `view.current` are set, before COMPOSER_READY_EVENT.
  onReady?(): void;
  /// Quotes `quoteReply` took before the editor was made, when the field goes before it is made:
  /// they were never placed, so the owner keeps them for the next field (none is ever dropped).
  onUnplacedQuotes?(quotes: string[]): void;
  /// The element each attachment placed in the text draws its chip into, by id, as they change.
  /// Only a field given one when it is made has placed attachments (composer/inlineNode.ts); any
  /// other keeps every U+FFFC as its text and pastes plain text.
  onInlineViews?(views: ReadonlyMap<string, HTMLElement>): void;
  /// Whether `id` is one of the composer's attachments: the draft's tokens are read against it
  /// (composer/inlineNode.ts InlineKnown), so a U+FFFC the person wrote just before a word and an
  /// attachment stays their text. Read when a value's tokens become nodes (the editor made, a value
  /// set from outside, `type`); unset, every token-shaped run is taken for an attachment.
  isInlineAttachment?(id: string): boolean;
  /// A copy or cut of the selection (Cmd-C, Cmd-X, the menu's): its runs of text and its placed
  /// attachments in order, its text as the field copies it, and whether it holds the whole draft.
  /// True when the surface wrote the pasteboard itself; the field then takes a cut's selection out.
  onCopy?(copy: { parts: SelectionPart[]; text: string; whole: boolean }, cut: boolean): boolean;
  /// Whether the selection holds the whole draft (Select All), as it changes: the surface marks what
  /// it shows besides the text (the strip's attachments) as selected too.
  onWholeSelection?(whole: boolean): void;
  /// A paste before the field reads it: true when the surface put it in itself.
  onPasteFirst?(event: ClipboardEvent): boolean;
  /// The surface's own key handling, which runs before the editor's keys (the omnibar word rules).
  plugins?: Plugin[];
  /// Shift-Enter adds a line (default true).
  multiline?: boolean;
  /// Commands keep literal characters: no Markdown input rules or formatting shortcuts.
  literal?: boolean;
  /// Keep typing unformatted while retaining the normal attachment-aware clipboard/drop paths.
  plainInput?: boolean;
  placeholder?: string;
  /// A muted keycap after the placeholder, naming the key that takes it (the composer's "Tab").
  placeholderKey?: string;
  className?: string;
  /// Attributes for the editable element (aria-label, role=combobox, aria-expanded...).
  attributes?: Record<string, string | undefined>;
  /// Whose selection the field keeps for a focus with no click (the composer's chat session): a
  /// selection kept under one key never comes back under another, even over the same text.
  selectionKey?: string;
};

/// Streaming agent updates replace the composer's snapshot while the prompt is unchanged. The
/// editor keeps its own ProseMirror view, so rebuilding that React subtree for every token only
/// competes with the next key for the main thread. Event callbacks are held in `latest` below;
/// callers may therefore update their refs without forcing the editor to reconcile.
function sameMarkdownFieldAttributes(
  left: MarkdownFieldProps["attributes"],
  right: MarkdownFieldProps["attributes"],
): boolean {
  if (left === right) return true;
  const leftKeys = Object.keys(left ?? {});
  const rightKeys = Object.keys(right ?? {});
  if (leftKeys.length !== rightKeys.length) return false;
  return leftKeys.every((key) => left?.[key] === right?.[key]);
}

function sameMarkdownFieldProps(previous: MarkdownFieldProps, next: MarkdownFieldProps): boolean {
  return (
    previous.value === next.value &&
    previous.multiline === next.multiline &&
    previous.literal === next.literal &&
    previous.plainInput === next.plainInput &&
    previous.placeholder === next.placeholder &&
    previous.placeholderKey === next.placeholderKey &&
    previous.className === next.className &&
    previous.selectionKey === next.selectionKey &&
    previous.onChange === next.onChange &&
    previous.onCaret === next.onCaret &&
    previous.onKeyDown === next.onKeyDown &&
    previous.onCompositionChange === next.onCompositionChange &&
    previous.onBeforeInput === next.onBeforeInput &&
    previous.onSubmit === next.onSubmit &&
    previous.onReturnInput === next.onReturnInput &&
    previous.onFirstInput === next.onFirstInput &&
    previous.onReady === next.onReady &&
    previous.onUnplacedQuotes === next.onUnplacedQuotes &&
    previous.onInlineViews === next.onInlineViews &&
    previous.isInlineAttachment === next.isInlineAttachment &&
    previous.onCopy === next.onCopy &&
    previous.onWholeSelection === next.onWholeSelection &&
    previous.onPasteFirst === next.onPasteFirst &&
    previous.plugins === next.plugins &&
    sameMarkdownFieldAttributes(previous.attributes, next.attributes)
  );
}

/** Markdown without the serializer's trailing newline, and empty for an empty document.
 * Milkdown writes an empty paragraph as `<br />`; empty lines a prompt starts or ends with
 * are not part of it. */
const clean = (markdown: string) =>
  markdown
    .replace(/\n+$/, "")
    .replace(/^\u200b$/, "")
    .replace(/(^|\n\n)<br \/>(?=\n\n|$)/g, "$1")
    .replace(/^\n+|\n+$/g, "");

/** Spaces at the end of the prompt: markdown drops them, but "/review " needs its space. */
const trailingSpaces = (view: EditorView) => /[ \t]+$/.exec(view.state.doc.lastChild?.textContent ?? "")?.[0] ?? "";

/// Whether pasted HTML holds an image of its own data (an <img> with a `data:` source).
const htmlHasDataImage = (html: string) => /<img\b[^<>]*\ssrc\s*=\s*["']?\s*data:/i.test(html);

/** Text copied as Milkdown's markdown (before this field copied plain text) wrote a blank line as
 * a `<br />` line between blank lines: that placeholder is a blank line. Every other character,
 * a `<br>` in pasted source included, stays as copied. */
const withoutBreakPlaceholders = (text: string) =>
  text
    .replace(/\r\n?/g, "\n")
    .replace(/\n\n<br \/>(?=\n\n)/g, "")
    .replace(/^<br \/>\n\n/, "\n")
    .replace(/\n\n<br \/>\n?$/, "\n");

const BLOCK_TAG = /^(P|DIV|LI|PRE|BLOCKQUOTE|H[1-6]|UL|OL|TABLE|TR|SECTION|ARTICLE|HEADER|FOOTER)$/;

/** HTML pasted with no plain text, as its text: each `<br>` and block (a `<p>`) ends a line. */
function htmlText(html: string): string {
  const template = document.createElement("template");
  template.innerHTML = html;
  let out = "";
  const walk = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      out += (node.textContent ?? "").replace(/\s+/g, " ");
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const tag = (node as Element).tagName;
    if (tag === "BR") {
      out += "\n";
      return;
    }
    if (tag === "STYLE" || tag === "SCRIPT" || tag === "META" || tag === "TITLE") return;
    const block = BLOCK_TAG.test(tag);
    if (block && out && !out.endsWith("\n")) out += "\n";
    for (const child of node.childNodes) walk(child);
    if (block) out += "\n";
  };
  for (const child of template.content.childNodes) walk(child);
  return out.replace(/[ \t]+\n/g, "\n").replace(/^\n+|\n+$/g, "");
}

/** Plain text as the field shows it: one paragraph whose newlines are line breaks, a blank line
 * two of them. A paste is never parsed as markdown or HTML, so its lines and characters stay. */
function plainFragment(view: EditorView, text: string): Fragment {
  const { schema } = view.state;
  const hardbreak = schema.nodes.hardbreak;
  const nodes: ProseNode[] = [];
  text.split("\n").forEach((line, index) => {
    if (index > 0) nodes.push(hardbreak ? hardbreak.create() : schema.text(" "));
    if (line) nodes.push(schema.text(line));
  });
  return Fragment.from(nodes);
}

/** Inserts `text` at the selection as the field's lines (`plainFragment`), the caret after it. */
function insertPlain(view: EditorView, text: string) {
  const { from, to, $from } = view.state.selection;
  // In a code block a newline is a newline.
  if ($from.parent.type.spec.code) {
    view.dispatch(view.state.tr.insertText(text, from, to).scrollIntoView());
    return;
  }
  const fragment = plainFragment(view, text);
  const tr = view.state.tr.replaceWith(from, to, fragment);
  tr.setSelection(TextSelection.near(tr.doc.resolve(tr.mapping.map(to))));
  view.dispatch(tr.scrollIntoView());
}

/** The copy's text/plain: the lines as the field shows them (a block or line break a newline, an
 * empty paragraph a blank line), with no markdown escapes or `<br />` placeholders. */
const copiedText = (slice: Slice) => slice.content.textBetween(0, slice.content.size, "\n");

/// How long after a focus with no click the browser's own caret placement is overruled. Its caret
/// at the field's very start is overruled for as long as no key, click or edit came (see `keepCaret`).
const KEEP_CARET_MS = 100;
/// How soon after `compositionend` a keyCode-229 Return is the key that committed the composition
/// (WebKit sends it after the event). ProseMirror's own Safari guard uses the same window.
const COMMIT_RETURN_MS = 500;
/** Return or keypad Enter, also when an input method reports its key as "Process". */
const isReturnKey = (event: KeyboardEvent) =>
  event.key === "Enter" || event.code === "Enter" || event.code === "NumpadEnter";
/// The soft band at a long draft's scrolled edges (markdownField.css reads it as
/// `--acpmux-md-fade-band`). The caret reveal keeps the caret this far from the field's edge, so the
/// caret's line never sits in the fade. The attachment row above the prompt fades its scrolled sides
/// by the same band (composer/attachmentIntake.tsx).
export const FADE_BAND_PX = 18;

/** The document as the prompt's markdown, keeping the spaces typed at its end and the empty reply
 * paragraph needed on restore. A field with placed attachments writes the person's own text shaped
 * like a token escaped (composer/inlineNode.ts withTextMarksEscaped): only its nodes write tokens. */
function promptMarkdown(editor: Editor | undefined, view: EditorView, inline: boolean): string {
  const escaped = inline ? withTextMarksEscaped(view.state.doc) : view.state.doc;
  const written =
    escaped === view.state.doc
      ? editor?.action(getMarkdown())
      : editor?.action((ctx) => ctx.get(serializerCtx)(escaped));
  const markdown = clean(written ?? "");
  const { doc, schema } = view.state;
  // The serializer omits the empty typing paragraph Quote in Reply leaves after its block.
  // Keep that boundary in the persisted value: setDocument recreates it from the blank line,
  // so a remount's end caret stays below the quote. Ordinary paragraph drafts remain trimmed.
  if (
    markdown &&
    doc.childCount > 1 &&
    doc.lastChild?.type === schema.nodes.paragraph &&
    !doc.lastChild.content.size &&
    doc.child(doc.childCount - 2).type !== schema.nodes.paragraph
  )
    return markdown + "\n\n";
  const tail = trailingSpaces(view);
  return tail && !markdown.endsWith(tail) ? markdown + tail : markdown;
}

type MdNode = { type: string; value?: string; url?: string; children?: MdNode[] };

/** A link that GFM made from a bare URL in the text: its text is the URL as written. */
const bareLinkText = (node: MdNode) => {
  const only = node.children?.length === 1 ? node.children[0] : undefined;
  const value = only?.type === "text" ? only.value : undefined;
  if (value === undefined || !node.url) return undefined;
  return [value, `http://${value}`, `mailto:${value}`].includes(node.url) ? value : undefined;
};

/** Text, and links GFM made from bare URLs, as raw nodes: the serializer writes them unescaped.
 * A line break (a pasted or Shift-Return newline inside a paragraph) is the newline it was, not
 * markdown's `\\` hard break. */
function asWritten(node: MdNode): MdNode {
  if (node.type === "text") return { type: "html", value: node.value ?? "" };
  if (node.type === "break") return { type: "html", value: "\n" };
  if (node.type === "link") {
    const bare = bareLinkText(node);
    if (bare !== undefined) return { type: "html", value: bare };
  }
  if (!node.children) return node;
  // One raw node per run: the serializer turns a newline before a raw node into a space.
  const children: MdNode[] = [];
  for (const child of node.children.map(asWritten)) {
    const last = children.at(-1);
    if (child.type === "html" && last?.type === "html")
      children[children.length - 1] = { ...last, value: `${last.value}${child.value}` };
    else children.push(child);
  }
  return { ...node, children };
}

/** The field's markdown with its text as the user typed it. The field's value escapes text
 * (`\\[`, `http\\:`, `\\*`) so that reading it back gives the same text, not a link or
 * emphasis. The agent gets the typed characters; formatted nodes keep their markdown syntax. */
function typedText(remark: RemarkParser, markdown: string): string {
  // ProseMirror has no reference-definition node. A serialized paragraph that looks like one
  // is literal text; protect it before inline-links can remove it on this second parsing pass.
  const parsed = remark.parse(markdown);
  const safe = escapeDefinitions(markdown, parsed as unknown as MdNode);
  const tree = remark.runSync(safe === markdown ? parsed : remark.parse(safe), safe) as unknown as MdNode;
  return clean(String(remark.stringify(asWritten(tree) as unknown as Parameters<RemarkParser["stringify"]>[0])));
}

/** The caret's offset inside the first paragraph, else past its end. */
function caretOf(view: EditorView): number {
  const { selection, doc } = view.state;
  const first = doc.firstChild;
  if (!first) return 0;
  const start = 1;
  const end = start + first.content.size;
  if (selection.from < start || selection.from > end) return first.textContent.length + 1;
  return doc.textBetween(start, selection.from, "\n", "\n").length;
}

/** The text before `pos`, blocks joined by newlines. */
const plainOffset = (doc: ProseNode, pos: number) => doc.textBetween(0, pos, "\n", "\n").length;

/** The position in a textblock where the plain text reaches `offset`. */
function plainPosition(doc: ProseNode, offset: number): number {
  let low = 0;
  let high = doc.content.size;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (plainOffset(doc, middle) >= offset) high = middle;
    else low = middle + 1;
  }
  const resolved = doc.resolve(low);
  return resolved.parent.inlineContent ? low : TextSelection.near(resolved, 1).from;
}

/// The composer's prompt, edited inline as formatted markdown (spec S5, Milkdown): typing
/// `**bold**`, a backtick span, `- ` or a fence turns into the formatted node, with no toolbar
/// and no syntax reveal. Enter is the composer's (send or pick a command); Shift-Enter starts a
/// new block, a new list item inside a list. The composer reads and writes markdown through
/// `value` / `onChange`, so its slash menu, mention and draft logic stay as they were.
const MarkdownFieldImpl = React.forwardRef<MarkdownFieldHandle, MarkdownFieldProps>(function MarkdownFieldImpl(
  {
    value,
    onChange,
    onCaret,
    onKeyDown,
    onCompositionChange,
    onBeforeInput,
    onSubmit,
    onReturnInput,
    onFirstInput,
    onReady,
    onUnplacedQuotes,
    onInlineViews,
    isInlineAttachment,
    onCopy,
    onWholeSelection,
    onPasteFirst,
    plugins = [],
    multiline = true,
    literal = false,
    plainInput = false,
    placeholder,
    placeholderKey,
    className,
    attributes,
    selectionKey,
  },
  ref,
) {
  const pendingQuotes = useRef<string[]>([]);
  const editor = useRef<Editor | undefined>(undefined);
  const view = useRef<EditorView | undefined>(undefined);
  const remark = useRef<RemarkParser | undefined>(undefined);
  const literalNow = useRef(literal);
  literalNow.current = literal;
  const plainInputNow = useRef(plainInput || literal);
  plainInputNow.current = plainInput || literal;
  const richPlugins = useRef<readonly Plugin[]>([]);
  const literalKeys = useRef<Plugin | undefined>(undefined);
  literalKeys.current ??= keymap({
    ...baseKeymap,
    // Plain omnibar input still needs the browser's editing shortcuts. The rich keymap that
    // normally provides these is removed with formatting shortcuts in plain mode.
    "Mod-a": selectAll,
    "Shift-Enter": (state, dispatch, editorView) => !lines.current || baseKeymap.Enter!(state, dispatch, editorView),
    "Mod-z": undo,
    "Shift-Mod-z": redo,
    "Mod-y": redo,
  });
  const configureLiteral = useCallback(() => {
    const current = view.current;
    if (!current || !richPlugins.current.length) return;
    // Removing the input-rule plugin also disables its compositionend handler. Merely
    // intercepting handleTextInput leaves IME commits able to rewrite a shell command.
    const plugins = plainInputNow.current
      ? [
          ...richPlugins.current.filter((plugin) => {
            // keymap() creates only props.handleKeyDown. A plugin that also owns views,
            // state, or transactions is not a keymap: inlinePlugin needs its nodeViews,
            // copy normalization, and adjacent-attachment Backspace/Delete handler intact.
            const keymapOnly =
              plugin.props.handleKeyDown &&
              Object.keys(plugin.props).every((key) => key === "handleKeyDown") &&
              Object.keys(plugin.spec).every((key) => key === "props" || key === "key");
            return !plugin.spec.isInputRules && !keymapOnly;
          }),
          // Specialized handlers (such as deleting an adjacent attachment) run first.
          literalKeys.current!,
        ]
      : richPlugins.current;
    current.updateState(current.state.reconfigure({ plugins }));
  }, []);
  useLayoutEffect(configureLiteral, [configureLiteral, literal, plainInput]);
  // The markdown the field last emitted or applied; a different `value` comes from outside.
  const known = useRef(value);
  const latest = useRef({
    onChange,
    onCaret,
    onKeyDown,
    onCompositionChange,
    onBeforeInput,
    onSubmit,
    onReturnInput,
    onFirstInput,
    onReady,
    onUnplacedQuotes,
    onInlineViews,
    isInlineAttachment,
    onCopy,
    onWholeSelection,
    onPasteFirst,
  });
  latest.current = {
    onChange,
    onCaret,
    onKeyDown,
    onCompositionChange,
    onBeforeInput,
    onSubmit,
    onReturnInput,
    onFirstInput,
    onReady,
    onUnplacedQuotes,
    onInlineViews,
    isInlineAttachment,
    onCopy,
    onWholeSelection,
    onPasteFirst,
  };
  const composing = useRef(false);
  const touched = useRef(false);
  // Focus asked for before the editor exists is applied once it does.
  const pendingFocus = useRef(false);
  // The selection to put back when the field gets focus again without a click, and until when the
  // browser's own placement right after that focus is overruled (see `keepCaret`).
  // It belongs to the `selectionKey` it was kept under, not to the text: two chats can hold the same draft.
  const refocus = useRef<{ doc: ProseNode; selection: Selection; until: number; owner?: string } | null>(null);
  const owner = useRef(selectionKey);
  owner.current = selectionKey;
  const surfacePlugins = useRef(plugins);
  const lines = useRef(multiline);
  const empty = useRef<HTMLSpanElement>(null);
  const attrs = useRef(attributes);
  attrs.current = attributes;
  const applyAttributes = () => {
    const dom = view.current?.dom;
    if (!dom) return;
    for (const [name, attribute] of Object.entries(attrs.current ?? {}))
      if (attribute === undefined) dom.removeAttribute(name);
      else dom.setAttribute(name, attribute);
  };
  const showPlaceholder = (markdown: string) => {
    if (empty.current) empty.current.hidden = markdown !== "";
  };

  /// Asks the surface about typed or pasted text first; true when it consumed it.
  const beforeInput = (editorView: EditorView, text: string, paste = false) =>
    latest.current.onBeforeInput?.(text, {
      empty: editorView.state.doc.textContent === "",
      composing: composing.current || editorView.composing,
      paste,
    }) === true;

  // Each placed attachment's element (composer/inlineNode.ts), told to the composer once per task.
  const inlineViews = useRef(new Map<string, HTMLElement>());
  const inlineTold = useRef(false);
  const tellInlineViews = () => {
    if (inlineTold.current) return;
    inlineTold.current = true;
    queueMicrotask(() => {
      inlineTold.current = false;
      latest.current.onInlineViews?.(new Map(inlineViews.current));
    });
  };
  const inline = useRef({
    add: (id: string, dom: HTMLElement) => {
      inlineViews.current.set(id, dom);
      tellInlineViews();
    },
    remove: (id: string, dom: HTMLElement) => {
      if (inlineViews.current.get(id) !== dom) return;
      inlineViews.current.delete(id);
      tellInlineViews();
    },
  });
  const inlineKnown = (id: string) => latest.current.isInlineAttachment?.(id) ?? true;
  // Whether this field's editor was made with placed attachments (`placesInline` in `mount`).
  const inlineOn = useRef(false);
  /// A copy or cut the surface writes itself (`onCopy`): the field's own copy is skipped, and a cut's
  /// selection goes as one edit.
  const copied = (editorView: EditorView, event: ClipboardEvent, cut: boolean) => {
    const surface = latest.current.onCopy;
    const { state } = editorView;
    if (!surface || state.selection.empty) return false;
    const copy = {
      parts: inlineOn.current ? selectionParts(state) : [],
      text: copiedText(state.selection.content()),
      whole: wholeSelected(state),
    };
    if (!copy.parts.length && copy.text) copy.parts.push({ text: copy.text });
    if (!surface(copy, cut)) return false;
    event.preventDefault();
    // The text at once; the surface's own write (the host's, a moment later) replaces it whole.
    event.clipboardData?.setData("text/plain", copy.text);
    if (cut) editorView.dispatch(editorView.state.tr.deleteSelection().scrollIntoView().setMeta("uiEvent", "cut"));
    return true;
  };

  const mount = useCallback(
    (root: HTMLDivElement | null) => {
      if (!root) return;
      let disposed = false;
      // Placed attachments only in a field made with a place to draw them (`onInlineViews`): the
      // composer's, in either attachment view, so the view's switch never remakes the editor.
      const placesInline = latest.current.onInlineViews !== undefined;
      inlineOn.current = placesInline;
      // The value the editor's first document was made from: one given after it (a send cleared the
      // draft while the editor was still being made) is applied once it is made, empty too.
      let madeFrom: string | undefined;
      // A paste shows its end, the caret right after it (Leo 2026-10-20, as in Claude Code desktop).
      // Milkdown's clipboard plugin dispatches the paste without asking ProseMirror to scroll, so a
      // long paste left the field (it scrolls past eight lines) at the top. Set while a paste the
      // surface did not consume runs; the paste's dispatch is synchronous inside it.
      let pasting = false;
      // When the last composition ended (the event's timeStamp), for the Return that commits it.
      let compositionEndedAt = -Infinity;
      // Set from a passed-on Return the field took until its key comes up: the paragraph an input
      // method may still insert for that key is the same Return, not a second one.
      let returnTaken = false;
      // Whether the selection held the whole draft at the last update (`onWholeSelection`).
      let wholeNow = false;
      // A paste that ends the draft shows the field's whole end, its bottom inset too: the caret
      // reveal stops a margin short in WebKit, which would leave the last line under the bottom fade
      // (markdownField.css). Every paste path ends here.
      const showPastedEnd = (state: EditorState) => {
        if (Selection.atEnd(state.doc).to !== state.selection.to) return;
        requestAnimationFrame(() => {
          const field = root.parentElement;
          if (!disposed && field) field.scrollTop = field.scrollHeight;
        });
      };
      // Keys reach the composer first, as a textarea's keydown would.
      const composerKeys = $prose(
        () =>
          new Plugin({
            props: {
              handleDOMEvents: {
                keydown: (_view, event) => {
                  returnTaken = false;
                  latest.current.onKeyDown?.(event);
                  if (event.defaultPrevented) return true;
                  // Browser editing shortcuts must remain reliable in literal New Tab input.
                  // ProseMirror's keymap can be bypassed while the field is being reconfigured
                  // from rich to plain mode, so handle select-all at the composer boundary too.
                  const macPlatform = /Mac|iPhone|iPad|iPod/.test(globalThis.navigator?.platform ?? "");
                  const modA = event.metaKey || (event.ctrlKey && !macPlatform);
                  if (
                    plainInputNow.current &&
                    event.key.toLowerCase() === "a" &&
                    modA &&
                    !event.altKey &&
                    !event.shiftKey &&
                    !event.isComposing
                  ) {
                    event.preventDefault();
                    selectAll(_view.state, _view.dispatch);
                    return true;
                  }
                  // A Return an input method or Dictation passed on (keyCode 229) never reaches
                  // ProseMirror's keymap, which reads its key as Enter and splits the paragraph: in
                  // Leo's chat that line was all a dictated prompt's Return did (2026-10-21). The
                  // Return that commits a composition stays the input method's; any later one is
                  // Return, as the field's surface takes it.
                  const returnInput = latest.current.onReturnInput;
                  const plainReturn = !event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey;
                  if (returnInput && isImeKeyEvent(event) && isReturnKey(event) && plainReturn) {
                    if (event.isComposing || composing.current) return true;
                    // WebKit's commit Return, just after compositionend: ProseMirror's own keydown
                    // swallows it and clears its after-composition guard (imeKeys.ts). Kept from it,
                    // the guard stayed armed and took the next key, so a quick Shift-Return sent.
                    if (event.timeStamp - compositionEndedAt <= COMMIT_RETURN_MS) return false;
                    event.preventDefault();
                    returnTaken = true;
                    returnInput();
                    return true;
                  }
                  const submit = latest.current.onSubmit;
                  if (submit && event.key === "Enter" && !event.shiftKey && !event.altKey && !isImeKeyEvent(event)) {
                    event.preventDefault();
                    submit(known.current, { cmd: event.metaKey || event.ctrlKey });
                    return true;
                  }
                  return false;
                },
                // Shift-Return's line comes from the keymap (a transaction), never from this input.
                beforeinput: (_view, event) => {
                  const returnInput = latest.current.onReturnInput;
                  const input = event as InputEvent;
                  // Without a rich keymap, the browser can still implement Cmd-B itself.
                  if (
                    plainInputNow.current &&
                    (input.inputType.startsWith("format") ||
                      input.inputType === "insertOrderedList" ||
                      input.inputType === "insertUnorderedList")
                  ) {
                    event.preventDefault();
                    return true;
                  }
                  if (!returnInput || (input.inputType !== "insertParagraph" && input.inputType !== "insertLineBreak"))
                    return false;
                  event.preventDefault();
                  if (returnTaken) returnTaken = false;
                  else returnInput();
                  return true;
                },
                keyup: () => {
                  returnTaken = false;
                  return false;
                },
                compositionstart: () => {
                  composing.current = true;
                  latest.current.onCompositionChange?.(true);
                  return false;
                },
                compositionend: (_view, event) => {
                  compositionEndedAt = event.timeStamp;
                  composing.current = false;
                  latest.current.onCompositionChange?.(false);
                  return false;
                },
                // A paste that carries images (files, or a data: <img> in its HTML: Chrome's Copy Image
                // puts both; or `![…](data:…)` text, a prompt copied from a bubble that went out with
                // them) gives the field only its plain text without them: the composer attaches the
                // images as chips (its document paste listener). Left to ProseMirror (or Milkdown's
                // markdown paste), each became an image node drawn full size in the field and sent as
                // `![…](data:…)` text (Leo 2026-10-20).
                // Files copied in Finder also put their names on the clipboard as text: not a prompt.
                // With no text, ProseMirror would also move focus to a stand-in element for 50 ms to
                // capture the paste, and the keys typed then came back stripped of spaces.
                // A drop of text past what a prompt carries (a text drag, no files) goes to the surface
                // whole, as such a paste does, before ProseMirror lays every line of it out (Leo,
                // 2026-10-25: "the composer should never ever freeze"). Smaller drops are ProseMirror's.
                drop: (editorView, event) => {
                  const data = event.dataTransfer;
                  // A drag from inside the field moves its own text, as ProseMirror does.
                  if (editorView.dragging) return false;
                  if (!data) return false;
                  if (literalNow.current) {
                    if (data.files.length || [...data.types].includes("Files")) return false;
                    const text = data.getData("text/plain");
                    if (!text) return false;
                    const at = editorView.posAtCoords({ left: event.clientX, top: event.clientY });
                    if (at)
                      editorView.dispatch(
                        editorView.state.tr.setSelection(TextSelection.near(editorView.state.doc.resolve(at.pos))),
                      );
                    insertPlain(editorView, text);
                    event.preventDefault();
                    return true;
                  }
                  const files = data.files.length > 0 || [...data.types].includes("Files");
                  const whole = files ? "" : data.getData("text/plain");
                  if (files ? !inlineOn.current || !latest.current.onInlineViews : whole.length <= PASTE_FILE_CHARS)
                    return false;
                  // Intake places its pending atom at the selection synchronously. A drop belongs at
                  // the pointer, never over text selected elsewhere before the drag started.
                  const at = editorView.posAtCoords({ left: event.clientX, top: event.clientY });
                  if (at) {
                    const tr = editorView.state.tr;
                    tr.setSelection(TextSelection.near(tr.doc.resolve(at.pos)));
                    editorView.dispatch(tr);
                  }
                  if (!files && !beforeInput(editorView, whole, true)) return false;
                  // File intake listens on the document: leave propagation intact, but keep
                  // ProseMirror from also inserting the file's text/HTML payload.
                  event.preventDefault();
                  return true;
                },
                // A copy of a selection with attachments in it is the surface's: it puts the text and
                // the attachments on the pasteboard together (Leo, 2026-11-01: "select all in
                // composer which also selects all the attachments as the copy as well").
                copy: (editorView, event) => copied(editorView, event, false),
                cut: (editorView, event) => copied(editorView, event, true),
                paste: (editorView, event) => {
                  if (latest.current.onPasteFirst?.(event)) {
                    event.preventDefault();
                    return true;
                  }
                  const data = event.clipboardData;
                  if (!data) return false;
                  if (literalNow.current) {
                    const text = data.getData("text/plain") || htmlText(data.getData("text/html"));
                    if (text) insertPlain(editorView, text);
                    event.preventDefault();
                    showPastedEnd(editorView.state);
                    return true;
                  }
                  // Text past what a prompt carries goes to the surface whole, before anything reads
                  // or parses it (ProseMirror would lay out every line of it first): the composer
                  // attaches it as a file (pastedText.ts PASTE_FILE_CHARS).
                  const whole = data.getData("text/plain");
                  // A surface without a file intake (Home Channels) takes it as before.
                  if (whole.length > PASTE_FILE_CHARS && !data.files.length && beforeInput(editorView, whole, true)) {
                    event.preventDefault();
                    return true;
                  }
                  const lifted = liftInlineImages(whole);
                  if (!data.files.length && !htmlHasDataImage(data.getData("text/html")) && !lifted.attachments.length)
                    return false;
                  event.preventDefault();
                  // The picture itself is on the clipboard (a file, or a data: <img>): the `![…](…)`
                  // a browser or the transcript copies beside it is only markup for it, never text.
                  const carriesImage =
                    [...data.files].some((file) => file.type.startsWith("image/")) ||
                    htmlHasDataImage(data.getData("text/html"));
                  const plain = pasteIsOnlyFileNames(data)
                    ? ""
                    : carriesImage
                      ? withoutMarkdownImages(lifted.text)
                      : lifted.text;
                  if (!plain.trim() || beforeInput(editorView, plain, true)) return true;
                  insertPlain(editorView, plain);
                  showPastedEnd(editorView.state);
                  return true;
                },
              },
              handleTextInput: (editorView, _from, _to, text) => beforeInput(editorView, text),
              handlePaste: (editorView, event, slice) => {
                if (literalNow.current) {
                  const data = event.clipboardData;
                  const text = data?.getData("text/plain") || htmlText(data?.getData("text/html") ?? "");
                  if (text) insertPlain(editorView, text);
                  showPastedEnd(editorView.state);
                  return true;
                }
                // A copy of the prompt's own text with an attachment placed in it carries that
                // attachment (its node, by id); the rest of a paste is its plain text.
                if (placesInline && sliceHoldsInline(slice)) {
                  editorView.dispatch(editorView.state.tr.replaceSelection(slice).scrollIntoView());
                  return true;
                }
                // A paste is its plain text, as copied: with HTML too, the plain text wins, and HTML
                // alone goes in as its text. Left to Milkdown, a plain paste was parsed as markdown
                // (its `<br />` blank-line placeholder, HTML or JSX source went in as typed tags) and
                // an HTML one as rich nodes (Leo 2026-10-21: "line breaks ... as <br />").
                // VS Code's paste is Milkdown's (a code block in its language).
                const data = event.clipboardData;
                if (data && !data.getData("vscode-editor-data")) {
                  const html = data.getData("text/html");
                  const text = data.getData("text/plain");
                  const plain = text ? withoutBreakPlaceholders(text) : html ? htmlText(html) : "";
                  if (plain) {
                    if (beforeInput(editorView, plain, true)) return true;
                    insertPlain(editorView, plain);
                    showPastedEnd(editorView.state);
                    return true;
                  }
                }
                const plain = data?.getData("text/plain");
                // The surface sees the text as copied (a huge paste becomes the composer's chip as it
                // was), else the slice's text (a paste of HTML only).
                if (
                  beforeInput(editorView, plain || slice.content.textBetween(0, slice.content.size, "\n", "\n"), true)
                )
                  return true;
                pasting = true;
                queueMicrotask(() => {
                  pasting = false;
                });
                return false;
              },
            },
            // Whichever plugin inserts the paste (Milkdown's or ProseMirror's own), the selection ends
            // after the pasted content; this scrolls the field to it.
            appendTransaction: (transactions, _previous, state) => {
              if (!pasting || !transactions.some((tr) => tr.docChanged)) return null;
              pasting = false;
              showPastedEnd(state);
              return transactions.some((tr) => tr.scrolledIntoView) ? null : state.tr.scrollIntoView();
            },
            // Report every document and caret change; the composer's menu follows the caret.
            view: () => ({
              update: (next, previous) => {
                const whole = wholeSelected(next.state);
                if (whole !== wholeNow) {
                  wholeNow = whole;
                  latest.current.onWholeSelection?.(whole);
                }
                if (next.state.doc.eq(previous.doc)) {
                  if (!next.state.selection.eq(previous.selection)) latest.current.onCaret?.(caretOf(next));
                  return;
                }
                // Before the editor is made there is nothing to write the document with (it would read
                // as an empty prompt and wipe the draft); the document made is `known` then.
                if (!editor.current) return;
                const markdown = promptMarkdown(editor.current, next, inlineOn.current);
                showPlaceholder(markdown);
                // A value applied from outside comes back unchanged: not the user's edit.
                if (markdown === known.current) return;
                known.current = markdown;
                if (!touched.current) {
                  touched.current = true;
                  latest.current.onFirstInput?.();
                }
                latest.current.onChange(markdown, caretOf(next));
              },
            }),
          }),
      );
      // WebKit clears the selection when the web view gives the keyboard to the app (another pane,
      // tab or workspace, the palette) and, taking it back, puts a contenteditable's caret at its
      // start; ProseMirror took that as the person's caret, and the next keys landed at the front. A
      // textarea gets its selection back. So does the field now: a focus that no click placed puts
      // back the selection it had, also over a placement the browser makes just after the focus.
      const keepCaret = $prose(() => {
        const caretAtStart = ({ doc, selection }: EditorState) =>
          selection.empty && selection.from === Selection.atStart(doc).from;
        const kept = (state: EditorState) => {
          const saved = refocus.current;
          if (!saved || saved.owner !== owner.current || !state.doc.eq(saved.doc)) return null;
          // The same document: the saved selection (text, node or all) holds as it was.
          const selection = Selection.fromJSON(state.doc, saved.selection.toJSON());
          return selection.eq(state.selection) ? null : selection;
        };
        const leave = (editorView: EditorView) => {
          const { doc, selection } = editorView.state;
          refocus.current = { doc, selection, until: 0, owner: owner.current };
        };
        const enter = (editorView: EditorView) => {
          if (!refocus.current) return;
          refocus.current.until = performance.now() + KEEP_CARET_MS;
          const selection = kept(editorView.state);
          if (selection) editorView.dispatch(editorView.state.tr.setSelection(selection));
        };
        // The web view letting go of the keyboard may blur only the window, the editor keeping focus.
        const focused = (editorView: EditorView) => editorView.dom.contains(document.activeElement);
        return new Plugin({
          view: (editorView) => {
            const windowBlur = () => {
              if (focused(editorView)) leave(editorView);
            };
            const windowFocus = () => {
              if (focused(editorView)) enter(editorView);
            };
            // The editor's own window, kept: the editor can be torn down after the page's global
            // `window` is gone (a test's DOM unregistered before Milkdown's async destroy runs).
            const win = editorView.dom.ownerDocument.defaultView;
            win?.addEventListener("blur", windowBlur);
            win?.addEventListener("focus", windowFocus);
            return {
              destroy: () => {
                win?.removeEventListener("blur", windowBlur);
                win?.removeEventListener("focus", windowFocus);
              },
            };
          },
          props: {
            handleDOMEvents: {
              mousedown: () => {
                refocus.current = null;
                return false;
              },
              keydown: () => {
                refocus.current = null;
                return false;
              },
              blur: (editorView) => {
                leave(editorView);
                return false;
              },
              focus: (editorView) => {
                enter(editorView);
                return false;
              },
            },
          },
          appendTransaction: (transactions, _previous, state) => {
            const saved = refocus.current;
            if (!saved) return null;
            const docChanged = transactions.some((tr) => tr.docChanged);
            if (performance.now() > saved.until) {
              // Past the window only WebKit's caret at the start is overruled: it comes after the
              // focus, as a selectionchange that a busy page (an inbound message drawing) takes well
              // past 100 ms to deliver (Leo 2026-10-21, after another agent's steer). The person's own
              // move there comes with a key or a click, which drop the saved selection first.
              if (docChanged || !caretAtStart(state)) return null;
            } else if (docChanged) {
              refocus.current = null;
              return null;
            }
            const selection = kept(state);
            return selection ? state.tr.setSelection(selection) : null;
          },
        });
      });
      const blockKeys = $prose(() =>
        keymap({
          // Milkdown replaces the base Backspace's joinBackward with joinTextblockBackward,
          // which cannot lift a quote at the document's start and joins one into prior text.
          // Lift its first paragraph instead, preserving text and the paragraph boundary.
          Backspace: (state, dispatch) => {
            const { selection } = state;
            if (!(selection instanceof TextSelection) || !selection.empty) return false;
            const { $from } = selection;
            if (
              $from.depth < 2 ||
              $from.parentOffset !== 0 ||
              $from.parent.type !== state.schema.nodes.paragraph ||
              $from.node(-1).type !== state.schema.nodes.blockquote ||
              $from.index(-1) !== 0
            )
              return false;
            return lift(state, dispatch);
          },
          "Shift-Enter": (state, dispatch, editorView) => {
            if (!lines.current) return true;
            const item = state.schema.nodes.list_item;
            const enter = baseKeymap.Enter!;
            return chainCommands(...(item ? [splitListItem(item), enter] : [enter]))(state, dispatch, editorView);
          },
        }),
      );
      void Editor.make()
        .config((ctx) => {
          ctx.set(rootCtx, root);
          madeFrom = known.current;
          ctx.set(defaultValueCtx, madeFrom);
          ctx.update(remarkStringifyOptionsCtx, (options) => ({
            ...options,
            bullet: "-" as const,
            emphasis: "*" as const,
          }));
          // The field fills a box (the composer, a prompt editor) and its caret shows focus: a text
          // field is :focus-visible on every focus, so desktop.css's ring drew a rectangle inside it.
          // The scroll margin covers the field's own padding and the fade band at a scrolled edge, so a
          // long draft scrolls the caret's whole line into view, clear of the fade.
          ctx.update(editorViewOptionsCtx, (options) => ({
            ...options,
            attributes: { class: "acpmux-md", "data-focus-ring": "none" },
            // A copy's plain text is the lines as shown, not Milkdown's markdown (which writes a blank
            // line as `<br />`); a view prop, so it comes before the clipboard plugin's.
            clipboardTextSerializer: copiedText,
            scrollMargin: FADE_BAND_PX,
          }));
        })
        .use(composerKeys)
        .use(surfacePlugins.current.map((plugin) => $prose(() => plugin)))
        .use(keepCaret)
        // A rewrap with no edit (the actions' width, a resize) keeps the caret in view too.
        .use($prose(() => caretInView(FADE_BAND_PX)))
        .use(blockKeys)
        .use(commonmark)
        .use(gfm)
        .use(history)
        .use(clipboard)
        .use(placesInline ? [inlineAttachmentNode, inlinePlugin(inline.current)] : [])
        .create()
        .then((made) => {
          if (disposed) {
            void made.destroy();
            return;
          }
          editor.current = made;
          view.current = made.ctx.get(editorViewCtx);
          richPlugins.current = view.current.state.plugins;
          configureLiteral();
          remark.current = made.ctx.get(remarkCtx);
          if (known.current || known.current !== madeFrom) setDocument(known.current, false);
          showPlaceholder(known.current);
          applyAttributes();
          for (const quote of pendingQuotes.current.splice(0)) insertReplyQuote(made, view.current, quote);
          if (pendingFocus.current) view.current.focus();
          latest.current.onReady?.();
          window.dispatchEvent(new window.Event(COMPOSER_READY_EVENT));
        });
      return () => {
        disposed = true;
        // A quote taken while the editor was being made goes back to the owner, not with the field.
        const unplaced = pendingQuotes.current.splice(0);
        if (unplaced.length) latest.current.onUnplacedQuotes?.(unplaced);
        void editor.current?.destroy();
        editor.current = undefined;
        view.current = undefined;
        remark.current = undefined;
        richPlugins.current = [];
      };
    },
    [configureLiteral],
  );

  /// Replaces the document with `markdown`. Parsing drops the spaces at its end ("/review "),
  /// so they go back where the caret goes. It drops a blank line at its end too: after a block
  /// that is not a paragraph (a quote put in for the reply), an empty paragraph takes the caret,
  /// so typing goes on below the block, not inside it.
  const setDocument = (markdown: string, undoable = true) => {
    // A field with placed attachments reads the value's tokens as their nodes in the same edit
    // (composer/inlineNode.ts placeTokensIn): undo and redo bring back nodes, and token text typed
    // or pasted is never read so. The editor's first document (`undoable` false) is not an edit to
    // undo: undo would bring back the tokens it was made with as text.
    if (inlineOn.current)
      editor.current?.action((ctx) => {
        const parsed = ctx.get(parserCtx)(markdown);
        const current = ctx.get(editorViewCtx);
        if (!parsed) return;
        const { tr, doc } = current.state;
        tr.replace(0, doc.content.size, new Slice(parsed.content, 0, 0));
        current.dispatch(placeTokensIn(tr, inlineKnown).setMeta("addToHistory", undoable));
      });
    else editor.current?.action(replaceAll(markdown));
    const current = view.current;
    if (!current) return;
    const tail = /[ \t]+$/.exec(markdown)?.[0];
    if (tail && !trailingSpaces(current)) {
      current.dispatch(current.state.tr.insertText(tail, current.state.doc.content.size - 1));
      return;
    }
    const { doc, schema } = current.state;
    if (!/\n[ \t]*\n$/.test(markdown) || !doc.lastChild || doc.lastChild.type === schema.nodes.paragraph) return;
    const tr = current.state.tr.insert(doc.content.size, schema.nodes.paragraph.create());
    current.dispatch(tr.setSelection(TextSelection.create(tr.doc, tr.doc.content.size - 1)));
  };

  // A value from outside (a send cleared it, the menu wrote a command) replaces the document.
  useLayoutEffect(() => {
    if (value === known.current) return;
    // Before the editor exists the new value becomes its default content.
    known.current = value;
    if (!editor.current) return;
    setDocument(value);
  }, [value]);
  // Aria and role follow the composer's state on the editable element.
  useLayoutEffect(applyAttributes);

  const wrapper = useRef<HTMLDivElement | null>(null);
  // A long draft scrolls inside this box past its cap (markdownField.css): the edge with more draft
  // past it is marked, and the CSS fades it (Leo 2026-10-21). A DOM with no layout (the jsdom and
  // happy-dom unit tests) has no observers and nothing scrolls there.
  useEffect(
    () =>
      wrapper.current && typeof ResizeObserver === "function" && typeof MutationObserver === "function"
        ? followScrollEdges(wrapper.current)
        : undefined,
    [],
  );
  // In the composer's box, its scrollbar runs down the box's right edge, clear of the actions
  // (composerScrollLane.ts).
  useEffect(
    () => (wrapper.current && typeof ResizeObserver === "function" ? followActionsWidth(wrapper.current) : undefined),
    [],
  );
  // Under the scrollbar fade (agentPane.debug.scrollerFade, on by default since Lawrence 2026-10-23)
  // a long draft's thumb fades in and out with the scrolling marks, as the transcript's does.
  useEffect(() => (wrapper.current ? followShownScrollerFade(wrapper.current) : undefined), []);
  const handle = useRef<MarkdownFieldHandle>(undefined);
  useImperativeHandle(
    ref,
    () =>
      (handle.current = {
        focus: () => {
          if (view.current) view.current.focus();
          else pendingFocus.current = true;
        },
        setCaret: (offset) => {
          const current = view.current;
          if (!current) return;
          refocus.current = null;
          const { doc } = current.state;
          const first = doc.firstChild;
          // Inside the first paragraph when it is one; past a longer offset (or another block), the end.
          const inside = first?.isTextblock && offset <= first.content.size;
          const at = inside ? 1 + Math.max(0, offset) : doc.content.size;
          current.dispatch(current.state.tr.setSelection(TextSelection.near(doc.resolve(at), inside ? 1 : -1)));
        },
        value: () => known.current,
        caret: () => (view.current ? caretOf(view.current) : 0),
        type: (markdown) => {
          if (!editor.current) return false;
          refocus.current = null;
          // Not `known`: the view plugin reports the change as the user's.
          setDocument(markdown);
          const current = view.current;
          if (current) {
            const end = current.state.doc.content.size;
            current.dispatch(current.state.tr.setSelection(TextSelection.near(current.state.doc.resolve(end), -1)));
          }
          return true;
        },
        quoteReply: (markdown) => {
          const made = editor.current,
            current = view.current;
          refocus.current = null;
          if (!made || !current) {
            pendingQuotes.current.push(markdown);
            pendingFocus.current = true;
            return true;
          }
          insertReplyQuote(made, current, markdown);
          return true;
        },
        text: () => {
          const current = view.current;
          if (!current) return { value: known.current, selectionStart: 0, selectionEnd: 0 };
          const { doc, selection } = current.state;
          return {
            value: doc.textBetween(0, doc.content.size, "\n", "\n"),
            selectionStart: plainOffset(doc, selection.from),
            selectionEnd: plainOffset(doc, selection.to),
          };
        },
        atStart: () => {
          const current = view.current;
          if (!current) return false;
          const { doc, selection } = current.state;
          const { $from } = selection;
          return (
            selection.empty &&
            selection.from === Selection.atStart(doc).from &&
            $from.depth === 1 &&
            $from.parent.type.name === "paragraph"
          );
        },
        writeText: (value, selectionStart, selectionEnd) => {
          const current = view.current;
          if (!current) return;
          refocus.current = null;
          const { doc } = current.state;
          const old = doc.textBetween(0, doc.content.size, "\n", "\n");
          // Only the span that changed is replaced, so formatting around it stays.
          let head = 0;
          while (head < old.length && head < value.length && old[head] === value[head]) head += 1;
          let tail = 0;
          while (
            tail < old.length - head &&
            tail < value.length - head &&
            old[old.length - 1 - tail] === value[value.length - 1 - tail]
          )
            tail += 1;
          const tr = current.state.tr;
          if (old !== value) {
            const from = plainPosition(doc, head);
            const to = Math.max(from, plainPosition(doc, old.length - tail));
            const inserted = value.slice(head, value.length - tail);
            if (inserted) tr.insertText(inserted, from, to);
            else tr.delete(from, to);
          }
          const anchor = plainPosition(tr.doc, selectionStart);
          const focus = plainPosition(tr.doc, selectionEnd);
          tr.setSelection(TextSelection.create(tr.doc, anchor, focus));
          current.dispatch(tr);
        },
        focused: () => view.current?.hasFocus() ?? false,
        history: () => {
          const state = view.current?.state;
          return { undo: state ? undoDepth(state) > 0 : false, redo: state ? redoDepth(state) > 0 : false };
        },
        undo: () => {
          if (view.current) undo(view.current.state, view.current.dispatch);
        },
        redo: () => {
          if (view.current) redo(view.current.state, view.current.dispatch);
        },
        selectAll: () => {
          refocus.current = null;
          if (view.current) selectAll(view.current.state, view.current.dispatch);
        },
        insertText: (text) => {
          if (!view.current || !text) return;
          refocus.current = null;
          insertPlain(view.current, text);
        },
        insertInline: (ids) => {
          if (!view.current) return false;
          refocus.current = null;
          return insertInline(view.current, ids);
        },
        removeInline: (id, caret) => {
          if (view.current) removeInline(view.current, id, caret);
        },
        inlineIds: () => (view.current ? inlineIds(view.current.state.doc) : undefined),
        orderInline: (ids) => {
          if (view.current) orderInline(view.current, ids);
        },
        element: () => wrapper.current,
        plainText: () => {
          const doc = view.current?.state.doc;
          return doc ? doc.textBetween(0, doc.content.size, "\n", "\n") : known.current;
        },
        insertTyped: (text) => {
          const current = view.current;
          if (!current) return;
          const { from, to } = current.state.selection;
          if (beforeInput(current, text)) return;
          current.dispatch(current.state.tr.insertText(text, from, to));
        },
        pasteText: (text) => {
          const current = view.current;
          if (!current) return;
          if (beforeInput(current, text, true)) return;
          // A paste event that carries `text` as the clipboard's plain text, so the paste takes the
          // path a person's does (Milkdown's markdown paste: blank lines kept, lines not split into
          // paragraphs). Plain data, not a DataTransfer: jsdom has neither it nor ClipboardEvent.
          const event = new Event("paste");
          Object.defineProperty(event, "clipboardData", {
            value: {
              types: ["text/plain"],
              files: [],
              getData: (type: string) => (type === "text/plain" || type === "Text" ? text : ""),
            },
          });
          current.pasteText(text, event as ClipboardEvent);
        },
        reset: (markdown = "") => {
          known.current = markdown;
          showPlaceholder(markdown);
          if (editor.current) setDocument(markdown);
        },
        // Before the editor exists nothing was typed: the value is what came in.
        agentText: (markdown) => (remark.current ? typedText(remark.current, markdown) : markdown),
        format: (format, href) => {
          if (editor.current && view.current) applyFormat(editor.current, view.current, format, href);
        },
        formats: () => (view.current ? activeFormats(view.current.state) : new Set()),
      }),
    [],
  );

  return (
    <div
      className={`acpmux-md-field ${className ?? ""}`}
      // A long draft's thin scrollbar (scrollers.ts): kept while it overflows, or under the fade
      // shown while it scrolls and while the pointer is near its edge.
      {...{ [MINIMAL_SCROLLER_ATTRIBUTE]: "" }}
      style={{ "--acpmux-md-fade-band": `${FADE_BAND_PX}px` } as React.CSSProperties}
      ref={(element: MarkdownFieldElement | null) => {
        wrapper.current = element;
        // A getter: the handle is made after this element attaches.
        if (element)
          Object.defineProperty(element, "acpmuxMarkdownField", { get: () => handle.current, configurable: true });
      }}
    >
      <span
        ref={empty}
        className={placeholderKey ? "acpmux-md-placeholder has-key" : "acpmux-md-placeholder"}
        aria-hidden="true"
      >
        {placeholderKey ? <span className="acpmux-md-placeholder-text">{placeholder}</span> : placeholder}
        {placeholderKey && <kbd className="acpmux-md-placeholder-key">{placeholderKey}</kbd>}
      </span>
      <div ref={mount} className="acpmux-md-root" />
    </div>
  );
});

export const MarkdownField = React.memo(MarkdownFieldImpl, sameMarkdownFieldProps);
