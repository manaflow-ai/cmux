import React, { useCallback, useImperativeHandle, useLayoutEffect, useRef } from "react";
import { COMPOSER_READY_EVENT } from "./composerFocus";
import { isImeKeyEvent } from "../../pages/shared/imeKeys";
import { activeFormats, applyFormat, type MarkdownFormat } from "./markdownFormat";
import "./markdownField.css";
import {
  Editor,
  defaultValueCtx,
  editorViewCtx,
  editorViewOptionsCtx,
  remarkCtx,
  remarkStringifyOptionsCtx,
  rootCtx,
} from "@milkdown/kit/core";
import { commonmark } from "@milkdown/kit/preset/commonmark";
import { gfm } from "@milkdown/kit/preset/gfm";
import { history } from "@milkdown/kit/plugin/history";
import { clipboard } from "@milkdown/kit/plugin/clipboard";
import { baseKeymap, chainCommands, selectAll } from "@milkdown/kit/prose/commands";
import { redo, redoDepth, undo, undoDepth } from "@milkdown/kit/prose/history";
import { keymap } from "@milkdown/kit/prose/keymap";
import { splitListItem } from "@milkdown/kit/prose/schema-list";
import { Plugin, TextSelection } from "@milkdown/kit/prose/state";
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
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
  type(markdown: string): void;
  /// The prompt as plain text (blocks joined by newlines) and the selection's offsets into it,
  /// for dictation, which splices words at the cursor.
  text(): PlainPrompt;
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
  /// Typed or pasted text before the editor inserts it, and whether the prompt was empty and an
  /// IME composition runs; true consumes it (the new tab's "!" rule converts the tab instead).
  onBeforeInput?(data: string, state: { empty: boolean; composing: boolean }): boolean;
  /// Enter (with `cmd` for Cmd-Enter) that `onKeyDown` did not take; unset, Enter is the editor's.
  onSubmit?(markdown: string, modifiers: { cmd: boolean }): void;
  /// The user's first edit (the new tab's `newTab.touched`).
  onFirstInput?(): void;
  /// The surface's own key handling, which runs before the editor's keys (the omnibar word rules).
  plugins?: Plugin[];
  /// Shift-Enter adds a line (default true).
  multiline?: boolean;
  placeholder?: string;
  className?: string;
  /// Attributes for the editable element (aria-label, role=combobox, aria-expanded...).
  attributes?: Record<string, string | undefined>;
};

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

/** HTML/JSX copied from a code editor is plain text, even when its clipboard advertises HTML. */
const looksLikeMarkupText = (text: string) => /<>|<\/?[A-Za-z][\w.-]*(?:\s[^<>]*)?\/?>(?=\s|$|[.,;:!?)]|<)/.test(text);

/** The document as the prompt's markdown, keeping the spaces typed at its end. */
function promptMarkdown(editor: Editor | undefined, view: EditorView): string {
  const markdown = clean(editor?.action(getMarkdown()) ?? "");
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
  const tree = remark.runSync(remark.parse(markdown), markdown) as unknown as MdNode;
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
export const MarkdownField = React.forwardRef<MarkdownFieldHandle, MarkdownFieldProps>(function MarkdownField(
  {
    value,
    onChange,
    onCaret,
    onKeyDown,
    onCompositionChange,
    onBeforeInput,
    onSubmit,
    onFirstInput,
    plugins = [],
    multiline = true,
    placeholder,
    className,
    attributes,
  },
  ref,
) {
  const editor = useRef<Editor | undefined>(undefined);
  const view = useRef<EditorView | undefined>(undefined);
  const remark = useRef<RemarkParser | undefined>(undefined);
  // The markdown the field last emitted or applied; a different `value` comes from outside.
  const known = useRef(value);
  const latest = useRef({ onChange, onCaret, onKeyDown, onCompositionChange, onBeforeInput, onSubmit, onFirstInput });
  latest.current = { onChange, onCaret, onKeyDown, onCompositionChange, onBeforeInput, onSubmit, onFirstInput };
  const composing = useRef(false);
  const touched = useRef(false);
  // Focus asked for before the editor exists is applied once it does.
  const pendingFocus = useRef(false);
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
  const beforeInput = (editorView: EditorView, text: string) =>
    latest.current.onBeforeInput?.(text, {
      empty: editorView.state.doc.textContent === "",
      composing: composing.current || editorView.composing,
    }) === true;

  const mount = useCallback((root: HTMLDivElement | null) => {
    if (!root) return;
    let disposed = false;
    // Keys reach the composer first, as a textarea's keydown would.
    const composerKeys = $prose(
      () =>
        new Plugin({
          props: {
            handleDOMEvents: {
              keydown: (_view, event) => {
                latest.current.onKeyDown?.(event);
                if (event.defaultPrevented) return true;
                const submit = latest.current.onSubmit;
                if (submit && event.key === "Enter" && !event.shiftKey && !event.altKey && !isImeKeyEvent(event)) {
                  event.preventDefault();
                  submit(known.current, { cmd: event.metaKey || event.ctrlKey });
                  return true;
                }
                return false;
              },
              compositionstart: () => {
                composing.current = true;
                latest.current.onCompositionChange?.(true);
                return false;
              },
              compositionend: () => {
                composing.current = false;
                latest.current.onCompositionChange?.(false);
                return false;
              },
              // A paste of only files (images) has no text for the field: the composer attaches them
              // (its document paste listener). ProseMirror would move focus to a stand-in element
              // for 50 ms to capture it, and the keys typed then came back stripped of spaces.
              paste: (_view, event) => {
                const data = event.clipboardData;
                if (!data?.files.length || data.getData("text/plain") || data.getData("text/html")) return false;
                event.preventDefault();
                return true;
              },
            },
            handleTextInput: (editorView, _from, _to, text) => beforeInput(editorView, text),
            handlePaste: (editorView, event, slice) => {
              const plain = event.clipboardData?.getData("text/plain");
              if (plain && looksLikeMarkupText(plain)) {
                if (beforeInput(editorView, plain)) return true;
                const { from, to } = editorView.state.selection;
                editorView.dispatch(editorView.state.tr.insertText(plain, from, to));
                return true;
              }
              return beforeInput(editorView, slice.content.textBetween(0, slice.content.size, "\n", "\n"));
            },
          },
          // Report every document and caret change; the composer's menu follows the caret.
          view: () => ({
            update: (next, previous) => {
              if (next.state.doc.eq(previous.doc)) {
                if (!next.state.selection.eq(previous.selection)) latest.current.onCaret?.(caretOf(next));
                return;
              }
              const markdown = promptMarkdown(editor.current, next);
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
    const blockKeys = $prose(() =>
      keymap({
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
        ctx.set(defaultValueCtx, known.current);
        ctx.update(remarkStringifyOptionsCtx, (options) => ({
          ...options,
          bullet: "-" as const,
          emphasis: "*" as const,
        }));
        // The field fills a box (the composer, a prompt editor) and its caret shows focus: a text
        // field is :focus-visible on every focus, so desktop.css's ring drew a rectangle inside it.
        ctx.update(editorViewOptionsCtx, (options) => ({
          ...options,
          attributes: { class: "acpmux-md", "data-focus-ring": "none" },
        }));
      })
      .use(composerKeys)
      .use(surfacePlugins.current.map((plugin) => $prose(() => plugin)))
      .use(blockKeys)
      .use(commonmark)
      .use(gfm)
      .use(history)
      .use(clipboard)
      .create()
      .then((made) => {
        if (disposed) {
          void made.destroy();
          return;
        }
        editor.current = made;
        view.current = made.ctx.get(editorViewCtx);
        remark.current = made.ctx.get(remarkCtx);
        if (known.current) setDocument(known.current);
        showPlaceholder(known.current);
        applyAttributes();
        if (pendingFocus.current) view.current.focus();
        window.dispatchEvent(new window.Event(COMPOSER_READY_EVENT));
      });
    return () => {
      disposed = true;
      void editor.current?.destroy();
      editor.current = undefined;
      view.current = undefined;
      remark.current = undefined;
    };
  }, []);

  /// Replaces the document with `markdown`. Parsing drops the spaces at its end ("/review "),
  /// so they go back where the caret goes. It drops a blank line at its end too: after a block
  /// that is not a paragraph (a quote put in for the reply), an empty paragraph takes the caret,
  /// so typing goes on below the block, not inside it.
  const setDocument = (markdown: string) => {
    editor.current?.action(replaceAll(markdown));
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
          if (!editor.current) return;
          // Not `known`: the view plugin reports the change as the user's.
          setDocument(markdown);
          const current = view.current;
          if (current) {
            const end = current.state.doc.content.size;
            current.dispatch(current.state.tr.setSelection(TextSelection.near(current.state.doc.resolve(end), -1)));
          }
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
        writeText: (value, selectionStart, selectionEnd) => {
          const current = view.current;
          if (!current) return;
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
          if (view.current) selectAll(view.current.state, view.current.dispatch);
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
          if (beforeInput(current, text)) return;
          current.pasteText(text);
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
      ref={(element: MarkdownFieldElement | null) => {
        wrapper.current = element;
        // A getter: the handle is made after this element attaches.
        if (element)
          Object.defineProperty(element, "acpmuxMarkdownField", { get: () => handle.current, configurable: true });
      }}
    >
      <span ref={empty} className="acpmux-md-placeholder" aria-hidden="true">
        {placeholder}
      </span>
      <div ref={mount} className="acpmux-md-root" />
    </div>
  );
});
