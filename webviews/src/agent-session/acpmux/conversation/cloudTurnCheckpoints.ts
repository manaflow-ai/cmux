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

/// The ready marks of each chat. `chat.select` switches the shown chat with no new handshake, so a
/// checkpoint answered for one chat never readies another's prompt of the same `user-<n>`. The
/// handshake's list is its chat's set; a handshake that names no chat (`unbound`) is the set of the
/// first chat the page then shows (`bindMarks`).
export type ChatMarks = {
  readonly bySession: ReadonlyMap<string, ReadonlySet<string>>;
  readonly unbound?: ReadonlySet<string>;
  /// Each chat's newest machine generation seen in a checkpoint or rewind answer.
  readonly generations?: ReadonlyMap<string, number>;
};

/// After a handshake: its `cloudTurnRewind` list (undefined when absent: no rewind at all) replaces
/// `session`'s set; the other chats' sets stay.
export function handshakeMarks(
  marks: ChatMarks | undefined,
  list: ReadonlySet<string> | undefined,
  session: string | undefined,
): ChatMarks | undefined {
  if (!list) return undefined;
  const bySession = new Map(marks?.bySession);
  const generations = marks?.generations;
  if (!session) return { bySession, unbound: list, generations };
  bySession.set(session, list);
  return { bySession, generations };
}

/// An unbound handshake list becomes `session`'s set (joining what that chat has already).
export function bindMarks(marks: ChatMarks | undefined, session: string | undefined): ChatMarks | undefined {
  if (!marks?.unbound || !session) return marks;
  const bySession = new Map(marks.bySession);
  bySession.set(session, new Set([...(marks.bySession.get(session) ?? []), ...marks.unbound]));
  return { bySession, generations: marks.generations };
}

/// The shown chat's ready marks: its own set, or the unbound handshake list before it is bound.
export function marksFor(marks: ChatMarks | undefined, session: string | undefined): ReadonlySet<string> | undefined {
  if (!marks) return undefined;
  return (session ? marks.bySession.get(session) : undefined) ?? marks.unbound ?? EMPTY;
}
const EMPTY: ReadonlySet<string> = new Set();

const AUTO_TURN_SEQ = /^auto-t(0|[1-9]\d{0,14})-g/;
const wholeNumber = (value: unknown) =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;

/// After a successful `chat.rewindTurn` of `session` to mark `rowId`: the machine is back at that
/// checkpoint, so every mark of that chat past it names a state the rewind discarded and is
/// dropped (a prompt mapped to one would restore undone work). The answer's `turn`
/// (`auto-t<seq>-g<generation>`) names the checkpoint restored; without it, `rowId`'s seq. Its
/// `generation` becomes the chat's: a checkpoint answered for an older generation (asked before
/// the rewind) is not added (`chatWithCheckpoint`).
export function chatAfterRewind(
  marks: ChatMarks | undefined,
  answer: unknown,
  session: string | undefined,
  rowId: string,
): ChatMarks | undefined {
  const bound = bindMarks(marks, session);
  if (!bound || !session) return bound;
  const fields = answer && typeof answer === "object" ? (answer as { turn?: unknown; generation?: unknown }) : {};
  const turn = typeof fields.turn === "string" ? AUTO_TURN_SEQ.exec(fields.turn) : null;
  const restored = turn ? Number(turn[1]) : markSeq(rowId);
  if (restored === undefined) return bound;
  const ready = bound.bySession.get(session) ?? EMPTY;
  const kept = new Set([...ready].filter((row) => (markSeq(row) ?? 0) <= restored));
  const bySession = new Map(bound.bySession);
  bySession.set(session, kept);
  const generation = wholeNumber(fields.generation);
  const generations = new Map(bound.generations);
  if (generation !== undefined) generations.set(session, Math.max(generation, generations.get(session) ?? 0));
  return { bySession, generations };
}

/// `withCheckpoint` for the chat the checkpoint was taken for. An answer of a machine generation
/// older than the chat's newest known (a checkpoint asked before a rewind) adds nothing.
export function chatWithCheckpoint(
  marks: ChatMarks | undefined,
  answer: unknown,
  session: string | undefined,
): ChatMarks | undefined {
  const bound = bindMarks(marks, session);
  if (!bound) return bound;
  const generation =
    answer && typeof answer === "object" ? wholeNumber((answer as { generation?: unknown }).generation) : undefined;
  const known = session ? bound.generations?.get(session) : undefined;
  if (generation !== undefined && known !== undefined && generation < known) return bound;
  if (!session) {
    const unbound = withCheckpoint(bound.unbound ?? EMPTY, answer);
    return unbound === (bound.unbound ?? EMPTY) ? bound : { ...bound, unbound };
  }
  const ready = bound.bySession.get(session) ?? EMPTY;
  const next = withCheckpoint(ready, answer);
  if (next === ready) return bound;
  const bySession = new Map(bound.bySession);
  bySession.set(session, next ?? EMPTY);
  const generations = new Map(bound.generations);
  if (generation !== undefined) generations.set(session, Math.max(generation, known ?? 0));
  return { bySession, generations };
}

/// Asks for one checkpoint after each completed turn of the shown chat, fed every snapshot from the
/// page's snapshot handler (no timer, no effect). A turn ends as the page's other turn-end readers
/// see it (`turnEndedBetween`); its checkpoint goes once that turn's summary is in the rows, for the
/// summary's seq. One request is in flight at a time; a turn that ends meanwhile waits, and only the
/// newest waiting one goes. A failure is logged and changes nothing else.
export class CloudTurnCheckpoints {
  private on = false;
  private last: { session?: string; working: boolean; turnsEnded?: number; newest?: number } | undefined;
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
    const next = {
      session: snapshot.sessionId,
      working: snapshot.isWorking,
      turnsEnded: snapshot.turnsEnded,
      newest: latestForkSeq(snapshot.rows),
    };
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
      this.before = next.newest;
      // A turn started: a waiting checkpoint would capture this turn's changes, so it is dropped
      // (this turn's end asks for its own).
      this.waiting = undefined;
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
      // The app checkpoints the shown chat's machine as it is at the request, so a waiting turn
      // goes only if its chat is still shown, idle (no turn running) and that turn's end is still
      // its newest; otherwise it is dropped, and the next turn end asks for its own.
      const last = this.last;
      if (
        waiting &&
        this.on &&
        last &&
        waiting.session === last.session &&
        !last.working &&
        waiting.afterSeq === last.newest
      )
        this.ask(waiting);
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
/// than the prompt itself: its own seq (its `user-<seq>` row id, else its row's seq). A prompt with
/// no seq yet (a sent prompt's `local-…` row) takes only the checkpoint taken right after the turn
/// before it (that summary's seq + 1), never a later one: a later mark can be a state a rewind
/// discarded. A summary with no seq (paged in from the transcript) bounds nothing that follows.
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
  let after: number | undefined = 0;
  let open: string | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary") {
      after = row.seq;
      open = undefined;
    } else if (open === undefined && opensTurn(row)) {
      open = row.id;
      if (after === undefined) continue;
      const own = markSeq(row.id) ?? row.seq;
      const mark = markIn(after, own ?? after + 1);
      if (mark !== undefined) shown.set(row.id, markRow(mark));
    }
  }
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
