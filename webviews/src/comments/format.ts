import { excerptFor, type CommentFileDiff } from "./anchor";
import type { CommentAttachment, DiffCommentRecord } from "./types";

export function commentBasename(filePath: string): string {
  const segments = filePath.split("/");
  const base = segments[segments.length - 1];
  return base != null && base !== "" ? base : filePath;
}

export function commentDisplayName(
  comment: Pick<DiffCommentRecord, "filePath" | "startLine" | "endLine">,
): string {
  const base = `${commentBasename(comment.filePath)}:${comment.startLine}`;
  return comment.endLine > comment.startLine ? `${base}-${comment.endLine}` : base;
}

export function attachmentForComment(
  comment: DiffCommentRecord,
  fileDiff: CommentFileDiff | null | undefined,
): CommentAttachment {
  const lineRef = comment.endLine > comment.startLine
    ? `lines ${comment.startLine}-${comment.endLine}`
    : `line ${comment.startLine}`;
  const version = comment.side === "deletions" ? "old" : "new";
  const excerpt = excerptFor(fileDiff, comment.side, comment.startLine, comment.endLine);
  const sections = [`Review comment on ${comment.filePath} ${lineRef} (${version} version):`];
  if (excerpt !== "") {
    sections.push(excerpt);
  }
  sections.push(comment.message);
  return {
    displayName: commentDisplayName(comment),
    submissionText: `${sections.join("\n\n")}\n`,
    submissionPath: comment.filePath,
  };
}
