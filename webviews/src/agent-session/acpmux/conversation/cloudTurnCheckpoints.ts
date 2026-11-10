// Back to before this turn for a Cloud chat (`cloud.turnCheckpoints`, off by default): after each
// completed turn the page asks the app for a whole-machine checkpoint (`chat.turnCheckpoint
// {afterSeq}`), and keeps the prompt rows that can be rewound up to date.
//
// The app's contract (CmuxNextAgentPane AgentPaneCloudTurnRewind.swift, cmux-cloud-api turns.rs): a
// prompt's turn number is its own transcript sequence, and the checkpoint before it is the one taken
// after the turn before it ended. `afterSeq` is that completed turn's last event (its turn summary's
// seq, as a fork through it uses); the checkpoint is named for turn `afterSeq + 1` and answered as
// `rowId: "user-<afterSeq + 1>"`. A rewind of `user-<n>` goes to the newest checkpoint numbered n or
// lower, so the checkpoint's row id is a mark between the turn it followed and the next prompt, not
// always that prompt's own row id (a sent prompt keeps its `local-…` row; another event can come
// between). `readyPromptRows` maps the marks to the prompt rows the page draws.
import type { AcpmuxRow } from "../model";
import { turnEndedBetween } from "../snapshotCache";
import { latestForkSeq } from "./messageMenu";

/// What the observer reads of each snapshot.
export type CheckpointSnapshot = {
  sessionId?: string;
  isWorking: boolean;
  turnsEnded?: number;
  rows: readonly { kind: string; seq?: number }[];
};

/// `chat.turnCheckpoint`'s answer, as far as the page reads it.
export type TurnCheckpointAnswer = {
  rowId?: unknown;
  retention?: { deleted?: unknown } | null;
};

/// The prompt row id (`user-<seq>`) of turn number `seq`.
const markRow = (seq: number) => `user-${seq}`;
const MARK_ROW = /^user-([1-9]\d{0,14})$/;
/// The turn number a `user-<seq>` row id names, or undefined.
export function markSeq(rowId: string): number | undefined {
  const match = MARK_ROW.exec(rowId);
  return match ? Number(match[1]) : undefined;
}
const AUTO_TURN = /^auto-t(0|[1-9]\d{0,14})-g(0|[1-9]\d{0,14})$/;

/// The ready marks after a checkpoint's answer: its `rowId` added, and the rows of the older
/// checkpoints its retention deleted (`auto-t<seq>-g<generation>`, turns.rs `auto_turn`) dropped.
/// A deleted turn of the answer's own number (an older generation's) leaves the new one ready.
export function withCheckpoint(
  ready: ReadonlySet<string> | undefined,
  answer: unknown,
): ReadonlySet<string> | undefined {
  if (!ready || !answer || typeof answer !== "object") return ready;
  const { rowId, retention } = answer as TurnCheckpointAnswer;
  const added = typeof rowId === "string" && markSeq(rowId) !== undefined ? rowId : undefined;
  const deleted = Array.isArray(retention?.deleted) ? retention.deleted : [];
  const dropped = new Set<string>();
  for (const turn of deleted) {
    const match = typeof turn === "string" ? AUTO_TURN.exec(turn) : null;
    if (match && markRow(Number(match[1])) !== added) dropped.add(markRow(Number(match[1])));
  }
  if ((!added || ready.has(added)) && ![...dropped].some((row) => ready.has(row))) return ready;
  const next = new Set([...ready].filter((row) => !dropped.has(row)));
  if (added) next.add(added);
  return next;
}

/// Asks for one checkpoint after each completed turn of the shown chat, fed every snapshot from the
/// page's snapshot handler (no timer, no effect). A turn ends as the page's other turn-end readers
/// see it (`turnEndedBetween`); its checkpoint goes once that turn's summary is in the rows, for the
/// summary's seq. One request is in flight at a time; a turn that ends meanwhile waits, and only the
/// newest waiting one goes. A failure is logged and changes nothing else.
export class CloudTurnCheckpoints {
  private on = false;
  private last: { session?: string; working: boolean; turnsEnded?: number } | undefined;
  /// The newest turn summary's seq when the shown chat's turn started: the ended turn's summary is
  /// a newer one.
  private before: number | undefined;
  private ended = false;
  private inFlight = false;
  private waiting: { session?: string; afterSeq: number } | undefined;
  private sent: { session?: string; afterSeq: number } | undefined;

  constructor(
    private readonly request: (afterSeq: number) => Promise<unknown>,
    private readonly answered: (answer: unknown, session: string | undefined) => void,
    private readonly log: (error: unknown) => void = (error) =>
      console.debug("cmux: the Cloud turn checkpoint failed", error),
  ) {}

  /// The handshake's `cloudTurnRewind` was present (on) or absent (off). Off never asks.
  setOn(on: boolean): void {
    this.on = on;
    if (!on) this.waiting = undefined;
  }

  observe(snapshot: CheckpointSnapshot): void {
    const next = { session: snapshot.sessionId, working: snapshot.isWorking, turnsEnded: snapshot.turnsEnded };
    const last = this.last;
    this.last = next;
    if (!last || last.session !== next.session) {
      this.ended = false;
      this.before = latestForkSeq(snapshot.rows);
      return;
    }
    if (turnEndedBetween(last, next)) this.ended = true;
    else if (!last.working && next.working) {
      this.ended = false;
      this.before = latestForkSeq(snapshot.rows);
    }
    if (!this.ended || next.working) return;
    const afterSeq = latestForkSeq(snapshot.rows);
    if (afterSeq === undefined || afterSeq === this.before) return;
    this.ended = false;
    this.before = afterSeq;
    if (this.on) this.ask({ session: next.session, afterSeq });
  }

  private ask(turn: { session?: string; afterSeq: number }): void {
    const sent = this.sent;
    if (sent && sent.session === turn.session && sent.afterSeq === turn.afterSeq) return;
    if (this.inFlight) {
      this.waiting = turn;
      return;
    }
    this.inFlight = true;
    this.sent = turn;
    const settle = () => {
      this.inFlight = false;
      const waiting = this.waiting;
      this.waiting = undefined;
      // A turn of a chat no longer shown is not asked for: the app checkpoints the shown chat.
      if (waiting && this.on && waiting.session === this.last?.session) this.ask(waiting);
    };
    let pending: Promise<unknown>;
    try {
      pending = this.request(turn.afterSeq);
    } catch (error) {
      pending = Promise.reject(error);
    }
    void pending.then(
      (answer) => {
        if (this.on && turn.session === this.last?.session) this.answered(answer, turn.session);
        settle();
      },
      (error) => {
        this.log(error);
        settle();
      },
    );
  }
}

const opensTurn = (row: AcpmuxRow) =>
  row.kind === "user" && !row.failed && !row.queued && !row.pending && row.steer !== "waiting";

/// The prompt rows the page draws that have a ready checkpoint before their turn, each with the
/// checkpoint's own row id (`user-<n>`, what `chat.rewindTurn {rowId}` names). A prompt opening a
/// turn takes the newest mark after the turn summary before it (0 before the first) and no later
/// than the prompt itself: its own seq when its row id is `user-<seq>`, else the next turn summary's
/// seq, else none. A summary with no seq (paged in from the transcript) bounds nothing that follows.
export function readyPromptRows(
  rows: readonly AcpmuxRow[],
  ready: ReadonlySet<string> | undefined,
): Map<string, string> {
  const shown = new Map<string, string>();
  const marks = [...(ready ?? [])]
    .map(markSeq)
    .filter((seq): seq is number => seq !== undefined)
    .sort((left, right) => left - right);
  if (!marks.length) return shown;
  // The newest mark in (after, through].
  const markIn = (after: number, through: number) => {
    let found: number | undefined;
    for (const mark of marks) {
      if (mark > through) break;
      if (mark > after) found = mark;
    }
    return found;
  };
  const place = (id: string, after: number, through: number) => {
    const mark = markIn(after, through);
    if (mark !== undefined) shown.set(id, markRow(mark));
  };
  let after: number | undefined = 0;
  let open: string | undefined;
  let prompt: string | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary") {
      if (prompt !== undefined && after !== undefined && row.seq !== undefined) place(prompt, after, row.seq);
      after = row.seq;
      open = undefined;
      prompt = undefined;
    } else if (open === undefined && opensTurn(row)) {
      open = row.id;
      const own = markSeq(row.id);
      if (own !== undefined) {
        if (after !== undefined) place(row.id, after, own);
      } else prompt = row.id;
    }
  }
  // The running turn's prompt: any mark after the turn before it.
  if (prompt !== undefined && after !== undefined) place(prompt, after, Number.MAX_SAFE_INTEGER);
  return shown;
}

/// `readyPromptRows` as a string, so the App rebuilds its actions only when the ready prompts change.
export const readyPromptKey = (shown: ReadonlyMap<string, string>) =>
  [...shown].map(([id, mark]) => `${id}\u0000${mark}`).join("\u0001");

/// The prompts back from `readyPromptKey`.
export function readyPromptMap(key: string): Map<string, string> {
  const shown = new Map<string, string>();
  for (const entry of key ? key.split("\u0001") : []) {
    const at = entry.indexOf("\u0000");
    shown.set(entry.slice(0, at), entry.slice(at + 1));
  }
  return shown;
}
