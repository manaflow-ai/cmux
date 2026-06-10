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

export type CommentTarget = {
  workspaceId?: string;
  surfaceId?: string;
};

export type CommentAttachment = {
  displayName: string;
  submissionText: string;
  submissionPath: string;
};

export type AttachTerminal = {
  surfaceId: string;
  title: string;
};

export type AttachCandidate = {
  surfaceId: string;
  title: string;
  directory?: string;
  hasActiveTextBox: boolean;
};

export type AttachResult =
  | { status: "attached"; terminal: AttachTerminal }
  | { status: "picker"; candidates: AttachCandidate[] }
  | { status: "unavailable" };

export type AttachTargets = {
  candidates: AttachCandidate[];
  defaultSurfaceId: string | null;
  openerSurfaceId: string | null;
};

export type CommentAttachState =
  | { phase: "idle" }
  | { phase: "attaching" }
  | { phase: "attached"; terminal: AttachTerminal }
  | { phase: "failed" }
  | { phase: "picker"; candidates: AttachCandidate[] }
  | { phase: "unavailable" };
