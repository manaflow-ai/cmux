// l10n-allow-file: gallery fixtures (todo items), not shipped UI.
// Looks of the agent's todo list (PlanList.tsx) beside Claude desktop's checklist card (Leo,
// 2026-10-29: "we want to have that capabilitiy of rendering like claude code desktop has stuff
// organized"): card (shipped, a quiet bordered card, one row per step), borderless (the rows
// alone), and count (the card with its "1 of 4 tasks done" line shown as a header). The marks are
// the same in each: a filled check is done, a thin spinner runs, a dashed circle waits. Ended, the
// list folds to its progress line: shipped as a bare line (`ended-line`), beside the line kept in
// its card (`ended-card`) and the whole list left open (`ended-open`, before 2026-11-03).
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxPlanEntry } from "../model";
import { PlanList } from "./PlanList";
import { setPlanOpen } from "./planOpen";

setPlanOpen("gallery-ended-open", true);

type Look = "card" | "borderless" | "count" | "ended-card";
type Props = { look: Look; entries: AcpmuxPlanEntry[]; ended?: boolean; id?: string };

function PlanInPane({ look, entries, ended, id }: Props) {
  return (
    <div className="acpmux-shell cv-plan-looks-gallery" data-plan-look={look} style={{ padding: 16 }}>
      <PlanList entries={entries} ended={ended} id={id} />
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
    "ended-line": {
      note: "Shipped after the turn ended: the list folds to a bare muted line, its count and a chevron, like the turn's other summary lines.",
      props: { look: "card", entries: midway.map((entry) => ({ ...entry, status: "completed" })), ended: true },
    },
    "ended-line-partial": {
      note: "Shipped, a turn that ended with steps left: a dashed ring instead of the filled check.",
      props: { look: "card", entries: midway, ended: true },
    },
    "ended-card": {
      note: "Alternative: the folded line kept inside its bordered card.",
      props: { look: "ended-card", entries: midway.map((entry) => ({ ...entry, status: "completed" })), ended: true },
    },
    "ended-open": {
      note: "Alternative (shipped before 2026-11-03): opened again, or never folded; the step left in progress stops spinning.",
      props: { look: "card", entries: midway, ended: true, id: "gallery-ended-open" },
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
