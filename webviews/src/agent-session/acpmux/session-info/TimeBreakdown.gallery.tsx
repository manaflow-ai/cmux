// l10n-allow-file: gallery fixture labels describe the sample timeline.
import { componentEntry } from "../../../gallery/format";
import { TimeBreakdown, type TimeBreakdownLook } from "./TimeBreakdown";
import type { AcpmuxTimeBreakdown } from "../model";

const breakdown: AcpmuxTimeBreakdown = {
  totalMs: 2_400_000,
  totalTokens: 18_400,
  tokensComplete: false,
  categories: [
    { id: "read", wallMs: 180_000, tokens: 1_200 },
    { id: "edit", wallMs: 90_000, tokens: 800 },
    { id: "run", wallMs: 1_320_000, tokens: 7_000 },
    { id: "think", wallMs: 420_000, tokens: 8_900 },
    { id: "person", wallMs: 540_000 },
    { id: "model", wallMs: 150_000, tokens: 500 },
  ],
  spans: [
    {
      turnSeq: 1,
      turnId: "turn-read",
      category: "read",
      startAt: 0,
      endAt: 180_000,
      tokens: 1_200,
    },
    {
      turnSeq: 1,
      turnId: "turn-think",
      category: "think",
      startAt: 180_000,
      endAt: 600_000,
      tokens: 8_900,
    },
    {
      turnSeq: 1,
      turnId: "turn-run",
      category: "run",
      startAt: 600_000,
      endAt: 1_920_000,
      tokens: 7_000,
    },
    {
      turnSeq: 1,
      turnId: "turn-you",
      category: "person",
      startAt: 1_920_000,
      endAt: 2_460_000,
    },
    {
      turnSeq: 2,
      turnId: "turn-edit",
      category: "edit",
      startAt: 2_460_000,
      endAt: 2_550_000,
      tokens: 800,
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
  load:
    async () =>
    ({ look }: { look: TimeBreakdownLook }) => (
      <div className="acpmux-shell" style={{ padding: 16 }}>
        <TimeBreakdown
          breakdown={breakdown}
          look={look}
          onShowTurn={(turnId) => console.info("reveal", turnId)}
        />
      </div>
    ),
  variants: {
    stacked: {
      note: "Picked: one compact timeline; each segment is a turn target.",
      props: { look: "stacked" },
    },
    lanes: {
      note: "Comparison: one lane per activity category makes parallel work easy to scan.",
      props: { look: "lanes" },
    },
    totals: {
      note: "Comparison: totals-first rows answer where the wall clock went at a glance.",
      props: { look: "totals" },
    },
  },
});
