// l10n-allow-file: gallery fixtures (sample summary rows), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { createElement } from "react";
import type { SessionSummary } from "./sessionSummary";
import { PinnedSummary } from "./PinnedSummary";
import type { SummarySectionInput } from "./summaryModel";

const base: SessionSummary = { scheduled: [], pullRequests: [], outputs: [], subagents: [], sources: [], plans: [] };
const sections: SummarySectionInput[] = [
  {
    id: "checks",
    title: "Checks",
    provider: "file",
    rows: [
      { title: "Build passes", subtitle: "macOS · 3m", icon: "task", badge: "ok", provenance: "user" },
      { title: "Agent suggestion", href: "https://example.com/review", icon: "agent", provenance: "agent" },
    ],
  },
];
const props = {
  summary: base,
  sections,
  cwd: "/Users/you/src/project",
  projectName: "project",
  mode: "pinned" as const,
  onClose: () => undefined,
};
export default componentEntry({
  id: "agent-pane.pinned-summary-b",
  title: "Pinned summary B",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 390, normal: 640, wide: 980 },
  anchors: [{ selector: ".acpmux-pinned-summary" }],
  covers: ["agent-session/acpmux/summary/PinnedSummary.tsx#PinnedSummary"],
  load: () => Promise.resolve(PinnedSummary),
  styles: () => import("./summary.css"),
  variants: {
    "pinned-wide": { note: "Dense pinned card with project header, plan and data sections.", props },
    "narrow-popover": {
      note: "Narrow fallback reserves space below the header.",
      props: { ...props, mode: "popover" },
    },
    empty: { note: "No rows keeps the card quiet.", props: { ...props, sections: [] } },
    busy: {
      note: "A busy plan stays visible with View all.",
      props: {
        ...props,
        summary: { ...base, plans: [{ id: "plan", text: "Reviewing changed files", state: "running" }] },
      },
    },
    "user-section": { note: "User supplied rows render as trusted data.", props },
    "agent-section": { note: "Agent links require inline confirmation.", props },
    "failed-provider": {
      note: "Provider failures remain a quiet row.",
      props: {
        ...props,
        sections: [
          {
            id: "failed",
            title: "Checks",
            provider: "command",
            rows: [{ title: "Provider failed: unavailable", icon: "warning", state: "failed", provenance: "user" }],
          },
        ],
      },
    },
  },
});
