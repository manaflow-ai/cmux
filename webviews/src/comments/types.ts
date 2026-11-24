export type DiffCommentSide = "additions" | "deletions";

export type DiffCommentRecord = {
  id: string;
  filePath: string; // exactly fileName(item.fileDiff) for the item it belongs to
  side: DiffCommentSide;
  startLine: number;
  endLine: number; // anchor line; annotation renders under endLine on `side`
  endSide?: DiffCommentSide;
  lineText: string; // content of endLine at save time (anchor text, exact)
  message: string;
  submissionText?: string; // precomputed text block consumed by the native pending pool
  createdAt: string; // ISO8601
  updatedAt: string;
};

export type DiffCommentSaveInput = Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt"> & {
  id?: string;
};

export type AnchorResult =
  | { state: "anchored"; line: number }
  | { state: "moved"; line: number; delta: number }
  | { state: "outdated" };

export type CommentDraft = {
  itemId: string;
  side: DiffCommentSide;
  startLine: number;
  endLine: number;
};

export type CommentAnnotationMetadata =
  | { kind: "draft" }
  | { kind: "comment"; comment: DiffCommentRecord; anchor: AnchorResult };

/** Where "Send to agent" is: idle, on its way, or refused (the comments stay). */
export type CommentsSendState = "idle" | "sending" | "failed";

/**
 * The GitHub pull request a review worktree checks out (`cmux git review start <url>`), as the host
 * lists it with the worktree's comments. Absent for an ordinary worktree.
 */
export type DiffReviewTarget = {
  url: string;
  repo: string; // "owner/name"
  number: number;
  title?: string;
  head: string; // the commit sha the drafts were written against
  base?: string; // the merge-base commit the diff starts from
};

/** Where "Post to GitHub" is: idle, on its way, posted (the drafts left), or refused (they stay). */
export type CommentsPostState = "idle" | "posting" | "posted" | "failed";

/** What one post made: the review's page, its inline comments and those folded into its body. */
export type DiffReviewPosted = { url: string; posted: number; inBody: number };
