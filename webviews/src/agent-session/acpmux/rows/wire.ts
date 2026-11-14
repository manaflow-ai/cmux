// A chat's changes as the client core gives them (cmux-tui/crates/acpmux-client/src/chat.rs,
// `ChatChange`), and the rows, ops and windows inside them (wire.rs: `ChatWindow`, `ChatOp`,
// `ChatPageResult`, `BlobHead`, `QueueHead`; acpmux-book/src/row.rs: the row text). The page reads
// these and decides nothing of the wire: no cursor, no credit, no edition compare.

/// One row as the daemon encoded it (acpmux-book/src/row.rs `Row::encode`). `body` is the kind's
/// own JSON; a body too large for the row is out of line and `blob` names its length and preview.
export type ChatRow = {
  id: number;
  /// 1 when the row settles; rises on the rare change after that.
  rev: number;
  kind: string;
  turn?: number;
  group?: number;
  /// Seconds since the epoch.
  at: number;
  open: boolean;
  body: unknown;
  /// Lines, for the height estimate.
  est: number;
  blob?: { bytes: number; preview: string };
};

/// An open row as a window carries it; `bodyLen` when its body was left out (read by `blob`).
export type ChatOpenRow = { row: ChatRow; bodyLen?: number };

export type ChatQueueItem = { id: string; text: string; len: number; held?: boolean; at: number };
export type ChatQueueHead = { entries: ChatQueueItem[]; count: number };

export type ChatWindow = {
  sid: string;
  cursor: number;
  edition: number;
  rows: ChatRow[];
  hasBefore: boolean;
  hasAfter: boolean;
  open?: ChatOpenRow[];
  queue?: ChatQueueHead;
  seen?: number;
  folds?: number[];
  refused?: number[];
};

export type ChatOp =
  | { op: "row"; seq: number; row: ChatRow; bodyLen?: number }
  | { op: "text"; seq: number; rowId: number; text: string }
  | { op: "patch"; seq: number; row: ChatRow }
  | {
      op: "queue";
      seq: number;
      entry?: ChatQueueItem;
      removed?: string;
      count: number;
      head?: ChatQueueHead;
    };

export type ChatPageResult = {
  sid: string;
  edition: number;
  rows: ChatRow[];
  hasBefore: boolean;
  hasAfter: boolean;
  refused?: number[];
};

export type ChatBlobHead = {
  id: string;
  start: number;
  len: number;
  total: number;
  next?: string;
  open?: boolean;
  gen?: string;
  fixed?: number;
};

export type ChatChange =
  | { kind: "chatWindow"; replaces: boolean; window: ChatWindow }
  | { kind: "chatOp"; sid: string; replay: boolean; op: ChatOp }
  | { kind: "chatResumeEnd"; sid: string; cursor: number }
  | { kind: "chatPage"; page: ChatPageResult }
  | { kind: "chatBlob"; sid: string; head: ChatBlobHead; nextStart: number; text: string }
  | { kind: "chatDropped"; sid: string; cursor?: number | null }
  | { kind: "chatError"; sid?: string | null; method: string; id?: string | null; code: string };

/// One change string as the host passes it. A blob's string is its JSON, one newline, then the
/// text; every other change is one compact JSON value, which holds no raw newline. Null for a
/// string that is not a change.
export function parseChange(line: string): ChatChange | null {
  const newline = line.indexOf("\n");
  const json = newline < 0 ? line : line.slice(0, newline);
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object" || typeof (value as { kind?: unknown }).kind !== "string") return null;
  const change = value as ChatChange;
  if (change.kind === "chatBlob") change.text = newline < 0 ? "" : line.slice(newline + 1);
  return change;
}

/// The sid a change is for; a `chatPage` and a `chatWindow` carry it inside.
export function changeSid(change: ChatChange): string | null {
  switch (change.kind) {
    case "chatWindow":
      return change.window.sid;
    case "chatPage":
      return change.page.sid;
    case "chatError":
      return change.sid ?? null;
    default:
      return change.sid;
  }
}
