import { diffExcerptFor, excerptFor, type CommentFileDiff } from "./anchor";
import type { DiffCommentRecord } from "./types";

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

/**
 * Builds the precomputed submission text stored with a saved comment. Native
 * code submits this block verbatim when the workspace pending pool is consumed.
 */
export function commentSubmissionText(
  comment: Pick<DiffCommentRecord, "filePath" | "side" | "startLine" | "endLine" | "message">,
  fileDiff: CommentFileDiff | null | undefined,
): string {
  const lineRef = comment.endLine > comment.startLine
    ? `lines ${comment.startLine}-${comment.endLine}`
    : `line ${comment.startLine}`;
  const version = comment.side === "deletions" ? "old" : "new";
  const sections = [`Review comment on ${comment.filePath} ${lineRef} (${version} version):`];
  const diffExcerpt = diffExcerptFor(fileDiff, comment.side, comment.startLine, comment.endLine);
  if (diffExcerpt !== "") {
    sections.push(`\`\`\`diff\n${diffExcerpt}\n\`\`\``);
  } else {
    const excerpt = excerptFor(fileDiff, comment.side, comment.startLine, comment.endLine);
    if (excerpt !== "") {
      sections.push(excerpt);
    }
  }
  sections.push(comment.message);
  return `${sections.join("\n\n")}\n`;
}
