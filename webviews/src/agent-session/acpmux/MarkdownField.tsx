import React, { useCallback, useImperativeHandle, useLayoutEffect, useRef } from "react";
import { COMPOSER_READY_EVENT } from "./composerFocus";
import {
  Editor,
  defaultValueCtx,
  editorViewCtx,
  editorViewOptionsCtx,
  remarkStringifyOptionsCtx,
  rootCtx,
} from "@milkdown/kit/core";
import { commonmark } from "@milkdown/kit/preset/commonmark";
import { gfm } from "@milkdown/kit/preset/gfm";
import { history } from "@milkdown/kit/plugin/history";
import { clipboard } from "@milkdown/kit/plugin/clipboard";
import { baseKeymap, chainCommands } from "@milkdown/kit/prose/commands";
import { keymap } from "@milkdown/kit/prose/keymap";
import { splitListItem } from "@milkdown/kit/prose/schema-list";
import { Plugin, TextSelection } from "@milkdown/kit/prose/state";
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import type { EditorView } from "@milkdown/kit/prose/view";
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

/** The document as the prompt's markdown, keeping the spaces typed at its end. */
function promptMarkdown(editor: Editor | undefined, view: EditorView): string {
  const markdown = clean(editor?.action(getMarkdown()) ?? "");
  const tail = trailingSpaces(view);
  return tail && !markdown.endsWith(tail) ? markdown + tail : markdown;
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
                if (submit && event.key === "Enter" && !event.shiftKey && !event.altKey && !event.isComposing) {
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
            },
            handleTextInput: (editorView, _from, _to, text) => beforeInput(editorView, text),
            handlePaste: (editorView, _event, slice) =>
              beforeInput(editorView, slice.content.textBetween(0, slice.content.size, "\n", "\n")),
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
        ctx.update(editorViewOptionsCtx, (options) => ({ ...options, attributes: { class: "acpmux-md" } }));
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
    };
  }, []);

  /// Replaces the document with `markdown`. Parsing drops the spaces at its end ("/review "),
  /// so they go back where the caret goes.
  const setDocument = (markdown: string) => {
    editor.current?.action(replaceAll(markdown));
    const current = view.current;
    const tail = /[ \t]+$/.exec(markdown)?.[0];
    if (current && tail && !trailingSpaces(current))
      current.dispatch(current.state.tr.insertText(tail, current.state.doc.content.size - 1));
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
