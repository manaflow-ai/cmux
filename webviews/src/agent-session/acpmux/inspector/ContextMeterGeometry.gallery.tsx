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

function ContextMeterGeometry({ width = 260 }: { width?: number }) {
  const stage: CSSProperties = {
    width,
    minHeight: 120,
    padding: 8,
    borderRadius: 8,
    background: "var(--surface-glass, color-mix(in srgb, var(--agent-text) 5%, transparent))",
  };
  return (
    <div style={stage} data-context-meter-fixture="five-equal-categories">
      <ContextSection usage={{ used: 95, size: 100 }} percent={95} breakdown={BREAKDOWN} />
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
  covers: ["agent-session/acpmux/inspector/ContextSection.tsx"],
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
  },
});
