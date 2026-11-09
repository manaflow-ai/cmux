// l10n-allow-file: fixture prompts and replies, not shipped UI.
// Scripted turns for the follow motion's checks (test/browser/send-stream-motion.harness.tsx) and
// gallery (sendStreamMotion.gallery.tsx): a few steps of a real turn's events on a socket's clock,
// each drawn in the next display frame as direct.ts draws one snapshot per frame.
// - `send`: the reader sends from the latest row (the composer's card shrinks to one line in the
//   same commit, `sends` counts one), acpmux's echo brings the prompt's row and the running turn's
//   live line, then the reply streams fast and the turn ends.
// - `tools`: a reply streams, a thought comes and goes, two tool calls run and finish, and the
//   reply streams on in a new segment.
// - `steer`: while the reply streams the reader sends again: the composer clears, the prompt lands
//   under the reply's text so far, and the reply streams on under it.
// The turn-transition turns (test/turn-transition-jumps.test.ts; Leo, 2026-11-07: "the jumps are
// jarring. We want to minimize the jumps") build their rows as direct.ts does: a segment's thought
// and tool calls are items of one activity row, and a call ends the text segment before it.
// - `text-tool`: the reply streams, then a tool call arrives, runs and finishes, and the reply goes on.
// - `burst-thought`: the reply streams, a burst lands most of a page at once, then a thought starts.
// - `tool-group`: four calls arrive one after another into one activity row (a run that groups).
// - `steer-tools`: the reader sends while a call runs: the steer waits, lands, and the reply goes on.
// - `thought-text`: a thought streams, ends, and the reply's text starts under it.
// The row-arrival turns (test/row-arrival-settle.test.ts; Leo, 2026-11-09: "the tool call shifting
// the chat animation and stuff is just too slow ... thinking, tool calls, etc... cannot lag nor can
// they take long") stream a paragraph, wait ARRIVAL_QUIET_MS with nothing new so everything rests,
// then one row arrives in two events, each after ARRIVAL_QUIET_MS of rest (steps `begin`: the row
// starts, and `land`: it takes its place above the live line), so each event's whole motion, from
// the event to everything at rest, is measured on its own:
// - `arrive-thinking`: a thought starts, then ends as a tool call starts;
// - `arrive-tool`: a tool call starts, then finishes;
// - `arrive-group`: a second call joins a finished call's row, which becomes a group, then finishes;
// - `arrive-subagent`: a subagent call (Claude Code's Agent tool) starts, then reports.
import type { AcpmuxRow } from "../model";
import { history, REPLY } from "./streamingTextFixture";

export type ScriptedTurn =
  | "send"
  | "tools"
  | "steer"
  | "text-tool"
  | "burst-thought"
  | "tool-group"
  | "steer-tools"
  | "thought-text"
  | ArrivalTurn;

/// The turn-transition turns, in the order of Leo's words.
export const TRANSITION_TURNS = ["text-tool", "burst-thought", "tool-group", "steer-tools", "thought-text"] as const;
export type TransitionTurn = (typeof TRANSITION_TURNS)[number];
const isTransition = (turn: ScriptedTurn): turn is TransitionTurn =>
  (TRANSITION_TURNS as readonly string[]).includes(turn);

/// The row-arrival turns: one row of each kind arrives in a resting followed view.
export const ARRIVAL_TURNS = ["arrive-thinking", "arrive-tool", "arrive-group", "arrive-subagent"] as const;
export type ArrivalTurn = (typeof ARRIVAL_TURNS)[number];
const isArrival = (turn: ScriptedTurn): turn is ArrivalTurn => (ARRIVAL_TURNS as readonly string[]).includes(turn);
/// How long an arrival turn holds still before its row arrives and after it (ms): longer than any
/// motion the stream or the arrival starts, so the window holds the arrival's motion and nothing else.
export const ARRIVAL_QUIET_MS = 600;

export const SCRIPTED_PROMPT_ID = "live-user";
/// The reply's rows' ids start with this (`live-answer`, `live-answer-2`).
export const SCRIPTED_ANSWER_ID = "live-answer";
/// The composer card's height with a three-line draft, and with one line once it is sent.
export const CARD_DRAFT = 88 + 2 * 22.75;
export const CARD_EMPTY = 88;

export type ScriptedView = { rows?: AcpmuxRow[]; working?: boolean; sends?: number; card?: number };

export type ScriptedTurnOptions = {
  /// Draws the pane's next state (rows, the running turn, the send count, the composer card's height).
  show: (next: ScriptedView) => void;
  /// Runs `draw` in the next display frame (direct.ts `nextFrame`).
  frame: (draw: () => void) => void;
  /// Names the step the turn is in (the frame samples' phase).
  step?: (name: string) => void;
  /// Characters per delta and the time between deltas: 24 every 16 ms, 1,500 a second.
  chars?: number;
  everyMs?: number;
  /// The history's finished turns (streamingTextFixture `history`), 7 by default.
  historyTurns?: number;
};

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/// The rows a scripted turn starts from: a chat's history.
export const scriptedHistory = (turns?: number) => history(turns);

/// Plays one scripted turn over `scriptedHistory()`; resolves once its summary row is drawn.
export async function playScriptedTurn(
  scenario: ScriptedTurn,
  { show, frame, step = () => {}, chars = 24, everyMs = 16, historyTurns }: ScriptedTurnOptions,
): Promise<void> {
  const ANSWER_ID = SCRIPTED_ANSWER_ID;
  const base = history(historyTurns);
  const prompt: AcpmuxRow = {
    id: SCRIPTED_PROMPT_ID,
    version: 1,
    at: 100_000,
    kind: "user",
    text: "Why does the relay fall over?",
  };
  /// The turn's rows after the prompt, by id in order; `emit` draws them in the next frame.
  const turn = new Map<string, AcpmuxRow>();
  let version = 0;
  let scheduled = false;
  let ended = false;
  const put = (row: Omit<AcpmuxRow, "version">) => {
    version += 1;
    turn.set(row.id, { ...row, version } as AcpmuxRow);
  };
  const emit = () => {
    if (scheduled) return;
    scheduled = true;
    frame(() => {
      scheduled = false;
      show({ rows: [...base, prompt, ...turn.values()], working: !ended });
    });
  };
  /// Streams `source` into the assistant row `id`, `chars` every `everyMs`, then stops it streaming.
  const stream = async (id: string, at: number, source: string, done = true) => {
    for (let index = 0; index < source.length; index += chars) {
      put({ id, at, kind: "assistant", text: source.slice(0, index + chars), streaming: true });
      emit();
      await wait(everyMs);
    }
    if (done) put({ id, at, kind: "assistant", text: source, streaming: false });
    emit();
  };
  if (isTransition(scenario)) {
    step("prompt");
    show({ rows: [...base, prompt], working: true, card: CARD_EMPTY });
    await wait(300);
    await playTransition(scenario, { put, emit, stream, step, show, wait });
  } else if (isArrival(scenario)) {
    step("prompt");
    show({ rows: [...base, prompt], working: true, card: CARD_EMPTY });
    await wait(300);
    step("stream");
    await stream(ANSWER_ID, 100_001, REPLY.split("\n\n")[0]!);
    await playArrival(scenario, { put, emit, step, wait });
  } else if (scenario === "send") {
    // Enter: the composer clears to one line and the view goes to the latest message (App.tsx `send`).
    step("send");
    show({ sends: 1, card: CARD_EMPTY });
    // acpmux's echo: the prompt's row and the running turn's live line.
    await wait(30);
    show({ rows: [...base, prompt], working: true });
    await wait(400);
    step("stream");
    await stream(ANSWER_ID, 100_001, REPLY, false);
  } else {
    // The turn is running: the prompt is in (from another of the reader's devices), its live line
    // under it.
    step("prompt");
    show({ rows: [...base, prompt], working: true, card: CARD_EMPTY });
    await wait(300);
    step("stream");
    const paragraphs = REPLY.split("\n\n");
    const first = paragraphs.slice(0, 2).join("\n\n");
    if (scenario === "tools") {
      await stream(ANSWER_ID, 100_001, first);
      // A burst of text, then the agent thinks: the thought streams on the live line.
      step("thought");
      for (let step = 1; step <= 6; step += 1) {
        put({
          id: "live-thought",
          at: 100_002,
          kind: "activity",
          items: [
            { kind: "thought", text: "Checking the retry path. ".repeat(step), startedAt: 0, endedAt: step * 50 },
          ],
        } as Omit<AcpmuxRow, "version">);
        emit();
        await wait(50);
      }
      // Two tool calls run one after the other and finish.
      for (const [index, title] of ["Read relay.ts", "Grep reconnect"].entries()) {
        step(`tool-${index + 1}`);
        const call = (status: string) =>
          ({
            id: `live-call-${index}`,
            at: 100_003 + index,
            kind: "activity",
            toolCount: 1,
            items: [{ kind: "tool", text: title, tool: { id: `call-${index}`, title, kind: "read", status } }],
          }) as Omit<AcpmuxRow, "version">;
        put(call("in_progress"));
        emit();
        await wait(250);
        step(`tool-${index + 1}-done`);
        put(call("completed"));
        emit();
        await wait(120);
      }
      step("segment");
      await stream("live-answer-2", 100_010, paragraphs.slice(2, 6).join("\n\n"), false);
    } else {
      await stream(ANSWER_ID, 100_001, first, false);
      // The reader sends while the reply streams: Enter clears the composer, acpmux's echo lands
      // the prompt under the reply's text so far, and the reply goes on under it.
      step("steer");
      put({ id: ANSWER_ID, at: 100_001, kind: "assistant", text: first, streaming: false });
      show({ sends: 1, card: CARD_EMPTY + 2 * 22.75 });
      show({ sends: 2, card: CARD_EMPTY });
      await wait(30);
      put({ id: "live-steer", at: 100_005, kind: "user", text: "Also check the queue that replays requests." });
      emit();
      await wait(300);
      step("segment");
      await stream("live-answer-2", 100_006, paragraphs.slice(2, 6).join("\n\n"), false);
    }
  }
  // turn_result: the reply stops streaming and the turn's summary comes in.
  await wait(everyMs);
  step("end");
  for (const [id, row] of turn) if (row.kind === "assistant") put({ ...row, id, streaming: false });
  ended = true;
  put({ id: "live-end", at: 120_000, kind: "turnSummary", status: "completed" } as Omit<AcpmuxRow, "version">);
  emit();
}

type TransitionParts = {
  put: (row: Omit<AcpmuxRow, "version">) => void;
  emit: () => void;
  stream: (id: string, at: number, source: string, done?: boolean) => Promise<void>;
  step: (name: string) => void;
  show: (next: ScriptedView) => void;
  wait: (ms: number) => Promise<unknown>;
};

/// A tool call item as direct.ts `mergeToolItem` keeps it.
const toolItem = (index: number, title: string, kind: string, status: string) => ({
  kind: "tool" as const,
  text: title,
  tool: { id: `call-${index}`, title, kind, status },
});

/// One activity row of a segment (direct.ts `streamingActivity`): its thought and calls in order.
const activityRow = (id: string, at: number, items: AcpmuxRow["items"]): Omit<AcpmuxRow, "version"> =>
  ({
    id,
    at,
    kind: "activity",
    toolCount: (items ?? []).filter((item) => item.kind === "tool").length,
    items,
    streaming: (items ?? []).some(
      (item) => item.kind === "thought" || (item.tool?.status !== "completed" && item.tool?.status !== "failed"),
    ),
  }) as Omit<AcpmuxRow, "version">;

async function playTransition(
  turn: TransitionTurn,
  { put, emit, stream, step, show, wait }: TransitionParts,
): Promise<void> {
  const paragraphs = REPLY.split("\n\n");
  const ANSWER = SCRIPTED_ANSWER_ID;
  const thought = (steps: number) => ({
    kind: "thought" as const,
    text: "Checking the retry path and where the socket wrapper resets its attempt count. ".repeat(steps),
    startedAt: 0,
    endedAt: steps * 60,
  });
  if (turn === "text-tool") {
    step("stream");
    await stream(ANSWER, 100_001, paragraphs.slice(0, 2).join("\n\n"), false);
    // A call ends the text segment (direct.ts endAssistantSegment) and opens the segment's activity row.
    step("tool");
    put({ id: ANSWER, at: 100_001, kind: "assistant", text: paragraphs.slice(0, 2).join("\n\n"), streaming: false });
    put(activityRow("live-activity-1", 100_002, [toolItem(0, "Read relay.ts", "read", "in_progress")]));
    emit();
    await wait(300);
    step("tool-done");
    put(activityRow("live-activity-1", 100_002, [toolItem(0, "Read relay.ts", "read", "completed")]));
    emit();
    await wait(150);
    step("segment");
    await stream("live-answer-2", 100_010, paragraphs.slice(2, 4).join("\n\n"), false);
  } else if (turn === "burst-thought") {
    step("stream");
    const first = paragraphs[0]!;
    await stream(ANSWER, 100_001, first, false);
    // A burst: the rest of the page's first blocks land in one delta.
    step("burst");
    const burst = paragraphs.slice(0, 4).join("\n\n");
    put({ id: ANSWER, at: 100_001, kind: "assistant", text: burst, streaming: true });
    emit();
    await wait(20);
    // Then the agent thinks: the thought ends the text segment and streams on its activity row.
    step("thought");
    put({ id: ANSWER, at: 100_001, kind: "assistant", text: burst, streaming: false });
    for (let steps = 1; steps <= 8; steps += 1) {
      put(activityRow("live-activity-1", 100_002, [thought(steps)]));
      emit();
      await wait(60);
    }
  } else if (turn === "tool-group") {
    step("stream");
    const first = paragraphs[0]!;
    await stream(ANSWER, 100_001, first, false);
    put({ id: ANSWER, at: 100_001, kind: "assistant", text: first, streaming: false });
    const calls: [string, string][] = [
      ["Read relay.ts", "read"],
      ["Read retry.ts", "read"],
      ["Grep reconnect", "search"],
      ["Read queue.ts", "read"],
    ];
    const items: NonNullable<AcpmuxRow["items"]> = [];
    for (const [index, [title, kind]] of calls.entries()) {
      step(`call-${index + 1}`);
      items.push(toolItem(index, title, kind, "in_progress"));
      put(activityRow("live-activity-1", 100_002, [...items]));
      emit();
      await wait(200);
      items[index] = toolItem(index, title, kind, "completed");
      put(activityRow("live-activity-1", 100_002, [...items]));
      emit();
      await wait(100);
    }
    step("segment");
    await stream("live-answer-2", 100_010, paragraphs.slice(1, 3).join("\n\n"), false);
  } else if (turn === "steer-tools") {
    step("stream");
    const first = paragraphs.slice(0, 2).join("\n\n");
    await stream(ANSWER, 100_001, first, false);
    put({ id: ANSWER, at: 100_001, kind: "assistant", text: first, streaming: false });
    put(activityRow("live-activity-1", 100_002, [toolItem(0, "Read relay.ts", "read", "in_progress")]));
    emit();
    await wait(200);
    // The reader sends while the call runs: the composer clears and the steer waits for the step.
    step("steer");
    show({ sends: 1, card: CARD_EMPTY + 2 * 22.75 });
    show({ sends: 2, card: CARD_EMPTY });
    await wait(30);
    put({
      id: "live-steer",
      at: 100_005,
      kind: "user",
      text: "Also check the queue that replays requests.",
      steer: "waiting",
      steerPromptId: "steer-1",
    } as Omit<AcpmuxRow, "version">);
    emit();
    await wait(250);
    step("tool-done");
    put(activityRow("live-activity-1", 100_002, [toolItem(0, "Read relay.ts", "read", "completed")]));
    emit();
    await wait(150);
    // The agent reads the steer as its next text starts (direct.ts landSteer).
    step("segment");
    put({
      id: "live-steer",
      at: 100_005,
      kind: "user",
      text: "Also check the queue that replays requests.",
      steer: "landed",
      steerPromptId: "steer-1",
    } as Omit<AcpmuxRow, "version">);
    await stream("live-answer-2", 100_006, paragraphs.slice(2, 4).join("\n\n"), false);
  } else {
    step("thought");
    for (let steps = 1; steps <= 8; steps += 1) {
      put(activityRow("live-activity-1", 100_001, [thought(steps)]));
      emit();
      await wait(60);
    }
    // The reply's first words end the thought (its row stops streaming) and start their own row.
    step("text");
    put({ ...activityRow("live-activity-1", 100_001, [thought(8)]), streaming: false } as Omit<AcpmuxRow, "version">);
    await stream(ANSWER, 100_002, paragraphs.slice(0, 2).join("\n\n"), false);
  }
}

/// A subagent call as Claude Code sends it: the Agent tool with its description, prompt and type.
const subagentItem = (index: number, status: string) => ({
  kind: "tool" as const,
  text: "Agent: Find the retry path",
  tool: {
    id: `call-${index}`,
    title: "Agent: Find the retry path",
    kind: "think",
    status,
    inputSummary: JSON.stringify({
      description: "Find the retry path",
      prompt: "Find where the relay retries a dropped socket and how it counts attempts.",
      subagent_type: "Explore",
    }),
    ...(status === "completed" && {
      output:
        "The relay retries in `retry.ts` and resets its count on every reconnect.\n<usage>tool_uses: 6\nduration_ms: 9000</usage>",
    }),
  },
});

/// One row-arrival turn after its first paragraph. Each event comes after ARRIVAL_QUIET_MS with
/// nothing new, so the view rests before it: `begin`, the row starts (a running call or thought shows
/// on the live line), then `land`, it takes its place in the thread above the live line and moves
/// what is under it (the call finishes, the thought ends as a call starts, the second call joins the
/// first one's row, the subagent reports).
async function playArrival(
  turn: ArrivalTurn,
  { put, emit, step, wait }: Pick<TransitionParts, "put" | "emit" | "step" | "wait">,
): Promise<void> {
  const ACTIVITY = "live-activity-1";
  const thought = (ended: boolean) => ({
    kind: "thought" as const,
    text: "Checking the retry path and where the socket wrapper resets its attempt count.",
    startedAt: 0,
    ...(ended ? { endedAt: 1_200 } : {}),
  });
  const before: AcpmuxRow["items"] = turn === "arrive-group" ? [toolItem(0, "Read relay.ts", "read", "completed")] : [];
  if (before.length) {
    // The first call ran and finished before the window: the second one joins its row.
    put(activityRow(ACTIVITY, 100_002, before));
    emit();
  }
  const events: Record<ArrivalTurn, [NonNullable<AcpmuxRow["items"]>, NonNullable<AcpmuxRow["items"]>]> = {
    "arrive-thinking": [[thought(false)], [thought(true), toolItem(0, "Read relay.ts", "read", "in_progress")]],
    "arrive-tool": [
      [toolItem(0, "Read relay.ts", "read", "in_progress")],
      [toolItem(0, "Read relay.ts", "read", "completed")],
    ],
    "arrive-group": [
      [...before, toolItem(1, "Grep reconnect", "search", "in_progress")],
      [...before, toolItem(1, "Grep reconnect", "search", "completed")],
    ],
    "arrive-subagent": [[subagentItem(0, "in_progress")], [subagentItem(0, "completed")]],
  };
  for (const [index, name] of ["begin", "land"].entries()) {
    await wait(ARRIVAL_QUIET_MS);
    step(name);
    put(activityRow(ACTIVITY, 100_002, events[turn][index]!));
    emit();
  }
  await wait(ARRIVAL_QUIET_MS);
}
