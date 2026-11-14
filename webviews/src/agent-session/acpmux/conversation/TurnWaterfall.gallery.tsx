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
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxActivity } from "../model";
import { TurnWaterfall, type WaterfallLook, type WaterfallSummary } from "./TurnWaterfall";
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

function Waterfall({ look, summary }: { look: WaterfallLook; summary?: WaterfallSummary }) {
  return (
    <TurnActionsContext.Provider value={{ showCall: () => true }}>
      <div className="acpmux-shell" style={{ padding: 16 }}>
        {/* The shell is a flex row, and the Timeline is a size container with no width of its own:
            a block around it gives it the pane's width, as the transcript's row does. */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <TurnWaterfall row={ROW} work={WORK} look={look} summary={summary} />
        </div>
      </div>
    </TurnActionsContext.Provider>
  );
}

export default componentEntry<{ look: WaterfallLook; summary?: WaterfallSummary }>({
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
      note: "Chosen: each call's label, its bar on the turn's axis and its time on one row; the slowest and failed calls tagged. At phone width the label goes over its bar. The header corner says \"10 calls · 1m 12s\": how much the turn did and how long it took, muted like the axis.",
      props: { look: "bars" },
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
