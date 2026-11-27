// l10n-allow-file: gallery fixtures (sample commands and file names), not shipped UI.
// A finished turn's Timeline (TurnWaterfall.tsx) in three looks on one 1m 12s turn: bars beside
// their labels (chosen), labels over full-width bars, and one lane per kind of work. References:
// cmux-design-references codex/live/status-work-session-edit-cards (elapsed work per step) and
// aside/web/task-activity-timeline (steps in time order); no reference app draws a per-call
// waterfall, so its grammar is a trace viewer's, in the transcript's tones. The header row's corner,
// left of the axis, says the turn's total (Leo, 2026-11-07: "The top left, there's nothing"), in four
// wordings: the count and total (chosen), the total alone, "Turn" and the total, and the count with
// the total in full ink. References: chatgpt/web/transcript-work-worked-for-browser-screenshot and
// codex/live/transcript-worked-for-collapsed-summary (a turn's time as one short muted phrase).
// The turn's time outside every call and thought (Leo, 2026-11-05: "im not sure what the total thing
// is meant to represent. the total time of a turn?") in three arms: a striped last row with its sum
// (chosen), the gaps shaded in every track, and nothing (before). `one-call` is his screenshot: one
// 2.7s read in a 14.1s turn. `leo-turn` is his 2026-11-22 screenshot ("IF THIS IS THE CASE, THEN
// DON'T FUCKING DISPLAY THIS BULLSHIT LIKE THIS"): a 1m 40s turn of a 551ms thought, one 24.5s call
// and 1m 15s of model time, now plain lines; `leo-turn-chart` is how it drew before. `model-calls`
// is his 2026-11-27 turn ("was your thinkin really 3ms only? from anthropic and back?"): two calls
// of 2.2s and 2.5s whose thinking read 3ms, timed from its first thought chunk to its last; now each
// model call reads from its request to its last token, as acpmux timed it (claude_stdio/model_calls.rs).
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnWork } from "./waterfallSpans";
import {
  TurnWaterfall,
  type WaterfallForm,
  type WaterfallLook,
  type WaterfallModelTime,
  type WaterfallSummary,
} from "./TurnWaterfall";
import { TurnActionsContext } from "./turnActions";

const START = Date.UTC(2026, 10, 5, 13, 10, 0);

function call(
  id: string,
  kind: string,
  title: string,
  from: number,
  to: number,
  extra: Partial<NonNullable<AcpmuxActivity["tool"]>> = {},
): AcpmuxActivity {
  return {
    kind: "tool",
    text: title,
    tool: { id, title, kind, status: "completed", startedAt: START + from, endedAt: START + to, ...extra },
  };
}

const thought = (from: number, to: number): AcpmuxActivity => ({
  kind: "thought",
  text: "Looking at where the turn spends its time",
  startedAt: START + from,
  endedAt: START + to,
});

const WORK: AcpmuxActivity[] = [
  thought(0, 2_400),
  call("read-1", "read", "Read TurnRows.tsx", 2_500, 2_900, { locations: [{ path: "conversation/TurnRows.tsx" }] }),
  call("grep-1", "search", "grep -rn useRowDisclosure", 3_000, 3_600),
  call("read-2", "read", "Read transcriptDisclosure.tsx", 3_700, 4_000),
  thought(4_100, 7_800),
  call("edit-1", "edit", "Edit waterfallSpans.ts", 8_000, 9_100),
  call("test-1", "execute", "bun test turnWaterfall", 9_300, 21_000, { command: "bun test turnWaterfall" }),
  call("lint-1", "execute", "scripts/web-lint.sh", 21_200, 49_000, { command: "scripts/web-lint.sh" }),
  call("fetch-1", "fetch", "Fetch github.com/manaflow-ai/cmux/pull/36491", 49_300, 51_800),
  call("mcp-1", "other", "mcp__github__ci_status", 52_000, 53_200, { status: "failed", output: "rate limited" }),
  call("edit-2", "edit", "Edit TurnWaterfall.css", 53_500, 54_600),
  call("test-2", "execute", "bun test TurnRows", 55_000, 70_500, { command: "bun test TurnRows" }),
];
const ROW = { at: START + 72_000, durationMs: 72_000 };

// Leo's screenshot: a 14.1s turn whose one timed call was a 2.7s read near its start.
const ONE_CALL: AcpmuxActivity[] = [call("read-3", "read", "Read threads and probe output", 0, 2_700)];
const ONE_CALL_ROW = { at: START + 14_100, durationMs: 14_100 };

// Leo's 2026-11-22 screenshot: "1 call · 1m 40s", a 551ms thought, one 24.5s call, the rest the model.
const LEO_TURN: AcpmuxActivity[] = [thought(25_000, 25_551), call("send-1", "other", "Sent a message", 52_000, 76_500)];
const LEO_TURN_ROW = { at: START + 100_400, durationMs: 100_400 };

// Leo's 2026-11-27 turn: the prompt goes out, the model's first byte comes 2.1s later, its thinking
// arrives in one 3ms burst at 6s and it calls two tools; their results go out at 8.2s and the second
// call ends at 10.4s. `timed` rows carry the two calls as acpmux timed them.
const queueLands = call("queue-1", "other", "Queue lands for #60053 and #60188", 6_000, 8_200);
const sentTo = call("send-2", "other", "Sent to Distribute work off the build host", 5_700, 8_200);
const modelRows = (timed: boolean): AcpmuxRow[] => [
  {
    id: "a",
    version: 1,
    at: START,
    kind: "activity",
    items: [{ ...thought(5_997, 6_000), text: "Queue both lands" }, queueLands, sentTo],
    ...(timed && {
      modelCalls: [
        { requestAt: START, firstTokenAt: START + 2_100, lastTokenAt: START + 6_100, thought: true as const },
        { requestAt: START + 8_210, firstTokenAt: START + 9_900, lastTokenAt: START + 10_400 },
      ],
    }),
  },
];
const MODEL_BEFORE = turnWork(modelRows(false))!;
const MODEL_AFTER = turnWork(modelRows(true))!;
const MODEL_BEFORE_ROW = { at: START + 8_200 };
const MODEL_ROW = { at: START + 10_400, durationMs: 10_400 };

type Props = {
  look: WaterfallLook;
  summary?: WaterfallSummary;
  modelTime?: WaterfallModelTime;
  form?: WaterfallForm;
  one?: boolean;
  leo?: boolean;
  /// Leo's 2026-11-27 turn, its thinking timed by its chunks (`before`) or its model calls (`after`).
  model?: "before" | "after";
};

function Waterfall({ look, summary, modelTime, form, one, leo, model }: Props) {
  return (
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <div className="acpmux-shell" style={{ padding: 16 }}>
        {/* The shell is a flex row, and the Timeline is a size container with no width of its own:
            a block around it gives it the pane's width, as the transcript's row does. */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <TurnWaterfall
            row={
              model === "after"
                ? MODEL_ROW
                : model === "before"
                  ? MODEL_BEFORE_ROW
                  : leo
                    ? LEO_TURN_ROW
                    : one
                      ? ONE_CALL_ROW
                      : ROW
            }
            work={
              model === "after"
                ? MODEL_AFTER
                : model === "before"
                  ? MODEL_BEFORE
                  : leo
                    ? LEO_TURN
                    : one
                      ? ONE_CALL
                      : WORK
            }
            look={look}
            summary={summary}
            modelTime={modelTime}
            form={form}
          />
        </div>
      </div>
    </TurnActionsContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.turn-waterfall",
  title: "Turn timeline (waterfall)",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 390, normal: 640, wide: 820 },
  covers: [
    "agent-session/acpmux/conversation/TurnWaterfall.tsx",
    "agent-session/acpmux/conversation/TurnWaterfall.css",
    "agent-session/acpmux/conversation/waterfallSpans.ts",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => Waterfall,
  variants: {
    bars: {
      note: "Chosen: each call's label, its bar on the turn's axis and its time on one row; the slowest and failed calls tagged. At phone width the label goes over its bar. The header corner says \"10 calls · 1m 12s\": how much the turn did and how long it took, muted like the axis. A last striped row holds the model's time outside every call and thought, so the rows add up to the total.",
      props: { look: "bars" },
    },
    "leo-turn": {
      note: 'Leo\'s 2026-11-22 turn, chosen: "1 call · 1m 40s" as plain lines, "Thinking 1m 16s" (the 551ms thought and the model\'s time together) and "Sent a message 24.5s". A turn charts only with two or more visible call bars (each at least 2% of the axis) and the model\'s time under half the turn.',
      props: { look: "bars", leo: true },
    },
    "leo-turn-chart": {
      note: "Before: the same turn as a chart, a 551ms tick, one 24.5s bar and 1m 15s of stripes. Nothing to compare.",
      props: { look: "bars", leo: true, form: "chart" },
    },
    "model-calls": {
      note: 'Leo\'s 2026-11-27 turn, chosen: each model call from its request to its last token, as acpmux timed it where it read the stream. "Thinking 6s" (the call that thought; its hover says its first token came after 2s) and "Model call 2s" beside the two calls, on an axis that opens at the prompt.',
      props: { look: "bars", model: "after" },
    },
    "model-calls-plain": {
      note: 'The same turn as plain lines: "Thinking 8s", the model\'s own time over both calls, then the two calls.',
      props: { look: "bars", model: "after", form: "plain" },
    },
    "model-calls-before": {
      note: 'Before: thinking timed from its first thought chunk to its last, "Thinking 3ms". Claude Code\'s thinking comes in one burst at its call\'s end, and the axis opened at the first call.',
      props: { look: "bars", model: "before", form: "chart" },
    },
    "one-call": {
      note: 'One 2.7s read in a 14.1s turn: one call and mostly the model, so plain lines, "Thinking 11.4s" and the read.',
      props: { look: "bars", one: true },
    },
    "one-call-chart": {
      note: 'Before: the same turn charted, the striped "Model, no tool running" row holding the other 11.4s.',
      props: { look: "bars", one: true, form: "chart" },
    },
    "model-tint": {
      note: "The model's time as a shade behind every call's bar, no row of its own: shorter, but it never says what the shade is or how long.",
      props: { look: "bars", modelTime: "tint" },
    },
    "model-none": {
      note: "Before: no model time. One 2.7s bar on a 14.1s axis leaves the rest of the turn blank and the total unexplained.",
      props: { look: "bars", modelTime: "none", one: true, form: "chart" },
    },
    "summary-total": {
      note: 'Header corner: the total alone, "1m 12s total". Shortest, but it only repeats the axis\'s end.',
      props: { look: "bars", summary: "total" },
    },
    "summary-turn": {
      note: 'Header corner: "Turn · 1m 12s". Names what the total is, says nothing the axis doesn\'t.',
      props: { look: "bars", summary: "turn" },
    },
    "summary-strong": {
      note: "Header corner: the count, then the total in full ink. Reads first, but competes with the slowest row's bold time.",
      props: { look: "bars", summary: "strong" },
    },
    stacked: {
      note: "Each label over a full-width bar: the axis has the whole width, but the list is twice as tall.",
      props: { look: "stacked" },
    },
    lanes: {
      note: "One lane per kind of work: compact and shows overlap, but a bar no longer names its call.",
      props: { look: "lanes" },
    },
  },
});
