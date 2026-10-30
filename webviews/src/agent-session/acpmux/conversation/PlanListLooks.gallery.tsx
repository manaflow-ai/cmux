// l10n-allow-file: gallery fixtures (todo items), not shipped UI.
// Looks of the agent's todo list (PlanList.tsx) beside Claude desktop's checklist card (Leo,
// 2026-10-29: "we want to have that capabilitiy of rendering like claude code desktop has stuff
// organized"): card (shipped, a quiet bordered card, one row per step), borderless (the rows
// alone), and count (the card with its "1 of 4 tasks done" line shown as a header). The marks are
// the same in each: a filled check is done, a thin spinner runs, a dashed circle waits.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPlanEntry } from "../model";
import { PlanList } from "./PlanList";

type Look = "card" | "borderless" | "count";
type Props = { look: Look; entries: AcpmuxPlanEntry[]; ended?: boolean };

function PlanInPane({ look, entries, ended }: Props) {
  return (
    <div className="acpmux-shell cv-plan-looks-gallery" data-plan-look={look} style={{ padding: 16 }}>
      <PlanList entries={entries} ended={ended} />
    </div>
  );
}

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });
const running = [
  todo("Check the current auth config", "in_progress"),
  todo("Switch the CLI to the personal account", "pending"),
  todo("Verify the login", "pending"),
];
const midway = [
  todo("Reproduce the layout shift", "completed"),
  todo("Add image dimensions to ProductCard", "in_progress"),
  todo("Reserve space with an aspect-ratio fallback", "pending"),
  todo("Check the product grid in the preview", "pending"),
];

export default componentEntry<Props>({
  id: "agent-pane.plan-list-looks",
  title: "Todo list: looks",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/PlanList.tsx#PlanList"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./PlanListLooks.gallery.css")]),
  load: async () => PlanInPane,
  variants: {
    card: {
      note: "Shipped: a quiet bordered card, one row per step; in progress spins, pending is a dashed circle.",
      props: { look: "card", entries: running },
    },
    "card-midway": {
      note: "Shipped look, a step done (filled check) above the running one.",
      props: { look: "card", entries: midway },
    },
    "card-ended": {
      note: "Shipped look after the turn ended: the step left in progress stops spinning.",
      props: { look: "card", entries: midway, ended: true },
    },
    borderless: {
      note: "Alternative: the rows alone, no card.",
      props: { look: "borderless", entries: midway },
    },
    count: {
      note: "Alternative: the card with its progress line shown as a header.",
      props: { look: "count", entries: midway },
    },
  },
});
