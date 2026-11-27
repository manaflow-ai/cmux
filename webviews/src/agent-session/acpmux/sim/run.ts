// The chat simulator's model run (sim/README.md): folds a scenario's records one at a time with the
// pane's own reducer (AcpmuxDirectClient.replay, as session replay does), shapes each snapshot with
// the pane's own turn view (turnViewFrom, built on the last, as App.tsx does) and places it with the
// pane's own layout (layoutConversation: the gap over each row the virtual stack draws). After every
// step it probes the drawn rows: the gap over each, which rows are folded or open, which rows left
// the view (folded into a line) and when, relative to their turn's end, and which rows above the
// newest were rebuilt. The browser lane (test/browser/chat-sim.harness.tsx) draws the same rows in
// the real VirtualTranscript and measures them with getBoundingClientRect.
//
// No DOM is needed: this runs under plain `bun` and scales to 10k+ rows (a long run's trace holds
// the probes, not every row, past `rowsInTraceUpTo`).
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import { preserveScrollAnchorTop } from "../conversation/scrollAnchor";
import { turnViewFrom, type TurnView } from "../conversation/turns";
import {
  layoutConversation,
  type AcpmuxRow,
  type AcpmuxSnapshot,
  type ConversationLayout,
  rowFrameKey,
} from "../model";
import { acpmuxSendCall } from "../conversation/acpmuxSends";
import {
  MARK_STEP,
  ROW_GAP_LOOKS,
  TRANSCRIPT_BLOCK_GAP,
  TRANSCRIPT_TURN_GAP,
  transcriptGap,
  TRANSCRIPT_RUN_GAP,
} from "../transcriptGrid";
import { STARTED_LINE_NAMES, withSubagentLines, type DoneLineCache } from "../subagents/runningTray";
import { SUBAGENT_STARTED } from "../subagents/subagentRows";
import { subagentNamed } from "../subagents/subsessions";
import { checkIntegrity, opensTurn as integrityTurnOpens, type IntegrityRule } from "./integrity";
import type { SimScenario, SimStep } from "./script";

/** One drawn row as a probe sees it. */
export type RowProbe = {
  id: string;
  kind: string;
  /** The turn the row first appeared in (1-based; 0: before the first prompt). */
  turn: number;
  /** The gap the layout leaves over it (px at interface scale 1). */
  gap: number;
  /** `open`, `closed` (a fold: Worked for, a run, a folded reply) or `` (no fold). */
  fold: string;
  /** The row is the running turn's live line. */
  live?: boolean;
  /** The row opens its turn (its prompt or incoming message). */
  opens?: boolean;
  /** The opening row is another agent's line (a notice or message), not the person's prompt. */
  received?: boolean;
  /** Another agent's line this row draws (its `incoming` kind, or `offer` for a received offer's result), wherever it falls. */
  incoming?: string;
  /** Another agent's message the turn received after its opening row (`received`), or a send to one (`sent`): an
   *  activity row, which stands `toolGap` (ST-02). */
  message?: "received" | "sent";
  /** The gap a tool row would stand in this row's place, under the same drawn row (transcriptGrid.ts transcriptGap
   *  over MARK_STEP). Set on `message` rows. */
  toolGap?: number;
  /** The row is the turn's header ("Working for" / "Worked for"), or, before it has one, its first row under the prompt. */
  head?: boolean;
  text?: string;
  /** A "Worked for" line's or a turn footer's status: `completed`, `failed`, `cancelled`. */
  status?: string;
  /** The turn footer carries the turn's error. */
  error?: boolean;
  /** The calls in the row that still read as running (pending or in progress, not a background shell). */
  running?: number;
  /** The calls the row holds. */
  calls?: number;
  /** Browser lane only: the row's measured top, bottom and the visible gap over it. */
  top?: number;
  bottom?: number;
  drawnGap?: number;
};

/** A row that folded away or closed: when, and why that is or is not allowed. */
export type FoldEvent = {
  id: string;
  kind: string;
  turn: number;
  /** `hidden`: the row left the drawn rows (folded under a line); `closed`: its fold went from open to closed. */
  how: "hidden" | "closed";
  /** ms of virtual time from the fold to its turn's first end record: > 0 means mid-turn. */
  beforeTurnEndMs?: number;
  /** `turn-end`: at or after its turn's end; `sibling`: a later row of the same running turn closed a finished run
   *  (the `runs` arm of live-turn-work, by design); `final-answer`: the turn's final answer (Codex's
   *  `final_answer` phase) began, which starts the turn's folded look before its `turn_result` (turns.ts,
   *  by design); `violation`: anything else mid-turn. */
  verdict: "turn-end" | "sibling" | "remapped" | "final-answer" | "violation";
};

export type Violation = {
  rule:
    | "a-turn-gap"
    | "a-head-gap"
    | "d-received-gap"
    | "b-mid-turn-fold"
    | "b-mid-turn-shrink"
    | "c-rerender"
    | "d-blank"
    | "d-shift"
    | "d-started-pill"
    | "d-started-lines"
    | "d-action-only"
    | "d-steer-order"
    | "d-row-key"
    | IntegrityRule;
  step: number;
  at: number;
  label: string;
  rowId: string;
  detail: string;
};

/** One line of the JSONL trace. */
export type StepTrace = {
  step: number;
  /** ms of virtual time since the scenario's first step. */
  t: number;
  label: string;
  seq?: number;
  working: boolean;
  /** The turn running (or last started). */
  turn: number;
  turnEnded: boolean;
  rowCount: number;
  /** Rows the turn view shaped anew this step: its rows less those it took over from the last view
   * (`reusedRows`). It stays near a turn's size however long the chat is. */
  shaped: number;
  folds: FoldEvent[];
  /** Rows above the newest changed row whose drawn object was rebuilt with no change of their own. */
  rerendered: string[];
  violations: Violation[];
  rows?: RowProbe[];
};

/// A layout shift a reader following the chat sees: rows drawn at both steps above the reader's anchor
/// (the lowest such row that is not a live line) moved relative to it, because a row between them came,
/// went, folded or changed height. Rows arriving under the anchor and text streaming into it are no
/// shift (CLS-style: only unexpected moves of drawn content).
export type ShiftEvent = {
  step: number;
  at: number;
  label: string;
  /// `turn-end`: the turn's end records (turn_end, turn_result, status ready) caused it; `mid-turn`: anything else.
  phase: "turn-end" | "mid-turn";
  /// Drawn rows (not live lines) whose top moved.
  moved: number;
  /// The largest move of one of them (px).
  px: number;
  /// How much shorter the chat got (px): what a follow pinned to the bottom moves every row above down by.
  back: number;
  /// The first row that changed over them: `+kind id` came, `-kind id` went, `~kind id` changed height.
  cause: string;
};

/// A row drawn for less than a second (FLASH_MS) of virtual time: it came and went before a reader
/// could read it.
export type FlashEvent = {
  id: string;
  kind: string;
  shownMs: number;
  step: number;
  at: number;
  label: string;
  phase: "turn-end" | "mid-turn";
};

/// Rows drawn for less than this read as a flash (Leo, 2026-11-22: "sub-second in and out bullshit").
export const FLASH_MS = 1_000;

export type SimOptions = {
  /** Width the layout places rows at. */
  width?: number;
  /** Include every row's probe in the trace while the chat has at most this many rows (default 400). */
  rowsInTraceUpTo?: number;
  /** Each step's trace line, as it is made (a CLI streams them to a file). */
  onStep?: (trace: StepTrace) => void;
  /** Measures the rows (the browser lane): returns each drawn row's top and bottom, in the order given. */
  measure?: (
    rows: readonly AcpmuxRow[],
    step: SimStep,
  ) => readonly ({ top: number; bottom: number } | undefined)[] | undefined;
  /** Integrity rules (integrity.ts) the scenario does not hold by design (a cancelled reply may stop inside `**`). */
  exemptIntegrity?: readonly IntegrityRule[];
};

export type SimResult = {
  scenario: string;
  steps: number;
  /** Rows drawn at the end (finished turns folded). */
  rows: number;
  /** Rows the reducer holds at the end, before the turn view folds them. */
  recordRows: number;
  virtualMs: number;
  wallMs: number;
  violations: Violation[];
  folds: FoldEvent[];
  /// Layout shifts and sub-second rows (ShiftEvent, FlashEvent).
  shifts: ShiftEvent[];
  flashes: FlashEvent[];
  traces: StepTrace[];
};

/** The most room another agent's line may have against a tool row beside it (rule d): the step pitch's 0,
 *  with the 8 a row stands under a status line to spare. */
const RECEIVED_STEP_GAP = 8;
/** Rows drawn on the tool rows' line (model.ts isStepRow, the one-line kinds). */
const STEP_KINDS = new Set(["activity", "subagent", "messageRun", "laneNoticeBatch", "pendingMessages"]);
const LIVE_KINDS = new Set(["typing", "working", "thinking"]);
const isLive = (row: AcpmuxRow) => row.below === true || row.kind === "typing" || row.id.endsWith("-live");
const foldOf = (row: AcpmuxRow): string => {
  if (row.foldOpen !== undefined) return row.foldOpen ? "open" : "closed";
  if (row.runOpen !== undefined) return row.runOpen ? "open" : "closed";
  if (row.folded !== undefined) return row.folded ? "closed" : "open";
  return "";
};
const opensTurn = (row: AcpmuxRow) => row.kind === "user" && row.incoming?.kind !== "hidden";
/// A tool run whose every call sends another agent a message (`acpmux send`): its "Sent to" line.
const isSendRow = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool) &&
  (row.items ?? []).every((item) => !item.tool || acpmuxSendCall(item.tool) !== undefined);
const isHeader = (row: AcpmuxRow) => row.kind === "worked" || (row.kind === "working" && row.below !== true);
const textOf = (row: AcpmuxRow) => (typeof row.text === "string" ? row.text.slice(0, 80) : undefined);

/// Measures nothing: every row one line tall, so the model's tops are the gaps' sums.
const LINE = (row: AcpmuxRow) =>
  row.kind === "assistant" ? 23 * Math.max(1, Math.ceil((row.text?.length ?? 0) / 90)) : 22;

/// The run, a step at a time: `advance(index)` then `check(index, measured?)` for each step, then `result()`.
export function createSimulation(scenario: SimScenario, options: SimOptions = {}) {
  const started = performance.now();
  const width = options.width ?? 720;
  const rowsUpTo = options.rowsInTraceUpTo ?? 400;
  let snapshot: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.replay(scenario.sessionId, [...scenario.events], (next) => (snapshot = next));
  const bySeq = new Map<number, EventRecord>(scenario.events.map((event) => [event.seq, event]));
  // The reducer settles a turn at turn_end; turn_result replaces that summary, or settles it when
  // the end was absent. Sequence determines order even when adjacent records share a timestamp.
  const turnEnds = new Map<number, EventRecord>();
  {
    let turn = 0;
    let ended = true;
    for (const event of [...scenario.events].sort((a, b) => a.seq - b.seq)) {
      if (event.kind === "user_message" && isTurnPrompt(event) && ended) {
        turn += 1;
        ended = false;
      }
      if ((event.kind === "turn_end" || event.kind === "turn_result") && !turnEnds.has(turn)) turnEnds.set(turn, event);
      if (event.kind === "turn_result" || endsTurn(event)) ended = true;
    }
  }
  const first = scenario.steps[0]?.at ?? 0;
  let turn = 0;
  let turnEnded = true;
  let throughSeq = -Infinity;
  const agentSent = new Set<number>();
  const settledForFolding = (own: number) =>
    own < turn || turnEnded || throughSeq >= (turnEnds.get(own)?.seq ?? Infinity);
  // Session replay never reports working (workingNow() is false while replayThrough is set), so the
  // runner tracks it from the records as the live pane would see it: running from `status running` or
  // `turn_started` to `status ready` or `turn_result`.
  let working = false;
  let workingSince: number | undefined;
  let last: TurnView | undefined;
  let previous: { rows: readonly AcpmuxRow[]; layout: ConversationLayout } | undefined;
  let prevRows: readonly AcpmuxRow[] = [];
  let prevProbeAt: (RowProbe | undefined)[] = [];
  const headAt = new Map<number, number>();
  const rowTurn = new Map<string, number>();
  const traces: StepTrace[] = [];
  const violations: Violation[] = [];
  const allFolds: FoldEvent[] = [];
  // The message ids streamed since the last turn ended (the integrity check's `messageOf`).
  const turnMessages = new Set<string>();
  const exempt = new Set<string>(options.exemptIntegrity ?? []);
  const cache = new Map();
  // The subagent lines the running tray puts in the transcript (App.tsx `withSubagentLines`, on by
  // default): each turn's "started working" line and each subagent's end line.
  const subagentLines: DoneLineCache = new Map();
  // (d) each drawn row's top at the step before, and whether the chat drew any row yet.
  const tops = new Map<string, number>();
  let drewRows = false;
  // The browser lane: each row's drawn height at the last measured step, to see a row collapse.
  const drawnHeights = new Map<string, number>();
  // The open folds, one object for the whole run as App.tsx keeps its `folds` state: a fresh set each
  // step reads as a fold change, and the turn view then shapes every turn again (no reuse).
  let folds = new Set<string>();

  let current: { rows: readonly AcpmuxRow[]; layout: ConversationLayout } | undefined;
  let shaped = 0;
  // Churn: the last checked rows' layout, and since when (virtual ms) each drawn row has been drawn.
  let prevLayout: ConversationLayout | undefined;
  const drawnSince = new Map<string, number>();
  const shifts: ShiftEvent[] = [];
  const flashes: FlashEvent[] = [];
  /** Folds step `index`'s record (or reader action) and shapes and places the rows: the rows to draw. */
  const advance = (index: number): readonly AcpmuxRow[] | undefined => {
    const step = scenario.steps[index]!;
    if (step.type === "event") {
      throughSeq = step.seq;
      const event = bySeq.get(step.seq);
      // A message that comes in while the turn runs steers it (turns.ts draws it inside that turn's
      // work); only one after the turn ended opens a turn.
      if (event?.kind === "user_message" && isTurnPrompt(event) && turnEnded) {
        turn += 1;
        turnEnded = false;
      }
      if (event?.kind === "turn_result" || (event && endsTurn(event))) turnEnded = true;
      // The agent sent the running turn something of its own (a thought, a call, a message): a turn
      // that ends showing none of it lost its work (d-action-only). One it sent nothing draws its
      // prompt and footer only, as map.ts's empty-turn case expects.
      if (event?.dir === "in" && !turnEnded) agentSent.add(turn);
      const messageId = event?.kind === "agent_message_chunk" ? event.msg?.params?.update?.messageId : undefined;
      if (typeof messageId === "string") turnMessages.add(messageId);
      const status = event?.kind === "status" ? event.msg?.status : undefined;
      if (event?.kind === "turn_started" || status === "running") {
        if (!working) workingSince = event!.at;
        working = true;
      }
      if (event?.kind === "turn_result" || status === "ready" || status === "idle") {
        working = false;
        workingSince = undefined;
      }
      client.seekReplay(step.seq);
    } else if ("open" in step.reader) folds = new Set([...folds, step.reader.open]); // App.tsx sets a new `folds`

    const snap = snapshot;
    if (!snap) {
      current = undefined;
      return undefined;
    }
    const view = turnViewFrom(
      withSubagentLines(snap.rows, subagentLines) as AcpmuxRow[],
      folds,
      {
        now: step.at,
        working: working || snap.isWorking,
        clockOffset: snap.clockOffsetMs,
        turnStartedAtMs: snap.turnStartedAtMs ?? workingSince,
        agentFamily: scenario.family,
        waitingSteers: snap.waitingSteers,
      },
      last,
    );
    shaped = view === last ? 0 : view.rows.length - (view.reusedRows ?? 0);
    last = view;
    const rows = view.rows;
    const layout = layoutConversation(rows, width, cache, LINE, undefined, previous);
    previous = { rows, layout };
    current = { rows, layout };
    return rows;
  };
  /** Probes and checks the rows `advance(index)` made; `measured` is their drawn boxes (the browser lane). */
  const check = (index: number, measured?: readonly ({ top: number; bottom: number } | undefined)[]) => {
    const step = scenario.steps[index]!;
    if (!current) return;
    const { rows, layout } = current;

    // Rows the turn view kept (the same objects at the same places) need no new probe: nothing over them
    // changed, so nothing in them can have folded or moved. Probing only from the first row that changed
    // keeps a step's cost near constant on a 10k-row chat. A measured (browser) step probes every row.
    let stable = 0;
    if (!measured) {
      const shared = Math.min(rows.length, prevRows.length);
      while (stable < shared && rows[stable] === prevRows[stable]) stable += 1;
    }
    const probeAt = prevProbeAt.slice(0, stable);
    for (const [own, at] of headAt) if (at >= stable) headAt.delete(own);
    let prevDrawn: RowProbe | undefined;
    for (let at = stable - 1; at >= 0 && !prevDrawn; at -= 1) prevDrawn = probeAt[at];
    const now = new Map<string, { row: AcpmuxRow; fold: string; index: number }>();
    for (let at = stable; at < rows.length; at += 1) {
      const row = rows[at]!;
      // A live line's id ("thinking-live") is reused by every turn: it belongs to the running one.
      if (!rowTurn.has(row.id) || isLive(row) || LIVE_KINDS.has(row.kind)) rowTurn.set(row.id, turn);
      const own = rowTurn.get(row.id)!;
      const fold = foldOf(row);
      now.set(row.id, { row, fold, index: at });
      if (measured ? !measured[at] : layout.heights[at] === 0) continue;
      const probe: RowProbe = { id: row.id, kind: row.kind, turn: own, gap: layout.gaps?.[at] ?? 0, fold };
      if (isLive(row)) probe.live = true;
      if (opensTurn(row)) probe.opens = true;
      if (opensTurn(row) && (row.incoming || row.received)) probe.received = true;
      if (row.incoming || row.received) probe.incoming = row.incoming?.kind ?? "offer";
      // Another agent's line under a row of its own turn (a message steered in mid-turn, or the message that opened a
      // finished turn drawn under that turn's "Worked for"), or a send: an activity row (ST-02).
      const message =
        row.kind === "user" && (row.incoming || row.received) && prevDrawn?.turn === own
          ? "received"
          : isSendRow(row)
            ? "sent"
            : undefined;
      if (message) {
        probe.message = message;
        let aboveAt = at - 1;
        while (aboveAt >= 0 && layout.heights[aboveAt] === 0) aboveAt -= 1;
        if (aboveAt >= 0 && layout.marks)
          probe.toolGap = transcriptGap(layout.marks[aboveAt]!, MARK_STEP) * (layout.scale ?? 1);
      }
      // The turn's head: its header line, or the first row under its opening row.
      if (!headAt.has(own) && ((prevDrawn?.opens && prevDrawn.turn === own) || isHeader(row))) {
        probe.head = true;
        headAt.set(own, at);
      }
      const words = textOf(row);
      if (words) probe.text = words;
      if ((row.kind === "worked" || row.kind === "turnSummary") && row.status) probe.status = row.status;
      if (row.kind === "turnSummary" && row.error) probe.error = true;
      const calls = (row.items ?? []).filter((item) => item.tool);
      if (calls.length) {
        probe.calls = calls.length;
        const running = calls.filter(
          (item) => (item.tool!.status === "pending" || item.tool!.status === "in_progress") && !item.tool!.background,
        ).length;
        if (running) probe.running = running;
      }
      const box = measured?.[at];
      if (box) {
        probe.top = box.top;
        probe.bottom = box.bottom;
        if (prevDrawn?.bottom !== undefined) probe.drawnGap = Math.round((box.top - prevDrawn.bottom) * 100) / 100;
      }
      probeAt[at] = probe;
      (probe as RowProbe & { above?: RowProbe }).above = prevDrawn;
      prevDrawn = probe;
    }

    const stepViolations: Violation[] = [];
    const flag = (rule: Violation["rule"], rowId: string, detail: string) =>
      stepViolations.push({ rule, step: index, at: step.at - first, label: step.label, rowId, detail });

    // (a) a turn's first row stands the turn gap under the turn before it, and its head a gap under that.
    for (let at = stable; at < rows.length; at += 1) {
      const probe = probeAt[at] as (RowProbe & { above?: RowProbe }) | undefined;
      const above = probe?.above;
      if (!probe || !above) continue;
      const gap = probe.drawnGap ?? probe.gap;
      // A person's prompt takes the turn gap; another agent's line (a notice, a message) the block gap
      // under the turn before's reply, the run gap under its footer row (transcriptSpacing.ts
      // footer-to-received; transcriptGrid.ts FOOTER_WORKING_GAP_LOOKS), by design.
      const wantUnder = (row: RowProbe | undefined) =>
        probe.received
          ? row?.kind === "turnSummary"
            ? TRANSCRIPT_RUN_GAP
            : TRANSCRIPT_BLOCK_GAP
          : TRANSCRIPT_TURN_GAP;
      const want = wantUnder(above);
      // The turn's "Working for" (or "Worked for") line drawn over the message that opened it (turns.ts
      // `shapeLiveTurn`): that line is the turn's top, so it stands the gap under the turn before.
      if (probe.opens && (above.id === `working-${probe.id}` || above.id === `worked-${probe.id}`)) {
        const before = (above as RowProbe & { above?: RowProbe }).above;
        const headGap = above.drawnGap ?? above.gap;
        const headWant = wantUnder(before);
        if (before && headGap < headWant - 0.5)
          flag(
            "a-turn-gap",
            above.id,
            `${above.kind} over ${probe.kind} opens turn ${probe.turn} ${headGap}px under ${before.kind} ${before.id} (want >= ${headWant})`,
          );
        continue;
      }
      if (probe.opens && above.turn !== probe.turn && gap < want - 0.5)
        flag(
          "a-turn-gap",
          probe.id,
          `${probe.kind} opens turn ${probe.turn} ${gap}px under ${above.kind} ${above.id} (want >= ${want})`,
        );
      // A turn's head (Thinking, Working for) under the line that opened it: the block gap under a person's
      // prompt; under another agent's notice or message, the gap "Worked for" stands under any one-line row
      // (transcriptGrid.ts ROW_GAP_LOOKS.shipped.workedAfterLine, #48591).
      const headWant = above.received ? ROW_GAP_LOOKS.shipped.workedAfterLine : TRANSCRIPT_BLOCK_GAP;
      if (probe.head && above.opens && gap < headWant - 0.5)
        flag(
          "a-head-gap",
          probe.id,
          `${probe.kind} heads turn ${probe.turn} ${gap}px under its opening ${above.kind} (want >= ${headWant})`,
        );
    }

    // (d) another agent's line among tool rows sits on their pitch, as a tool row does, never with a
    // message's room over or under it (Leo, 2026-11-22: "sometimes you get these way-too-big gaps. i
    // think it's the message recieving not properly getting treated like the tool call ish thing it
    // should be and instead as if it were a message?").
    for (let at = stable; at < rows.length; at += 1) {
      const probe = probeAt[at] as (RowProbe & { above?: RowProbe }) | undefined;
      const above = probe?.above;
      if (!probe || !above) continue;
      const gap = probe.drawnGap ?? probe.gap;
      const lineAbove = above.incoming !== undefined && above.incoming !== "offer";
      const lineHere = probe.incoming !== undefined && probe.incoming !== "offer";
      if (!(lineAbove || lineHere)) continue;
      // Under its own turn's "Working for" / "Worked for" the line is that turn's first step: flush,
      // as a tool row is under it; the live line under it stands a step's gap, not a head's.
      const ownHead = (line: RowProbe | undefined, user: RowProbe) => line?.id === `worked-${user.id}`;
      if (lineHere && ownHead(above, probe) && gap > 0.5) {
        flag(
          "d-received-gap",
          probe.id,
          `user (${probe.incoming}) ${gap}px under its own turn's ${above.kind} (want 0)`,
        );
        continue;
      }
      if (gap <= RECEIVED_STEP_GAP + 0.5) continue;
      const step = (row: RowProbe) =>
        STEP_KINDS.has(row.kind) || (row.incoming !== undefined && row.incoming !== "offer");
      const underOwnHead = (row: RowProbe & { above?: RowProbe }) => ownHead(row.above, row);
      if (
        (lineHere && step(above)) ||
        (lineAbove && (step(probe) || probe.live) && (!probe.live || underOwnHead(above)))
      )
        flag(
          "d-received-gap",
          probe.id,
          `${probe.kind}${lineHere ? ` (${probe.incoming})` : ""} ${gap}px under ${above.kind}${lineAbove ? ` (${above.incoming})` : ""} among tool rows (want <= ${RECEIVED_STEP_GAP})`,
        );
    }

    // (b) folds: a row that left the drawn rows, or whose fold closed.
    const folds: FoldEvent[] = [];
    for (let at = stable; at < prevRows.length; at += 1) {
      const wasRow = prevRows[at]!;
      const id = wasRow.id;
      const was = { row: wasRow, fold: foldOf(wasRow), index: at };
      const is = now.get(id);
      const hidden = !is;
      const closed = is && was.fold === "open" && is.fold === "closed";
      if (!hidden && !closed) continue;
      if (hidden && (isLive(was.row) || LIVE_KINDS.has(was.row.kind))) continue;
      const own = rowTurn.get(id) ?? 0;
      const end = turnEnds.get(own);
      const ended = settledForFolding(own);
      let verdict: FoldEvent["verdict"] = "turn-end";
      if (!ended) {
        // A finished run that the agent's next paragraph closed (live-turn-work's `runs` arm, by design; #48597:
        // a run stays open until the agent's next paragraph): the row is gone into a closed run row of its
        // turn, or closed itself, with a reply of its turn under it.
        const paragraphAfter = (from: number) =>
          rows.some((row, at) => at > from && rowTurn.get(row.id) === own && row.kind === "assistant");
        const closedRun = hidden
          ? rows.findIndex((row) => rowTurn.get(row.id) === own && row.id !== id && foldOf(row) === "closed")
          : -1;
        const laterSibling = hidden ? closedRun >= 0 && paragraphAfter(closedRun) : paragraphAfter(is!.index);
        const remapped =
          hidden &&
          was.row.kind === "assistant" &&
          !!was.row.text &&
          rows.some((row) => row.kind === "assistant" && row.text === was.row.text);
        // The turn's final answer is streaming: its commentary folds under "Worked for" as the answer
        // starts, not at turn_result (turns.ts "The final answer starts the folded presentation").
        const answering = rows.some((row) => rowTurn.get(row.id) === own && row.assistantPhase === "final_answer");
        // acpmux replaced the message (`message_superseded`, a harness retry): its rows go by design.
        const superseded = step.type === "event" && bySeq.get(step.seq)?.kind === "message_superseded";
        if (remapped || superseded) verdict = "remapped";
        else if (answering) verdict = "final-answer";
        else if (was.row.kind !== "assistant" && laterSibling) verdict = "sibling";
        else verdict = "violation";
      }
      const event: FoldEvent = {
        id,
        kind: was.row.kind,
        turn: own,
        how: hidden ? "hidden" : "closed",
        ...(end !== undefined ? { beforeTurnEndMs: end.at - step.at } : {}),
        verdict,
      };
      folds.push(event);
      if (verdict === "violation")
        flag(
          "b-mid-turn-fold",
          id,
          `${was.row.kind} of turn ${own} ${event.how} ${end !== undefined ? `${end.at - step.at} ms before its ${end.kind}` : "in a turn that never ends"}${was.row.text ? `: "${was.row.text.slice(0, 50)}"` : ""}`,
        );
    }

    // (b) in the browser lane: a row of a running turn that the stack draws much shorter than at the step
    // before (a collapse the reader sees) with its own fold unchanged. A finished run's closing is (b) above.
    if (measured) {
      for (let at = 0; at < rows.length; at += 1) {
        const row = rows[at]!;
        const box = measured[at];
        if (!box) continue;
        const height = box.bottom - box.top;
        const was = drawnHeights.get(row.id);
        drawnHeights.set(row.id, height);
        const own = rowTurn.get(row.id) ?? 0;
        if (was === undefined || was - height < 12 || isLive(row) || LIVE_KINDS.has(row.kind)) continue;
        if (settledForFolding(own)) continue;
        const before = prevRows.find((old) => old.id === row.id);
        if (before && foldOf(before) !== foldOf(row)) continue;
        flag(
          "b-mid-turn-shrink",
          row.id,
          `${row.kind} of turn ${own} drawn ${Math.round(was)}px -> ${Math.round(height)}px before its turn ended`,
        );
      }
    }

    // (d) what Leo saw from 22:05 to 22:11Z on 2026-11-22 (test/fixtures/chat-sim/leo-2205-subagent-burst.ndjson):
    // "ENTIRE THING FUCKING BLANKED AND FUCKING SHIFTED AND PLAYED SOME BULLSHIT ANIMATIONS WHEN YOU
    // STARTED A SUBAGENT"; "WHY DID IT FUCKING DISPLAY NOTHING THEN COPY BUTTONS THEN YOU SENT SHIT THEN
    // MY STEER WENT UNDER IT".
    if (rows.length > 0) drewRows = true;
    else if (drewRows) flag("d-blank", "", "the chat drew no row after it drew some");
    // (d) two rows the transcript draws under one React key (`rowFrameKey`): React keeps one element for
    // both, and the other stays painted where it was placed before, over the rows that took its place
    // (cmux#59809: a second "Worked for" of one background turn drawn across a bullet of the reply).
    {
      const keys = new Set<string>();
      for (const row of rows) {
        const key = rowFrameKey(row);
        if (keys.has(key)) flag("d-row-key", row.id, `a second row under the key ${key}`);
        keys.add(key);
      }
    }
    // A prepend (including the first turn's date line appearing after an hour) moves document
    // coordinates. VirtualTranscript holds the first visible row at its old viewport position.
    // Probe from the top so a change below that row still registers as movement.
    const scrollCorrection =
      prevLayout && rows[0]?.id !== prevRows[0]?.id
        ? (preserveScrollAnchorTop({
            oldLayout: prevLayout,
            newLayout: layout,
            oldRows: prevRows,
            newRows: rows,
            liveTop: 0,
            anchorTop: 0,
          }) ?? 0)
        : 0;
    const ownTurn = (row: AcpmuxRow) => rowTurn.get(row.id) ?? 0;
    const lines = new Map<string, string>();
    for (let at = 0; at < rows.length; at += 1) {
      const row = rows[at]!;
      const live = isLive(row) || LIVE_KINDS.has(row.kind);
      // A settled row (two or more turns back, not live) stands where it stood: nothing above it moved.
      const top = layout.tops[at]! - scrollCorrection;
      const was = tops.get(row.id);
      if (!live && was !== undefined && Math.abs(was - top) > 0.5 && ownTurn(row) < turn - 1)
        flag("d-shift", row.id, `${row.kind} of turn ${ownTurn(row)} moved ${Math.round(top - was)}px`);
      if (row.kind !== SUBAGENT_STARTED) continue;
      // A start line names at most STARTED_LINE_NAMES subagents, each named, each one this pane saw start.
      const agents = row.subagents ?? [];
      const named = agents.slice(0, row.startedNamed ?? agents.length);
      if (named.length > STARTED_LINE_NAMES)
        flag("d-started-pill", row.id, `names ${named.length} subagents (want <= ${STARTED_LINE_NAMES})`);
      for (const agent of agents)
        if (!subagentNamed(agent) || agent.startUnseen)
          flag(
            "d-started-pill",
            row.id,
            `${agent.startUnseen ? "a subagent whose start it never read" : "an unnamed subagent"}`,
          );
      // One start line a turn.
      const key = `${ownTurn(row)}\u0000${row.inBackground ?? ""}`;
      const other = lines.get(key);
      if (other !== undefined)
        flag("d-started-lines", row.id, `a second start line in turn ${ownTurn(row)} (first ${other})`);
      else lines.set(key, row.id);
    }
    tops.clear();
    for (let at = 0; at < rows.length; at += 1) tops.set(rows[at]!.id, layout.tops[at]!);
    // A steer stands where it was sent: no row of its turn that came after it is drawn over it.
    for (let at = 0; at < rows.length; at += 1) {
      const steer = rows[at]!;
      if (steer.kind !== "user" || steer.steer === undefined) continue;
      for (let above = 0; above < at; above += 1) {
        const row = rows[above]!;
        if (isLive(row) || LIVE_KINDS.has(row.kind) || ownTurn(row) !== ownTurn(steer)) continue;
        if (row.at > steer.at + 1)
          flag("d-steer-order", steer.id, `${row.kind} ${row.id} (+${row.at - steer.at} ms after it) drawn over it`);
      }
    }
    // A turn that ended draws more than its prompt and its action row.
    if (step.type === "event" && bySeq.get(step.seq)?.kind === "turn_result") {
      const own = rows.filter((row) => ownTurn(row) === turn);
      if (
        agentSent.has(turn) &&
        own.length > 0 &&
        own.every((row) => row.kind === "user" || row.kind === "turnSummary")
      )
        flag("d-action-only", own.at(-1)!.id, `turn ${turn} ended with only its prompt and action row`);
    }

    // (c) rows above the newest change rebuilt with nothing of their own changed (same id, version and fold).
    const rerendered: string[] = [];
    const before = new Map<string, AcpmuxRow>();
    for (let at = stable; at < prevRows.length; at += 1) before.set(prevRows[at]!.id, prevRows[at]!);
    let newest = rows.length;
    for (let at = stable; at < rows.length && newest === rows.length; at += 1) {
      const row = rows[at]!;
      const was = before.get(row.id);
      if (!was || was.version !== row.version || foldOf(was) !== foldOf(row)) newest = at;
    }
    for (let at = stable; at < newest; at += 1) {
      const row = rows[at]!;
      const was = before.get(row.id);
      if (was && was !== row && !isLive(row) && !LIVE_KINDS.has(row.kind) && rowTurn.get(row.id)! < turn - 1)
        rerendered.push(row.id);
    }
    for (const id of rerendered) flag("c-rerender", id, "rebuilt above the newest change, two or more turns back");

    // (i) bubble integrity (integrity.ts) on the turn that ended, at its end and at the run's last step: one
    // message is one bubble, no paragraph drawn twice, no settled reply cut inside a Markdown span. Only the
    // newest turn's rows are read, so a long run pays per turn, not per row it holds.
    const ends = step.type === "event" && bySeq.get(step.seq)?.kind === "turn_result";
    if (ends || index === scenario.steps.length - 1) {
      let from = rows.length;
      while (from > 0 && !integrityTurnOpens(rows[from - 1]!)) from -= 1;
      const byRow = new Map<string, string>();
      for (const id of turnMessages) for (const row of client.rowsOfMessage(id)) byRow.set(row, id);
      const turnRows = rows.slice(Math.max(0, from - 1));
      for (const finding of checkIntegrity({
        rows: turnRows,
        turnEnded: ends || turnEnded,
        messageOf: (id) => byRow.get(id),
      }))
        if (!exempt.has(finding.rule)) flag(finding.rule, finding.rowId, finding.detail);
      if (ends) turnMessages.clear();
    }
    // (d) churn: layout shifts of drawn rows and rows drawn under a second (ShiftEvent, FlashEvent).
    {
      const phase: ShiftEvent["phase"] = /^(turn_end|turn_result|status ready)$/.test(step.label)
        ? "turn-end"
        : "mid-turn";
      const drawnAt = (lay: ConversationLayout | undefined, at: number) => (lay ? (lay.heights[at] ?? 0) > 0 : false);
      const was = new Map<string, { top: number; height: number; kind: string }>();
      for (let at = stable; at < prevRows.length; at += 1)
        if (drawnAt(prevLayout, at))
          was.set(prevRows[at]!.id, {
            top: prevLayout!.tops[at]!,
            height: prevLayout!.heights[at]!,
            kind: prevRows[at]!.kind,
          });
      let moved = 0;
      let px = 0;
      let cause = "";
      const seen = new Set<string>();
      // The reader's anchor: the lowest row drawn at both steps that is not a live line. A row above it
      // that moved relative to it is a shift; rows streaming or arriving below it are not.
      let anchorAt = -1;
      for (let at = rows.length - 1; at >= stable && anchorAt < 0; at -= 1) {
        const row = rows[at]!;
        if (
          drawnAt(layout, at) &&
          was.has(row.id) &&
          !isLive(row) &&
          !LIVE_KINDS.has(row.kind) &&
          !row.id.startsWith("nextStep-")
        )
          anchorAt = at;
      }
      const anchorShift = anchorAt >= 0 ? layout.tops[anchorAt]! - was.get(rows[anchorAt]!.id)!.top : 0;
      for (let at = stable; at < rows.length; at += 1) {
        const row = rows[at]!;
        if (!drawnAt(layout, at)) continue;
        seen.add(row.id);
        const before = was.get(row.id);
        if (!before) {
          if (!drawnSince.has(row.id)) drawnSince.set(row.id, step.at);
          if (!cause && at < anchorAt) cause = `+${row.kind} ${row.id}`;
          continue;
        }
        const height = layout.heights[at]!;
        if (!cause && Math.abs(height - before.height) > 0.5 && at < anchorAt) cause = `~${row.kind} ${row.id}`;
        if (at >= anchorAt || isLive(row) || LIVE_KINDS.has(row.kind)) continue;
        const delta = Math.abs(layout.tops[at]! - before.top - anchorShift);
        if (delta > 0.5) {
          moved += 1;
          px = Math.max(px, delta);
        }
      }
      for (const [id, before] of was) {
        if (seen.has(id)) continue;
        const since = drawnSince.get(id);
        drawnSince.delete(id);
        if (!cause) cause = `-${before.kind} ${id}`;
        if (since !== undefined && step.at - since < FLASH_MS)
          flashes.push({
            id,
            kind: before.kind,
            shownMs: step.at - since,
            step: index,
            at: step.at - first,
            label: step.label,
            phase,
          });
      }
      const back = prevLayout ? Math.max(0, prevLayout.totalHeight - layout.totalHeight) : 0;
      if (moved > 0)
        shifts.push({
          step: index,
          at: step.at - first,
          label: step.label,
          phase,
          moved,
          px: Math.round(px),
          back: Math.round(back),
          cause,
        });
      prevLayout = layout;
    }

    const probes =
      rows.length <= rowsUpTo
        ? probeAt
            .filter((probe): probe is RowProbe => !!probe)
            .map(({ above: _above, ...probe }: RowProbe & { above?: RowProbe }) => probe)
        : [];

    prevRows = rows;
    prevProbeAt = probeAt;
    violations.push(...stepViolations);
    allFolds.push(...folds);
    const trace: StepTrace = {
      step: index,
      t: step.at - first,
      label: step.label,
      ...(step.type === "event" ? { seq: step.seq } : {}),
      working,
      turn,
      turnEnded,
      rowCount: rows.length,
      shaped,
      folds,
      rerendered,
      violations: stepViolations,
      ...(rows.length <= rowsUpTo ? { rows: probes } : {}),
    };
    options.onStep?.(trace);
    traces.push(trace);
  };

  const result = (): SimResult => ({
    scenario: scenario.name,
    steps: scenario.steps.length,
    rows: last?.rows.length ?? 0,
    recordRows: snapshot?.rows.length ?? 0,
    virtualMs: (scenario.steps.at(-1)?.at ?? first) - first,
    wallMs: Math.round(performance.now() - started),
    violations,
    folds: allFolds,
    shifts,
    flashes,
    traces: options.onStep ? [] : traces,
  });
  /** Whether the agent is working at the step `advance` last made (the browser lane draws it). */
  const state = () => ({ working, turn, turnEnded });
  /** The reducer's client and its newest snapshot (the scenario checks read rows of a message, raw rows). */
  const reducer = () => ({ client, snapshot });
  return { advance, check, result, state, reducer };
}

/// Runs `scenario` and checks the three rules at every step (sim/README.md "Rules").
export function runSimulation(scenario: SimScenario, options: SimOptions = {}): SimResult {
  const sim = createSimulation(scenario, options);
  scenario.steps.forEach((step, index) => {
    const rows = sim.advance(index);
    if (rows) sim.check(index, options.measure?.(rows, step));
  });
  return sim.result();
}

/// `runSimulation` with an asynchronous measure (the browser lane: draw, wait for the frame, then read
/// the boxes).
export async function runSimulationAsync(
  scenario: SimScenario,
  measure: (
    rows: readonly AcpmuxRow[],
    step: SimStep,
    index: number,
    state: { working: boolean; turn: number },
  ) => Promise<readonly ({ top: number; bottom: number } | undefined)[]>,
  options: SimOptions = {},
): Promise<SimResult> {
  const sim = createSimulation(scenario, options);
  for (let index = 0; index < scenario.steps.length; index += 1) {
    const rows = sim.advance(index);
    if (rows) sim.check(index, await measure(rows, scenario.steps[index]!, index, sim.state()));
  }
  return sim.result();
}

/// acpmux's `turn_end` of a named turn: the pane draws the turn's end there, as its `turn_result` (logged a moment
/// later, with the turn's git stats) will (direct.ts `endTurnId`), so the turn has ended for the reader. Rule b
/// counts from it: a fold the end draws is the turn's end fold, not one before it.
function endsTurn(event: EventRecord): boolean {
  return event.kind === "turn_end" && typeof event.msg?.turnId === "string" && event.msg.turnId !== "";
}

/// A prompt that starts a turn: the person's, or another agent's message; not the inbox's notice of threads.
/// A steer (`steer: true`) or a harness prompt into the running turn (a Stop hook's feedback) goes into the turn
/// that runs and opens none.
function isTurnPrompt(event: EventRecord): boolean {
  const kind = event.msg?._meta?.provenance?.kind;
  if (kind === "inbox_notice" || kind === "agent_digest" || event.msg?.steer === true) return false;
  return event.msg?._meta?.origin?.actor !== "harness";
}

/// A short summary of a result's violations by rule, for a CLI or a test's message.
export function summarize(result: SimResult): string {
  const byRule = new Map<string, number>();
  for (const violation of result.violations) byRule.set(violation.rule, (byRule.get(violation.rule) ?? 0) + 1);
  const rules = [...byRule].map(([rule, count]) => `${rule}=${count}`).join(" ") || "none";
  // Mid-turn folds the rules allow (a later sibling closed a finished run), by kind: what a reader sees
  // fold before the turn ends, by design.
  const sibling = new Map<string, number>();
  for (const fold of result.folds)
    if (fold.verdict === "sibling") sibling.set(fold.kind, (sibling.get(fold.kind) ?? 0) + 1);
  const siblings = [...sibling].map(([kind, count]) => `${kind}=${count}`).join(" ") || "none";
  // l10n-allow: simulator report for a terminal, not shipped UI
  return `${result.scenario}: ${result.steps} steps, ${result.rows} rows drawn (${result.recordRows} before folding), ${Math.round(result.virtualMs / 1000)} s simulated in ${result.wallMs} ms; violations ${rules}; mid-turn sibling folds ${siblings}`;
}

/// Shifts and flashes per minute of churn (virtual time), split by phase: the numbers the PR quotes.
export function churnSummary(result: SimResult): string {
  const minutes = Math.max(result.virtualMs, 1) / 60_000;
  const rate = (count: number) => (count / minutes).toFixed(2);
  const mid = result.shifts.filter((shift) => shift.phase === "mid-turn").length;
  const end = result.shifts.length - mid;
  const flashMid = result.flashes.filter((flash) => flash.phase === "mid-turn").length;
  const kinds = new Map<string, number>();
  for (const flash of result.flashes) kinds.set(flash.kind, (kinds.get(flash.kind) ?? 0) + 1);
  const causes = new Map<string, number>();
  for (const shift of result.shifts) {
    const key = shift.cause.replace(/ .*/, "") || "(shorter)";
    causes.set(key, (causes.get(key) ?? 0) + 1);
  }
  const list = (map: Map<string, number>) => [...map].map(([key, count]) => `${key}=${count}`).join(" ") || "none";
  return `${result.scenario}: ${minutes.toFixed(2)} min; shifts ${result.shifts.length} (${rate(result.shifts.length)}/min; mid-turn ${mid}, turn-end ${end}; by cause ${list(causes)}); sub-second rows ${result.flashes.length} (${rate(result.flashes.length)}/min; mid-turn ${flashMid}; by kind ${list(kinds)})`;
}
