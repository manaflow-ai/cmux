import type { DiffLineAnnotation } from "@pierre/diffs";
import { fileName, type DiffItem } from "../diff-stream";
import { anchorComment } from "./anchor";
import type {
  AnchorResult,
  CommentAnnotationMetadata,
  CommentDraft,
  DiffCommentRecord,
} from "./types";

export type CommentAnnotation = DiffLineAnnotation<CommentAnnotationMetadata>;

/**
 * Derives the inline annotations for one diff item from the saved comments
 * and the in-progress draft. Comments anchor against the item's fileDiff;
 * outdated comments get no inline annotation (they stay sidebar-only).
 */
export function annotationsForItem(
  item: DiffItem,
  comments: readonly DiffCommentRecord[],
  draft: CommentDraft | null,
): CommentAnnotation[] {
  const annotations: CommentAnnotation[] = [];
  const path = item.fileDiff != null ? fileName(item.fileDiff, "") : "";
  if (path !== "") {
    for (const comment of comments) {
      if (comment.filePath !== path) {
        continue;
      }
      const anchor = anchorComment(item.fileDiff, comment);
      if (anchor.state === "outdated") {
        continue;
      }
      annotations.push({
        side: comment.side,
        lineNumber: anchor.line,
        metadata: { kind: "comment", comment, anchor },
      });
    }
  }
  if (draft != null && draft.itemId === item.id) {
    annotations.push({
      side: draft.side,
      lineNumber: draft.endLine,
      metadata: { kind: "draft" },
    });
  }
  return annotations;
}

function sameAnchor(previous: AnchorResult, next: AnchorResult): boolean {
  if (previous.state !== next.state) {
    return false;
  }
  if (previous.state === "outdated" || next.state === "outdated") {
    return true;
  }
  return previous.line === next.line;
}

function sameCommentAnnotation(previous: CommentAnnotation, next: CommentAnnotation): boolean {
  if (previous.side !== next.side || previous.lineNumber !== next.lineNumber) {
    return false;
  }
  const previousMetadata = previous.metadata;
  const nextMetadata = next.metadata;
  if (previousMetadata.kind === "draft" || nextMetadata.kind === "draft") {
    return previousMetadata.kind === nextMetadata.kind;
  }
  return previousMetadata.comment === nextMetadata.comment &&
    sameAnchor(previousMetadata.anchor, nextMetadata.anchor);
}

export function sameCommentAnnotations(
  previous: readonly CommentAnnotation[] | undefined,
  next: readonly CommentAnnotation[],
): boolean {
  const previousList = previous ?? [];
  if (previousList.length !== next.length) {
    return false;
  }
  for (let index = 0; index < next.length; index += 1) {
    if (!sameCommentAnnotation(previousList[index], next[index])) {
      return false;
    }
  }
  return true;
}

/**
 * Attaches derived annotations to a freshly streamed item (no version bump;
 * the item has never been handed to the CodeView yet).
 */
export function withCommentAnnotations(
  item: DiffItem,
  comments: readonly DiffCommentRecord[],
  draft: CommentDraft | null,
): DiffItem {
  const annotations = annotationsForItem(item, comments, draft);
  if (annotations.length === 0 && (item.annotations == null || item.annotations.length === 0)) {
    return item;
  }
  return { ...item, annotations };
}

/**
 * Recomputes annotations across all items, preserving item identity (and
 * version) for items whose annotations did not change so the controlled
 * CodeView only re-renders affected files.
 */
export function applyCommentAnnotations(
  items: readonly DiffItem[],
  comments: readonly DiffCommentRecord[],
  draft: CommentDraft | null,
): DiffItem[] {
  let changed = false;
  const next = items.map((item) => {
    const annotations = annotationsForItem(item, comments, draft);
    // Diff viewer items are always type "diff", so their annotations are
    // DiffLineAnnotation values even though CodeViewItem unions in file items.
    if (sameCommentAnnotations(item.annotations as CommentAnnotation[] | undefined, annotations)) {
      return item;
    }
    changed = true;
    return { ...item, annotations, version: (item.version ?? 0) + 1 };
  });
  return changed ? next : (items as DiffItem[]);
}

export type SidebarCommentEntry = {
  comment: DiffCommentRecord;
  itemId: string | null;
  anchor: AnchorResult;
  /** True while the diff is still streaming and this comment's file has not
   * arrived yet; render as loading instead of prematurely calling it
   * outdated. */
  pending: boolean;
};

/**
 * Builds the sidebar list: every comment (including outdated ones) resolved
 * to the first item whose fileDiff anchors it, falling back to the first item
 * with a matching path for outdated comments.
 */
export function sidebarCommentEntries(
  items: readonly DiffItem[],
  comments: readonly DiffCommentRecord[],
  streamComplete = true,
): SidebarCommentEntry[] {
  return comments.map((comment) => {
    let fallback: { itemId: string; anchor: AnchorResult } | null = null;
    for (const item of items) {
      if (item.fileDiff == null || fileName(item.fileDiff, "") !== comment.filePath) {
        continue;
      }
      const anchor = anchorComment(item.fileDiff, comment);
      if (anchor.state !== "outdated") {
        return { comment, itemId: item.id, anchor, pending: false };
      }
      fallback ??= { itemId: item.id, anchor };
    }
    return {
      comment,
      itemId: fallback?.itemId ?? null,
      anchor: fallback?.anchor ?? { state: "outdated" },
      pending: fallback == null && !streamComplete,
    };
  });
}
