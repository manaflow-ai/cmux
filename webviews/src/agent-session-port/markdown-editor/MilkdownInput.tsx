// The composer's input: Milkdown (ProseMirror + remark) edited inline as formatted markdown.
// No toolbar, no split view, no syntax reveal: typing `**bold**`, `- ` or a fence turns into
// the formatted node (input rules), and the prompt is sent as the serialized markdown.
// Styling is in milkdown.css: the document looks like the plain composer text of the
// reference until something is formatted.
import { useCallback, useRef } from "react";
import { Editor, defaultValueCtx, editorViewOptionsCtx, remarkStringifyOptionsCtx, rootCtx } from "@milkdown/kit/core";
import { commonmark } from "@milkdown/kit/preset/commonmark";
import { gfm } from "@milkdown/kit/preset/gfm";
import { history } from "@milkdown/kit/plugin/history";
import { listener, listenerCtx } from "@milkdown/kit/plugin/listener";
import { clipboard } from "@milkdown/kit/plugin/clipboard";
import { keymap } from "@milkdown/kit/prose/keymap";
import { baseKeymap, chainCommands } from "@milkdown/kit/prose/commands";
import { splitListItem } from "@milkdown/kit/prose/schema-list";
import { $prose, getMarkdown, replaceAll } from "@milkdown/kit/utils";
import "./milkdown.css";

export type MilkdownInputHandle = {
  /** The prompt as markdown. */
  markdown(): string;
  /** Replace the document (empty clears it). */
  set(markdown: string): void;
  focus(): void;
};

export type MilkdownInputProps = {
  initial?: string;
  placeholder?: string;
  /** Enter (without Shift) sends; Shift-Enter starts a new block. */
  onSubmit: (markdown: string) => void;
  onChange?: (markdown: string) => void;
  onReady?: (handle: MilkdownInputHandle) => void;
  ariaLabel?: string;
};

/** True when the document has no text. */
const isBlank = (markdown: string) => markdown.replace(/[\s​]/g, "") === "";

export function MilkdownInput({
  initial = "",
  placeholder,
  onSubmit,
  onChange,
  onReady,
  ariaLabel = "Message",
}: MilkdownInputProps) {
  // Latest callbacks for the editor's long-lived plugins.
  const latest = useRef({ onSubmit, onChange });
  latest.current = { onSubmit, onChange };
  const empty = useRef<HTMLDivElement>(null);
  const showPlaceholder = (markdown: string) => {
    if (empty.current) empty.current.hidden = !isBlank(markdown);
  };
  const mount = useCallback(
    (root: HTMLDivElement | null) => {
      if (!root) return;
      let editor: Editor | undefined;
      let disposed = false;
      const submitKeys = $prose(() =>
        keymap({
          Enter: () => {
            const markdown = editor?.action(getMarkdown()) ?? "";
            if (isBlank(markdown)) return true;
            latest.current.onSubmit(markdown.trim());
            return true;
          },
          // Shift-Enter starts a new block (a new list item inside a list), so lists, quotes
          // and fences keep working and the prompt serializes without hard-break escapes.
          "Shift-Enter": (state, dispatch, view) => {
            const item = state.schema.nodes.list_item;
            const enter = baseKeymap.Enter!;
            return chainCommands(...(item ? [splitListItem(item), enter] : [enter]))(state, dispatch, view);
          },
        }),
      );
      void Editor.make()
        .config((ctx) => {
          ctx.set(rootCtx, root);
          ctx.set(defaultValueCtx, initial);
          // The markers people type in prompts: "-" bullets, "*" emphasis.
          ctx.update(remarkStringifyOptionsCtx, (options) => ({
            ...options,
            bullet: "-" as const,
            emphasis: "*" as const,
          }));
          ctx.update(editorViewOptionsCtx, (options) => ({
            ...options,
            attributes: { "aria-label": ariaLabel, role: "textbox", "aria-multiline": "true", class: "pt-md" },
          }));
          ctx.get(listenerCtx).markdownUpdated((_ctx, markdown) => {
            showPlaceholder(markdown);
            latest.current.onChange?.(markdown);
          });
        })
        // The keymap comes first so Enter sends before the presets' newline handling.
        .use(submitKeys)
        .use(commonmark)
        .use(gfm)
        .use(history)
        .use(clipboard)
        .use(listener)
        .create()
        .then((made) => {
          if (disposed) {
            void made.destroy();
            return;
          }
          editor = made;
          showPlaceholder(initial);
          onReady?.({
            markdown: () => made.action(getMarkdown()),
            set: (markdown) => {
              made.action(replaceAll(markdown));
              showPlaceholder(markdown);
            },
            focus: () => (root.querySelector(".ProseMirror") as HTMLElement | null)?.focus(),
          });
        });
      return () => {
        disposed = true;
        void editor?.destroy();
      };
    },
    // The editor is made once per mount; `initial` seeds it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );
  return (
    <div className="pt-md-input">
      <div ref={empty} className="pt-md-input__placeholder" aria-hidden="true">
        {placeholder}
      </div>
      <div ref={mount} className="pt-md-input__root" />
    </div>
  );
}
