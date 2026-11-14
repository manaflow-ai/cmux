// Pair Another Machine (`#/pair-invite`): the ops the app answers (PairInviteCardProvider.swift).
// Swift keeps the mint, the invite's watch socket (its secret never reaches the page), Add Server's
// approver and the clipboard; the page derives the step, the buttons and the countdown (model.ts).

export const PairInviteOps = {
  /** `{}` → `PairInviteStatus`. */
  status: "cmux.pairInvite.status",
  /** `{}` → null: a new invite. The person's own click or key. */
  newCode: "cmux.pairInvite.newCode",
  /** `{target}` → null: copies the code, the line or the install line, concealed. The person's own click or key. */
  copy: "cmux.pairInvite.copy",
  /** `{on}` → null: run the person's Chief on the arrived machine. The person's own click or key. */
  setRunChief: "cmux.pairInvite.setRunChief",
  /** `{name}` → null: the Name field, read when Confirm goes. Confirm and Try Again are the panel's
   * native control in its own footer under the page: only the person's click on it approves. */
  setName: "cmux.pairInvite.setName",
  /** Stream: one empty event whenever the status may have changed; the page asks again. */
  changes: "cmux.pairInvite.changes",
} as const;

export const PAIR_INVITE_CARD = "pair-invite";

/** What the Copy buttons copy. */
export type CopyTarget = "code" | "line" | "installLine";

export interface PairInviteShown {
  /** `ABCDE-12345`. */
  code: string;
  /** `cmux pair ABCDE-12345`. */
  line: string;
  /** The install line, then the invite, for a machine without cmux. */
  installLine: string;
  /** The code's QR (`https://cmux.com/pair?i=…`) as a PNG data URL, dark on white. */
  qr?: string;
  /** Unix ms when the code stops working. */
  expiresAt: number;
}

/** One frame of the invite's watch socket, in order. */
export type PairInviteFrame =
  | { t: "pending" }
  | { t: "arrived"; code: string }
  | { t: "paired"; host: string }
  | { t: "voided" }
  | { t: "expired" }
  | { t: "lost" };

/** The arrived machine as Add Server's preview read it. */
export interface PairingCandidate {
  /** Its pending server pairing's 8-symbol code. */
  code: string;
  name: string;
  os: string;
  version: string;
  /** ISO 3166 region of the begin request (coarse location). */
  region?: string;
  words: string[];
}

/** Add Server's approver (ServerModel's `addServerStep`). */
export interface PairInviteApprover {
  step: "enterCode" | "lookingUp" | "codeRefused" | "review" | "approving" | "approveFailed" | "added";
  candidate?: PairingCandidate;
  /** The refusal (codeRefused, approveFailed). */
  reject?: string;
  /** The added machine's name. */
  added?: string;
  canApprove: boolean;
  runChief: boolean;
  /** The name of the machine this approver last approved. */
  lastApproved?: string;
}

export interface PairInviteStatus {
  /** Counts each mint and close: the page keeps its own state (Copied, the Name field) per session. */
  session: number;
  mint: "idle" | "minting" | "ready" | "failed";
  /** Why no invite was made: signed out, or the app's own sentence. */
  failure?: { signedOut?: boolean; text?: string };
  invite?: PairInviteShown;
  frames: PairInviteFrame[];
  approver: PairInviteApprover;
}
