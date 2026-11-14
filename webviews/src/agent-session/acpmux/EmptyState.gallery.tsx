// l10n-allow-file: gallery fixtures (sample projects and machines), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { EmptyStateProjects } from "./EmptyState";
import type { TourOfferActions } from "./repoTour/TourOffer";
import type { Project } from "./ProjectChooser";

type Props = { project?: string; picker?: EmptyStateProjects; tour?: TourOfferActions };

const tour: TourOfferActions = { onTake: () => undefined, onDismiss: () => undefined };

const projects: Project[] = [
  { cwd: "/Users/you/src/cmux", label: "cmux" },
  { cwd: "/Users/you/src/atlas-web", label: "atlas-web" },
  { cwd: "/Users/you/src/relay", label: "relay" },
  { cwd: "/home/dev/api-server", label: "api-server", peer: "build-box", host: "build-box" },
  { cwd: "/workspace/ml-train", label: "ml-train", peer: "cloud-1", host: "cmux Cloud 1" },
];

const picker = (current?: string): EmptyStateProjects => ({
  projects,
  ...(current ? { current } : { noProject: true }),
  onPick: () => undefined,
  onBrowse: () => undefined,
  onNoProject: () => undefined,
});

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-project-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
};

const search: Play = async (ctx) => {
  await open(ctx);
  await ctx.type("api");
  // The pinned actions (No folder, + Add folder…) stay above the results while
  // searching (#26536); the search filters only the scrolling list under them.
  await ctx.waitFor(() => ctx.document.querySelectorAll('.ui-combobox-scroll [role="option"]').length === 1);
};

export default componentEntry<Props>({
  id: "agent-pane.empty-state",
  title: "New chat hero project picker",
  area: "Agent pane",
  covers: ["agent-session/acpmux/EmptyState.tsx#EmptyState", "agent-session/acpmux/repoTour/TourOffer.tsx#TourOffer"],
  load: () => import("./EmptyState").then((module) => module.EmptyState),
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 420,
  anchors: [{ selector: ".acpmux-project-button" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening the picker uses a portal and must not move the question." },
    layoutShiftMax: { value: 0, reason: "The menu floats below the question without reflowing the hero." },
    longFrameFailMs: { value: 33, reason: "The picker opens and filters on the first frames." },
  },
  variants: {
    closed: {
      note: "The project in the question is the picker: underlined, with a small chevron.",
      props: { project: "cmux", picker: picker("/Users/you/src/cmux") },
    },
    open: {
      note: "Search, this Mac's projects (the current one checked), other machines' folders with a globe and the machine's name, No folder, and + Add folder….",
      props: { project: "cmux", picker: picker("/Users/you/src/cmux") },
      play: open,
    },
    "no-project": {
      note: "No project: the question has no folder and a quiet Choose folder sits under it; No folder is checked.",
      props: { picker: picker() },
      play: open,
    },
    "tour-offer": {
      note: "A folder no chat has used: Take a tour of this repo hangs under the question, out of its flow, so the question never moves; a dim × (Not now) sits beside it.",
      props: { project: "atlas-web", picker: picker("/Users/you/src/atlas-web"), tour },
    },
    "tour-offer-hover": {
      note: "Hovering the offer fills it; the × closes it for this folder.",
      props: { project: "atlas-web", picker: picker("/Users/you/src/atlas-web"), tour },
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-tour-offer-take" });
      },
    },
    search: {
      note: "Typing filters projects and machines; the pinned No folder and + Add folder… stay above the results while searching.",
      props: { project: "cmux", picker: picker("/Users/you/src/cmux") },
      play: search,
    },
  },
});
