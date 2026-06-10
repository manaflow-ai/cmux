import { excerptFor, type CommentFileDiff } from "./anchor";
import type { AttachCandidate, CommentAttachment, DiffCommentRecord } from "./types";

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
 * Builds display labels for the attach-target dropdown, disambiguating
 * terminals that share a title with the directory basename and an ordinal.
 */
export function attachTargetOptionLabels(candidates: readonly AttachCandidate[]): string[] {
  const base = candidates.map((candidate) => {
    const title = candidate.title.trim();
    return title !== "" ? title : commentBasename(candidate.directory ?? "") || "Terminal";
  });
  const baseCounts = new Map<string, number>();
  for (const label of base) {
    baseCounts.set(label, (baseCounts.get(label) ?? 0) + 1);
  }
  const withDirectory = base.map((label, index) => {
    const directory = candidates[index].directory ?? "";
    if ((baseCounts.get(label) ?? 0) > 1 && directory !== "") {
      return `${label} — ${commentBasename(directory)}`;
    }
    return label;
  });
  const finalCounts = new Map<string, number>();
  for (const label of withDirectory) {
    finalCounts.set(label, (finalCounts.get(label) ?? 0) + 1);
  }
  const seen = new Map<string, number>();
  return withDirectory.map((label) => {
    if ((finalCounts.get(label) ?? 0) <= 1) {
      return label;
    }
    const ordinal = (seen.get(label) ?? 0) + 1;
    seen.set(label, ordinal);
    return `${label} (${ordinal})`;
  });
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
