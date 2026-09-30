import React, { useImperativeHandle, useLayoutEffect, useRef } from "react";
import { Schema, type Node as ProseMirrorNode } from "prosemirror-model";
import { splitBlock } from "prosemirror-commands";
import { EditorState, Plugin, PluginKey, TextSelection } from "prosemirror-state";
import { Decoration, DecorationSet, EditorView } from "prosemirror-view";
import { CODEX_FOLDER_ICON_PATH } from "../shared/codexIconPaths";
import { isComposingEnter, isPlanModeShortcut } from "../shared/keyboard";
import { promptMentionMarkdown } from "../shared/promptMentions";

export type PromptMention = {
  description?: string;
  displayName?: string;
  fsPath?: string;
  kind: "at" | "agent" | "skill";
  label: string;
  name: string;
  path: string;
};

export type PromptAutocompleteState = {
  anchorPos: number;
  kind: "mention" | "skill";
  query: string;
};

type PromptAutocompleteKey = "ArrowDown" | "ArrowUp" | "Enter" | "Tab" | "Escape";

const promptSchema = new Schema({
  nodes: {
    doc: { content: "paragraph+" },
    paragraph: {
      content: "inline*",
      group: "block",
      parseDOM: [{ tag: "p" }],
      toDOM: () => ["p", 0],
    },
    text: { group: "inline" },
    atMention: {
      attrs: {
        label: { validate: "string" },
        path: { validate: "string" },
        fsPath: { validate: "string", default: "" },
      },
      inline: true,
      group: "inline",
      draggable: false,
      selectable: false,
      toDOM: (node) => mentionDom({
        text: node.attrs.label,
        iconNode: folderMentionIcon(),
        dataAttributes: {
          "at-mention-label": node.attrs.label,
          "at-mention-path": node.attrs.path,
          "at-mention-fs-path": node.attrs.fsPath,
        },
      }),
      parseDOM: [{
        tag: "span[at-mention-label][at-mention-path]",
        getAttrs: (node) => {
          const element = node as HTMLElement;
          return {
            label: element.getAttribute("at-mention-label"),
            path: element.getAttribute("at-mention-path"),
            fsPath: element.getAttribute("at-mention-fs-path") ?? "",
          };
        },
      }],
    },
    agentMention: {
      attrs: {
        name: { validate: "string" },
        displayName: { validate: "string", default: "" },
        path: { validate: "string" },
      },
      inline: true,
      group: "inline",
      draggable: false,
      selectable: false,
      toDOM: (node) => {
        const displayName = node.attrs.displayName || node.attrs.name;
        return mentionDom({
          text: `@${displayName}`,
          dataAttributes: {
            "agent-mention-name": node.attrs.name,
            "agent-mention-display-name": displayName,
            "agent-mention-path": node.attrs.path,
          },
        });
      },
      parseDOM: [{
        tag: "span[agent-mention-name][agent-mention-path]",
        getAttrs: (node) => {
          const element = node as HTMLElement;
          const name = element.getAttribute("agent-mention-name") ?? "";
          return {
            name,
            displayName: element.getAttribute("agent-mention-display-name") ?? name,
            path: element.getAttribute("agent-mention-path") ?? "",
          };
        },
      }],
    },
    skillMention: {
      attrs: {
        name: { validate: "string" },
        displayName: { validate: "string", default: "" },
        path: { validate: "string" },
        description: { validate: "string", default: "" },
      },
      inline: true,
      group: "inline",
      draggable: false,
      selectable: false,
      toDOM: (node) => {
        const displayName = node.attrs.displayName || node.attrs.name;
        return mentionDom({
          text: displayName,
          icon: "$",
          dataAttributes: {
            "skill-mention-name": node.attrs.name,
            "skill-mention-display-name": displayName,
            "skill-mention-path": node.attrs.path,
          },
          title: node.attrs.description,
        });
      },
      parseDOM: [{
        tag: "span[skill-mention-name][skill-mention-path]",
        getAttrs: (node) => {
          const element = node as HTMLElement;
          const name = element.getAttribute("skill-mention-name") ?? "";
          return {
            name,
            displayName: element.getAttribute("skill-mention-display-name") ?? name,
            path: element.getAttribute("skill-mention-path") ?? "",
            description: element.getAttribute("title") ?? "",
          };
        },
      }],
    },
  },
  marks: {},
});

const placeholderKey = new PluginKey<string>("agentPromptPlaceholder");
export type PromptEditorHandle = {
  focus: () => void;
  getText: () => string;
  insertMention: (mention: PromptMention) => void;
  insertMentions: (mentions: PromptMention[]) => void;
  insertText: (text: string) => void;
};

type PromptEditorProps = {
  ariaLabel?: string;
  className?: string;
  minHeight?: string;
  onAutocompleteChange?: (state: PromptAutocompleteState | null) => void;
  onAutocompleteKeyDown?: (key: PromptAutocompleteKey) => boolean;
  onPlanModeShortcut?: () => void;
  onSubmit: () => void;
  onTextChange: (text: string) => void;
  onTriggerToken?: (token: "@" | "$") => void;
  placeholder: string;
  singleLine?: boolean;
  value: string;
};

export const PromptEditor = React.forwardRef<PromptEditorHandle, PromptEditorProps>(
  function PromptEditor(
    {
      ariaLabel,
      className,
      minHeight = "2.75rem",
      onAutocompleteChange,
      onAutocompleteKeyDown,
      onPlanModeShortcut,
      onSubmit,
      onTextChange,
      onTriggerToken,
      placeholder,
      singleLine = false,
      value,
    },
    ref,
  ) {
    const hostRef = useRef<HTMLDivElement | null>(null);
    const viewRef = useRef<EditorView | null>(null);
    const latestSubmitRef = useRef(onSubmit);
    const latestAutocompleteChangeRef = useRef(onAutocompleteChange);
    const latestAutocompleteKeyDownRef = useRef(onAutocompleteKeyDown);
    const latestPlanModeShortcutRef = useRef(onPlanModeShortcut);
    const latestTextChangeRef = useRef(onTextChange);
    const latestTriggerTokenRef = useRef(onTriggerToken);
    const latestTextRef = useRef(value);
    const latestSingleLineRef = useRef(singleLine);
    latestSubmitRef.current = onSubmit;
    latestAutocompleteChangeRef.current = onAutocompleteChange;
    latestAutocompleteKeyDownRef.current = onAutocompleteKeyDown;
    latestPlanModeShortcutRef.current = onPlanModeShortcut;
    latestTextChangeRef.current = onTextChange;
    latestTriggerTokenRef.current = onTriggerToken;
    latestSingleLineRef.current = singleLine;

    useImperativeHandle(ref, () => ({
      focus() {
        viewRef.current?.focus();
      },
      getText() {
        return latestTextRef.current;
      },
      insertMention(mention) {
        const view = viewRef.current;
        if (!view) {
          return;
        }
        insertPromptMentionAtSelection(view, mention);
      },
      insertMentions(mentions) {
        const view = viewRef.current;
        if (!view || mentions.length === 0) {
          return;
        }
        insertPromptMentionsAtSelection(view, mentions);
      },
      insertText(text) {
        const view = viewRef.current;
        if (!view) {
          return;
        }
        insertPromptTextAtSelection(view, text);
      },
    }), []);

    useLayoutEffect(() => {
      const host = hostRef.current;
      if (!host) {
        return;
      }
      const view = new EditorView(host, {
        state: EditorState.create({
          doc: docFromText(latestTextRef.current),
          plugins: [placeholderPlugin("")],
        }),
        attributes: {
          "aria-label": "",
          "data-codex-composer": "true",
          "data-virtualkeyboard": "true",
          role: "textbox",
          class: "ProseMirror prompt-editor-view",
          style: "min-height: 2.75rem; font-size: var(--codex-chat-font-size); height: auto; resize: none;",
        },
        dispatchTransaction(transaction) {
          const nextState = view.state.apply(transaction);
          view.updateState(nextState);
          const nextText = textFromDoc(nextState.doc);
          const previousText = latestTextRef.current;
          if (nextText !== previousText) {
            latestTextRef.current = nextText;
            const insertedTrigger = singleInsertedTrigger(previousText, nextText);
            if (insertedTrigger) {
              latestTriggerTokenRef.current?.(insertedTrigger);
            }
            latestTextChangeRef.current(nextText);
          }
          latestAutocompleteChangeRef.current?.(autocompleteStateForSelection(view));
        },
        handleKeyDown(_view, event) {
          if (isComposingEnter(event, _view.composing)) {
            return false;
          }
          if (isPlanModeShortcut(event) && latestPlanModeShortcutRef.current) {
            event.preventDefault();
            latestPlanModeShortcutRef.current();
            return true;
          }
          if (isAutocompleteKey(event.key) && latestAutocompleteKeyDownRef.current?.(event.key)) {
            event.preventDefault();
            return true;
          }
          if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
            event.preventDefault();
            latestSubmitRef.current();
            return true;
          }
          if (event.key !== "Enter") {
            return false;
          }
          if (event.shiftKey || event.altKey) {
            event.preventDefault();
            if (latestSingleLineRef.current) {
              return true;
            }
            return splitBlock(_view.state, _view.dispatch, _view);
          }
          event.preventDefault();
          latestSubmitRef.current();
          return true;
        },
      });
      viewRef.current = view;
      return () => {
        view.destroy();
        viewRef.current = null;
      };
    }, []);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view) {
        return;
      }
      view.dispatch(view.state.tr.setMeta(placeholderKey, placeholder));
    }, [placeholder]);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view) {
        return;
      }
      const nextLabel = ariaLabel ?? placeholder;
      if (nextLabel) {
        view.dom.setAttribute("aria-label", nextLabel);
      } else {
        view.dom.removeAttribute("aria-label");
      }
    }, [ariaLabel, placeholder]);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view) {
        return;
      }
      view.dom.style.minHeight = minHeight;
    }, [minHeight]);

    useLayoutEffect(() => {
      const view = viewRef.current;
      if (!view || value === latestTextRef.current) {
        return;
      }
      latestTextRef.current = value;
      replaceEditorText(view, value);
    }, [value]);

    const promptEditorClassName = [
      "text-size-chat",
      "[&_.ProseMirror]:focus-visible:outline-none",
      "text-token-foreground",
      singleLine
        ? "flex h-9 max-h-none items-center overflow-hidden [&_.ProseMirror]:!h-5 [&_.ProseMirror]:!min-h-5 [&_.ProseMirror]:min-w-0 [&_.ProseMirror]:flex-1 [&_.ProseMirror]:overflow-hidden [&_.ProseMirror]:whitespace-nowrap [&_.ProseMirror_p]:overflow-hidden [&_.ProseMirror_p]:text-ellipsis [&_.ProseMirror_p]:whitespace-nowrap"
        : "h-auto max-h-[25dvh] overflow-y-auto [&_.ProseMirror]:h-auto [&_.ProseMirror]:min-h-[2rem]",
      "[&_.ProseMirror]:resize-none",
      "[&_.ProseMirror_p]:m-0",
      className,
    ].filter(Boolean).join(" ");

    return React.createElement("div", {
      className: promptEditorClassName,
      onMouseDown: (event: React.MouseEvent<HTMLDivElement>) => {
        const view = viewRef.current;
        if (!view) {
          return;
        }
        if (event.target instanceof Node && !view.dom.contains(event.target)) {
          event.preventDefault();
          view.focus();
        }
      },
      ref: hostRef,
    });
  },
);

function singleInsertedTrigger(previous: string, next: string): "@" | "$" | null {
  if (next.length !== previous.length + 1) {
    return null;
  }
  let prefixLength = 0;
  while (
    prefixLength < previous.length &&
    previous.charCodeAt(prefixLength) === next.charCodeAt(prefixLength)
  ) {
    prefixLength += 1;
  }
  let suffixLength = 0;
  while (
    suffixLength < previous.length - prefixLength &&
    previous.charCodeAt(previous.length - 1 - suffixLength) ===
      next.charCodeAt(next.length - 1 - suffixLength)
  ) {
    suffixLength += 1;
  }
  const inserted = next.slice(prefixLength, next.length - suffixLength);
  return inserted === "@" || inserted === "$" ? inserted : null;
}

function placeholderPlugin(initialPlaceholder: string): Plugin {
  return new Plugin<string>({
    key: placeholderKey,
    state: {
      init: () => initialPlaceholder,
      apply(transaction, previous) {
        return transaction.getMeta(placeholderKey) ?? previous;
      },
    },
    props: {
      decorations(state) {
        const placeholder = placeholderKey.getState(state) ?? "";
        if (!placeholder || state.doc.childCount !== 1) {
          return null;
        }
        const firstChild = state.doc.firstChild;
        if (!firstChild?.isTextblock || firstChild.content.size !== 0) {
          return null;
        }
        return DecorationSet.create(state.doc, [
          Decoration.node(0, firstChild.nodeSize, {
            class: "placeholder",
            "data-placeholder": placeholder,
          }),
        ]);
      },
    },
  });
}

function docFromText(text: string) {
  const paragraphs = text.split("\n");
  return promptSchema.nodes.doc.create(null, paragraphs.map((paragraph) => {
    return promptSchema.nodes.paragraph.create(
      null,
      paragraph.length > 0 ? promptSchema.text(paragraph) : null,
    );
  }));
}

function textFromDoc(doc: ProseMirrorNode): string {
  const paragraphs: string[] = [];
  doc.forEach((node) => {
    const parts: string[] = [];
    node.forEach((child) => {
      parts.push(textFromInlineNode(child));
    });
    paragraphs.push(parts.join(""));
  });
  return paragraphs.join("\n");
}

function textFromInlineNode(node: ProseMirrorNode): string {
  switch (node.type.name) {
    case "atMention":
      return promptMentionMarkdown({
        kind: "at",
        label: node.attrs.label,
        name: node.attrs.label,
        path: node.attrs.path,
      });
    case "agentMention":
      return promptMentionMarkdown({
        kind: "agent",
        displayName: node.attrs.displayName || node.attrs.name,
        name: node.attrs.name,
        path: node.attrs.path,
      });
    case "skillMention":
      return promptMentionMarkdown({
        kind: "skill",
        displayName: node.attrs.displayName || node.attrs.name,
        name: node.attrs.name,
        path: node.attrs.path,
      });
    default:
      return node.textContent;
  }
}

function replaceEditorText(view: EditorView, text: string): void {
  const doc = docFromText(text);
  const transaction = view.state.tr.replaceWith(0, view.state.doc.content.size, doc.content);
  transaction.setSelection(TextSelection.atEnd(transaction.doc));
  view.dispatch(transaction);
}

function insertPromptTextAtSelection(view: EditorView, text: string): void {
  const { state } = view;
  const { from, to } = state.selection;
  const trigger = text.startsWith("@") ? "@" : text.startsWith("$") ? "$" : null;
  const previousCharacter = state.doc.textBetween(Math.max(0, from - 1), from, "\n", "\n");
  const insertFrom = trigger && previousCharacter === trigger ? from - 1 : from;
  const before = state.doc.textBetween(Math.max(0, insertFrom - 2), insertFrom, "\n", "\n");
  const after = state.doc.textBetween(to, Math.min(state.doc.content.size, to + 2), "\n", "\n");
  const prefix = before.length > 0 && !/\s$/.test(before) ? " " : "";
  const suffix = after.length > 0 && !/^\s/.test(after) ? " " : "";
  const inserted = `${prefix}${text}${suffix}`;
  const transaction = state.tr.insertText(inserted, insertFrom, to);
  const cursor = insertFrom + inserted.length;
  transaction.setSelection(TextSelection.create(transaction.doc, cursor));
  view.dispatch(transaction);
  view.focus();
}

function insertPromptMentionAtSelection(view: EditorView, mention: PromptMention): void {
  const { state } = view;
  const { from, to } = state.selection;
  const trigger = mention.kind === "skill" ? "$" : "@";
  const insertFrom = autocompleteStateForSelection(view)?.anchorPos ?? (
    state.doc.textBetween(Math.max(0, from - 1), from, "\n", "\n") === trigger ? from - 1 : from
  );
  const before = state.doc.textBetween(Math.max(0, insertFrom - 2), insertFrom, "\n", "\n");
  const after = state.doc.textBetween(to, Math.min(state.doc.content.size, to + 2), "\n", "\n");
  const prefix = before.length > 0 && !/\s$/.test(before) ? " " : "";
  const suffix = after.length > 0 && !/^\s/.test(after) ? " " : "";
  const nodes: ProseMirrorNode[] = [];
  if (prefix) {
    nodes.push(state.schema.text(prefix));
  }
  nodes.push(nodeForMention(state.schema, mention));
  if (suffix) {
    nodes.push(state.schema.text(suffix));
  }
  const transaction = state.tr.replaceWith(insertFrom, to, nodes);
  const cursor = insertFrom + nodes.reduce((total, node) => total + node.nodeSize, 0);
  transaction.setSelection(TextSelection.create(transaction.doc, cursor));
  view.dispatch(transaction);
  view.focus();
}

function insertPromptMentionsAtSelection(view: EditorView, mentions: PromptMention[]): void {
  const { state } = view;
  const { from, to } = state.selection;
  const before = state.doc.textBetween(Math.max(0, from - 2), from, "\n", "\n");
  const after = state.doc.textBetween(to, Math.min(state.doc.content.size, to + 2), "\n", "\n");
  const nodes: ProseMirrorNode[] = [];
  if (before.length > 0 && !/\s$/.test(before)) {
    nodes.push(state.schema.text(" "));
  }
  mentions.forEach((mention, index) => {
    if (index > 0) {
      nodes.push(state.schema.text(" "));
    }
    nodes.push(nodeForMention(state.schema, mention));
  });
  if (after.length > 0 && !/^\s/.test(after)) {
    nodes.push(state.schema.text(" "));
  }
  const transaction = state.tr.replaceWith(from, to, nodes);
  const cursor = from + nodes.reduce((total, node) => total + node.nodeSize, 0);
  transaction.setSelection(TextSelection.create(transaction.doc, cursor));
  view.dispatch(transaction);
  view.focus();
}

function nodeForMention(schema: Schema, mention: PromptMention): ProseMirrorNode {
  switch (mention.kind) {
    case "skill":
      return schema.nodes.skillMention.create({
        name: mention.name,
        displayName: mention.displayName ?? mention.label,
        path: mention.path,
        description: mention.description ?? "",
      });
    case "agent":
      return schema.nodes.agentMention.create({
        name: mention.name,
        displayName: mention.displayName ?? mention.label,
        path: mention.path,
      });
    case "at":
      return schema.nodes.atMention.create({
        label: mention.label,
        path: mention.path,
        fsPath: mention.fsPath ?? mention.path,
      });
  }
}

function autocompleteStateForSelection(view: EditorView): PromptAutocompleteState | null {
  const { state } = view;
  const { from, empty } = state.selection;
  if (!empty) {
    return null;
  }
  const textBefore = state.doc.textBetween(0, from, "\n", "\n");
  const match = /(^|\s)([@$][^\s@$]*)$/.exec(textBefore);
  if (!match) {
    return null;
  }
  const token = match[2] ?? "";
  const trigger = token.charAt(0);
  const query = token.slice(1);
  return {
    anchorPos: from - token.length,
    kind: trigger === "$" ? "skill" : "mention",
    query,
  };
}

function isAutocompleteKey(key: string): key is PromptAutocompleteKey {
  return key === "ArrowDown" || key === "ArrowUp" || key === "Enter" || key === "Tab" || key === "Escape";
}

function mentionDom({
  dataAttributes,
  icon,
  iconNode,
  text,
  title,
}: {
  dataAttributes: Record<string, string>;
  icon?: string;
  iconNode?: Node;
  text: string;
  title?: string;
}): HTMLElement {
  const root = document.createElement("span");
  root.className =
    "prompt-editor-mention group/inline-mention cursor-pointer inline-mention-brand-aware font-medium px-0.5 cursor-interaction";
  if (title) {
    root.title = title;
  }
  for (const [key, value] of Object.entries(dataAttributes)) {
    root.setAttribute(key, value);
  }
  if (icon || iconNode) {
    const iconWrapper = document.createElement("span");
    iconWrapper.className = "prompt-editor-mention-icon relative mr-[3px] inline-block h-[1lh] w-4 align-bottom";
    if (iconNode) {
      iconWrapper.append(iconNode);
    } else if (icon) {
      const iconGlyph = document.createElement("span");
      iconGlyph.className = "icon-xs absolute top-1/2 -translate-y-1/2";
      iconGlyph.textContent = icon;
      iconWrapper.append(iconGlyph);
    }
    root.append(iconWrapper);
  }
  const label = document.createElement("span");
  label.className = "min-w-0 break-words";
  label.textContent = text;
  root.append(label);
  return root;
}

function folderMentionIcon(): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "icon-xs absolute top-1/2 -translate-y-1/2");
  svg.setAttribute("width", "20");
  svg.setAttribute("height", "20");
  svg.setAttribute("viewBox", "0 0 20 20");
  svg.setAttribute("fill", "none");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", CODEX_FOLDER_ICON_PATH);
  path.setAttribute("fill", "currentColor");
  svg.append(path);
  return svg;
}
