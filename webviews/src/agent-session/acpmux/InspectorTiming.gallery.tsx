// l10n-allow-file: synthetic gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { InspectorTurn } from "./InspectorTiming";

const start = Date.UTC(2026, 10, 20, 10);
const turns: InspectorTurn[] = [
  {
    seq: 1,
    startedAt: start,
    endedAt: start + 30000,
    wallMs: 30000,
    toAgentMs: 2400,
    queuedMs: 6000,
    queuedOn: "busy",
    firstModelMs: 1600,
    prompt: "Inspect the slow request",
    status: "completed",
  },
  {
    seq: 40,
    startedAt: start + 40000,
    endedAt: start + 60000,
    wallMs: 20000,
    toAgentMs: 0,
    firstModelMs: 900,
    prompt: "Check the configuration",
    status: "completed",
  },
  { seq: 80, startedAt: start + 65000, prompt: "A turn without recorded send stamps", status: "running" },
];

export default componentEntry({
  id: "agent-pane.inspector-timing",
  title: "Session timing inspector",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 380, normal: 760, wide: 980 },
  covers: ["agent-session/acpmux/InspectorTiming.tsx#SessionTiming"],
  load: async () => (await import("./InspectorTiming")).SessionTiming,
  styles: () => Promise.all([import("../shared/styles.css"), import("./styles.css")]),
  variants: {
    bars: {
      props: { turns, look: "bars" },
      note: "Chosen: turn and phase bars (to agent, queued, first output) share one session time axis; idle gaps stay empty.",
    },
    compact: { props: { turns, look: "compact" }, note: "Thin tracks leave more room for long sessions." },
    stacked: { props: { turns, look: "stacked" }, note: "Duration sits under the prompt in narrow panes." },
    empty: { props: { turns: [] } },
  },
});
