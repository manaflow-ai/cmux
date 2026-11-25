// l10n-allow-file: gallery fixtures, not shipped UI.
// A deliberately even /context breakdown used by the geometry audit. Five 19% categories and
// the five percent free track make any separator width visible without synthetic markup.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { ContextSection } from "./ContextSection";

const BREAKDOWN = {
  categories: [
    { name: "Messages", tokens: 19, kind: "used" },
    { name: "System prompt", tokens: 19, kind: "used" },
    { name: "Tools", tokens: 19, kind: "used" },
    { name: "Memory files", tokens: 19, kind: "used" },
    { name: "Attachments", tokens: 19, kind: "used" },
    { name: "Free space", tokens: 5, kind: "free" },
  ],
  totalTokens: 95,
  maxTokens: 100,
};
const TINY_BREAKDOWN = {
  categories: [
    { name: "Normal category", tokens: 49.5, kind: "used" },
    { name: "Tiny positive category", tokens: 0.5, kind: "used" },
    { name: "Trailing positive category", tokens: 0.1, kind: "used" },
    { name: "Free space", tokens: 49.9, kind: "free" },
  ],
  totalTokens: 50.1,
  maxTokens: 100,
};

type ContextMeterGeometryProps = {
  width?: number;
  breakdown?: typeof BREAKDOWN | typeof TINY_BREAKDOWN;
  fixture?: string;
  usage?: { used: number; size: number };
  percent?: number;
};

function ContextMeterGeometry({
  width = 260,
  breakdown = BREAKDOWN,
  fixture = "five-equal-categories",
  usage = { used: 95, size: 100 },
  percent = 95,
}: ContextMeterGeometryProps) {
  const stage: CSSProperties = {
    width,
    minHeight: 120,
    padding: 8,
    borderRadius: 8,
    background: "var(--surface-glass, color-mix(in srgb, var(--agent-text) 5%, transparent))",
  };
  return (
    <div style={stage} data-context-meter-fixture={fixture}>
      <ContextSection usage={usage} percent={percent} breakdown={breakdown} />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.context-meter-geometry",
  title: "Context meter geometry",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 280, normal: 280 },
  covers: ["agent-session/acpmux/session-info/ContextSection.tsx"],
  load: async () => ContextMeterGeometry,
  variants: {
    "five-equal-categories": {
      note: "Worst-case geometry: five equal 19% used categories and a 5% free track in a 260px panel.",
      props: { width: 260 },
    },
    "five-equal-categories-wide": {
      note: "Worst-case geometry at a wider 400px panel: five equal 19% used categories and a 5% free track.",
      props: { width: 400 },
    },
    "tiny-positive-category": {
      note: "Tiny positive category below the 2px minimum next to a normal category; its colored fill must survive the separator.",
      props: {
        width: 260,
        breakdown: TINY_BREAKDOWN,
        fixture: "tiny-positive-category",
        usage: { used: 50.1, size: 100 },
        percent: 50.1,
      },
    },
  },
});
