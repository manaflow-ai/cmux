export type DiffCommentSide = "additions" | "deletions";

export type DiffCommentRecord = {
  id: string;
  filePath: string;          // exactly fileName(item.fileDiff) for the item it belongs to
  side: DiffCommentSide;
  startLine: number;
  endLine: number;           // anchor line; annotation renders under endLine on `side`
  endSide?: DiffCommentSide;
  lineText: string;          // content of endLine at save time (anchor text, exact)
  message: string;
  submissionText?: string;   // precomputed text block consumed by the native pending pool
  createdAt: string;         // ISO8601
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
