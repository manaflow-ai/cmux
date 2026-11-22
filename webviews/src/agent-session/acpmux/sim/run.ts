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
import { turnViewFrom, type TurnView } from "../conversation/turns";
import { layoutConversation, type AcpmuxRow, type AcpmuxSnapshot, type ConversationLayout } from "../model";
import { ROW_GAP_LOOKS, TRANSCRIPT_BLOCK_GAP, TRANSCRIPT_TURN_GAP } from "../transcriptGrid";
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
  /** The row is the turn's header ("Working for" / "Worked for"), or, before it has one, its first row under the prompt. */
  head?: boolean;
  text?: string;
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
  /** ms of virtual time from the fold to its turn's end event (`turn_result`): > 0 means mid-turn. */
  beforeTurnEndMs?: number;
  /** `turn-end`: at or after its turn's end; `sibling`: a later row of the same running turn closed a finished run
   *  (the `runs` arm of live-turn-work, by design); `final-answer`: the turn's final answer (Codex's
   *  `final_answer` phase) began, which starts the turn's folded look before its `turn_result` (turns.ts,
   *  by design); `violation`: anything else mid-turn. */
  verdict: "turn-end" | "sibling" | "remapped" | "final-answer" | "violation";
};

export type Violation = {
  rule: "a-turn-gap" | "a-head-gap" | "b-mid-turn-fold" | "b-mid-turn-shrink" | "c-rerender";
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
  traces: StepTrace[];
};

const LIVE_KINDS = new Set(["typing", "working", "thinking", "activityLine"]);
const isLive = (row: AcpmuxRow) => row.below === true || row.kind === "typing" || row.id.endsWith("-live");
const foldOf = (row: AcpmuxRow): string => {
  if (row.foldOpen !== undefined) return row.foldOpen ? "open" : "closed";
  if (row.runOpen !== undefined) return row.runOpen ? "open" : "closed";
  if (row.folded !== undefined) return row.folded ? "closed" : "open";
  return "";
};
const opensTurn = (row: AcpmuxRow) => row.kind === "user" && row.incoming?.kind !== "hidden";
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
  // Each turn's end (`turn_result`) time, known ahead from the script, so a fold can say how long before it it came.
  const turnEnds = new Map<number, number>();
  {
    let turn = 0;
    let ended = true;
    for (const event of [...scenario.events].sort((a, b) => a.seq - b.seq)) {
      if (event.kind === "user_message" && isTurnPrompt(event) && ended) {
        turn += 1;
        ended = false;
      }
      if (event.kind === "turn_result") {
        if (!turnEnds.has(turn)) turnEnds.set(turn, event.at);
        ended = true;
      }
    }
  }
  const first = scenario.steps[0]?.at ?? 0;
  let turn = 0;
  let turnEnded = true;
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
  const cache = new Map();
  // The browser lane: each row's drawn height at the last measured step, to see a row collapse.
  const drawnHeights = new Map<string, number>();
  // The open folds, one object for the whole run as App.tsx keeps its `folds` state: a fresh set each
  // step reads as a fold change, and the turn view then shapes every turn again (no reuse).
  const folds = new Set<string>();

  let current: { rows: readonly AcpmuxRow[]; layout: ConversationLayout } | undefined;
  let shaped = 0;
  /** Folds step `index`'s record (or reader action) and shapes and places the rows: the rows to draw. */
  const advance = (index: number): readonly AcpmuxRow[] | undefined => {
    const step = scenario.steps[index]!;
    if (step.type === "event") {
      const event = bySeq.get(step.seq);
      // A message that comes in while the turn runs steers it (turns.ts draws it inside that turn's
      // work); only one after the turn ended opens a turn.
      if (event?.kind === "user_message" && isTurnPrompt(event) && turnEnded) {
        turn += 1;
        turnEnded = false;
      }
      if (event?.kind === "turn_result") turnEnded = true;
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
    }
    const snap = snapshot;
    if (!snap) {
      current = undefined;
      return undefined;
    }
    const view = turnViewFrom(
      snap.rows,
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
      // The turn's head: its header line, or the first row under its opening row.
      if (!headAt.has(own) && ((prevDrawn?.opens && prevDrawn.turn === own) || isHeader(row))) {
        probe.head = true;
        headAt.set(own, at);
      }
      const words = textOf(row);
      if (words) probe.text = words;
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
      // under the turn before (transcriptSpacing.ts footer-to-received, by design).
      const want = probe.received ? TRANSCRIPT_BLOCK_GAP : TRANSCRIPT_TURN_GAP;
      // The turn's "Working for" (or "Worked for") line drawn over the message that opened it (turns.ts
      // `shapeLiveTurn`): that line is the turn's top, so it stands the gap under the turn before.
      if (probe.opens && (above.id === `working-${probe.id}` || above.id === `worked-${probe.id}`)) {
        const before = (above as RowProbe & { above?: RowProbe }).above;
        const headGap = above.drawnGap ?? above.gap;
        if (before && headGap < want - 0.5)
          flag(
            "a-turn-gap",
            above.id,
            `${above.kind} over ${probe.kind} opens turn ${probe.turn} ${headGap}px under ${before.kind} ${before.id} (want >= ${want})`,
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
      const ended = own < turn || turnEnded;
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
        if (remapped) verdict = "remapped";
        else if (answering) verdict = "final-answer";
        else if (was.row.kind !== "assistant" && laterSibling) verdict = "sibling";
        else verdict = "violation";
      }
      const event: FoldEvent = {
        id,
        kind: was.row.kind,
        turn: own,
        how: hidden ? "hidden" : "closed",
        ...(end !== undefined ? { beforeTurnEndMs: end - step.at } : {}),
        verdict,
      };
      folds.push(event);
      if (verdict === "violation")
        flag(
          "b-mid-turn-fold",
          id,
          `${was.row.kind} of turn ${own} ${event.how} ${end !== undefined ? `${end - step.at} ms before its turn_result` : "in a turn that never ends"}${was.row.text ? `: "${was.row.text.slice(0, 50)}"` : ""}`,
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
        if (own < turn || turnEnded) continue;
        const before = prevRows.find((old) => old.id === row.id);
        if (before && foldOf(before) !== foldOf(row)) continue;
        flag(
          "b-mid-turn-shrink",
          row.id,
          `${row.kind} of turn ${own} drawn ${Math.round(was)}px -> ${Math.round(height)}px before its turn_result`,
        );
      }
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
    traces: options.onStep ? [] : traces,
  });
  /** Whether the agent is working at the step `advance` last made (the browser lane draws it). */
  const state = () => ({ working, turn, turnEnded });
  return { advance, check, result, state };
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

/// A prompt that starts a turn: the person's, or another agent's message; not the inbox's notice of threads.
function isTurnPrompt(event: EventRecord): boolean {
  const kind = event.msg?._meta?.provenance?.kind;
  return kind !== "inbox_notice" && kind !== "agent_digest";
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
  return `${result.scenario}: ${result.steps} steps, ${result.rows} rows drawn (${result.recordRows} before folding), ${Math.round(result.virtualMs / 1000)} s simulated in ${result.wallMs} ms; violations ${rules}; mid-turn sibling folds ${siblings}`;
}
