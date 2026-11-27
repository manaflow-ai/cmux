// Comments in the viewer (viewer-comments-DESIGN.md "Comments in the viewer"): each comment the user
// left with Comment… shows as a marker in the left margin of the block that holds its first line;
// the marker opens a card with the quoted text, the comment and Delete. The host keeps the list with
// the file and sends it in the config (`comments`) and on every change (the `comments` command).
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { Plugin, PluginKey } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";
import type { QuoteSourceMap } from "./selectionQuote";

/** One comment, as the host's `ViewerComment`. */
export interface ViewerComment {
  id: string;
  startLine: number;
  endLine: number;
  quoted: string;
  comment: string;
}

/** The comments in `value` (the host's `{v: 1, comments: [...]}`), skipping malformed ones. */
export function parseComments(value: unknown): ViewerComment[] {
  const raw = (value ?? {}) as { v?: unknown; comments?: unknown };
  if (raw.v !== 1 || !Array.isArray(raw.comments)) return [];
  return raw.comments.filter(
    (item): item is ViewerComment =>
      !!item &&
      typeof item.id === "string" &&
      Number.isInteger(item.startLine) &&
      item.startLine >= 1 &&
      Number.isInteger(item.endLine) &&
      typeof item.quoted === "string" &&
      typeof item.comment === "string",
  );
}

/** The index of the top-level node whose source holds 1-based `line`, else the last block before it. */
export function topIndexForLine(map: QuoteSourceMap, line: number): number | null {
  if (line < 1 || map.blocks.length === 0) return null;
  // The offset where `line` starts (past the end: the text's end).
  let offset = 0;
  for (let current = 1; current < line; current++) {
    const next = map.text.indexOf("\n", offset);
    if (next < 0) {
      offset = map.text.length;
      break;
    }
    offset = next + 1;
  }
  let index = 0;
  let found: number | null = null;
  for (const block of map.blocks) {
    if (block.nodes.length && block.start <= offset) found = index;
    if (block.start > offset) break;
    index += block.nodes.length;
  }
  return found ?? 0;
}

/** Builds a comment's marker: a margin button that opens its card (quote, comment, Delete). */
export function commentMarker(comment: ViewerComment, host: CommentMarkerHost): HTMLElement {
  const marker = document.createElement("div");
  marker.className = "cmux-comment-marker";
  marker.dataset.commentId = comment.id;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "cmux-comment-button";
  button.setAttribute("aria-label", host.label("comment"));
  button.setAttribute("aria-expanded", "false");
  button.addEventListener("click", (event) => {
    event.preventDefault();
    const open = marker.querySelector(".cmux-comment-card");
    if (open) {
      open.remove();
      button.setAttribute("aria-expanded", "false");
      return;
    }
    marker.append(commentCard(comment, host));
    button.setAttribute("aria-expanded", "true");
  });
  marker.append(button);
  return marker;
}

/** What a marker needs from the page: its strings and Delete. */
export interface CommentMarkerHost {
  label(key: "comment" | "deleteComment"): string;
  deleteComment?(id: string): void;
}

function commentCard(comment: ViewerComment, host: CommentMarkerHost): HTMLElement {
  const card = document.createElement("div");
  card.className = "cmux-comment-card";
  card.setAttribute("role", "note");
  const quote = document.createElement("blockquote");
  quote.textContent = comment.quoted;
  const text = document.createElement("p");
  text.textContent = comment.comment;
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "cmux-comment-delete";
  remove.textContent = host.label("deleteComment");
  remove.addEventListener("click", (event) => {
    event.preventDefault();
    host.deleteComment?.(comment.id);
  });
  card.append(quote, text, remove);
  return card;
}

export const commentMarkersKey = new PluginKey<DecorationSet>("cmuxCommentMarkers");

/** Draws the decorations `setComments` computed (meta on `commentMarkersKey`); edits map them along. */
export function commentMarkersPlugin() {
  return $prose(
    () =>
      new Plugin<DecorationSet>({
        key: commentMarkersKey,
        state: {
          init: () => DecorationSet.empty,
          apply: (tr, previous) => {
            const next = tr.getMeta(commentMarkersKey) as DecorationSet | undefined;
            return next ?? previous.map(tr.mapping, tr.doc);
          },
        },
        props: { decorations: (state) => commentMarkersKey.getState(state) },
      }),
  );
}

/** The marker decorations for `comments` in `doc`: each at the start of the top-level node `topIndex` names. */
export function commentDecorations(
  doc: ProseNode,
  comments: readonly ViewerComment[],
  topIndex: (line: number) => number | null,
  host: CommentMarkerHost,
): DecorationSet {
  const starts: number[] = [];
  doc.forEach((_node, offset) => starts.push(offset));
  const decorations: Decoration[] = [];
  for (const comment of comments) {
    const index = topIndex(comment.startLine);
    if (index === null) continue;
    const pos = starts[Math.min(index, starts.length - 1)];
    if (pos === undefined) continue;
    decorations.push(
      Decoration.widget(pos, () => commentMarker(comment, host), {
        side: -1,
        key: `comment-${comment.id}`,
        ignoreSelection: true,
        stopEvent: () => true,
      }),
    );
  }
  return DecorationSet.create(doc, decorations);
}
