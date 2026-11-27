// l10n-allow-file: gallery fixture labels describe the sample timeline.
import { componentEntry } from "../../../gallery/format";
import type { TimeBreakdownLook } from "./TimeBreakdown";
import type { AcpmuxTimeBreakdown } from "../model";

export const breakdown: AcpmuxTimeBreakdown = {
  totalMs: 2_550_000,
  totalTokens: 18_400,
  tokensComplete: true,
  categories: [
    { id: "read", wallMs: 180_000 },
    { id: "edit", wallMs: 90_000 },
    { id: "run", wallMs: 1_320_000 },
    { id: "think", wallMs: 420_000 },
    { id: "person", wallMs: 390_000 },
    { id: "model", wallMs: 150_000 },
  ],
  spans: [
    {
      turnSeq: 1,
      turnId: "turn-1",
      category: "read",
      startAt: 0,
      endAt: 180_000,
      turnTokens: 17_600,
    },
    {
      turnSeq: 1,
      turnId: "turn-1",
      category: "think",
      startAt: 180_000,
      endAt: 600_000,
      turnTokens: 17_600,
    },
    {
      turnSeq: 1,
      turnId: "turn-1",
      category: "run",
      startAt: 600_000,
      endAt: 1_920_000,
      turnTokens: 17_600,
    },
    {
      turnSeq: 1,
      turnId: "turn-1",
      category: "model",
      startAt: 1_920_000,
      endAt: 2_070_000,
      turnTokens: 17_600,
    },
    {
      turnSeq: 1,
      turnId: "turn-1",
      category: "person",
      startAt: 2_070_000,
      endAt: 2_460_000,
      turnTokens: 17_600,
    },
    {
      turnSeq: 2,
      turnId: "turn-2",
      category: "edit",
      startAt: 2_460_000,
      endAt: 2_550_000,
      turnTokens: 800,
    },
  ],
};

export default componentEntry<{ look: TimeBreakdownLook }>({
  id: "agent-pane.session-info-time-breakdown",
  title: "Session Info Time Breakdown",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 480 },
  covers: [
    "agent-session/acpmux/session-info/TimeBreakdown.tsx",
    "agent-session/acpmux/session-info/TimeBreakdown.css",
    "agent-session/acpmux/session-info/UsageSection.tsx",
  ],
  load: async () => {
    const { TimeBreakdown } = await import("./TimeBreakdown");
    return ({ look }: { look: TimeBreakdownLook }) => (
      <div className="acpmux-shell" data-time-fixture="" style={{ padding: 16 }}>
        <TimeBreakdown
          breakdown={breakdown}
          look={look}
          onShowTurn={(turnId) => {
            document.querySelector<HTMLElement>("[data-time-fixture]")?.setAttribute("data-revealed-turn", turnId);
          }}
        />
      </div>
    );
  },
  variants: {
    stacked: {
      note: "Picked: one compact timeline; each segment is a turn target.",
      props: { look: "stacked" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-time-breakdown__span" });
        await ctx.waitFor(() => ctx.document.querySelector("[data-revealed-turn]"));
      },
    },
    lanes: {
      note: "Comparison: one lane per activity category makes activity changes easy to scan.",
      props: { look: "lanes" },
    },
    totals: {
      note: "Comparison: totals-first rows answer where the wall clock went at a glance.",
      props: { look: "totals" },
    },
  },
});
