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
import type { AcpmuxRow } from "../model";
import { history, REPLY } from "./streamingTextFixture";

export type ScriptedTurn = "send" | "tools" | "steer";

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
};

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/// The rows a scripted turn starts from: a chat's history.
export const scriptedHistory = history;

/// Plays one scripted turn over `scriptedHistory()`; resolves once its summary row is drawn.
export async function playScriptedTurn(
  scenario: ScriptedTurn,
  { show, frame, step = () => {}, chars = 24, everyMs = 16 }: ScriptedTurnOptions,
): Promise<void> {
  const ANSWER_ID = SCRIPTED_ANSWER_ID;
  const base = history();
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
  if (scenario === "send") {
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
