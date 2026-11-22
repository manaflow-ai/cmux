// l10n-allow-file: gallery fixtures (sample projects and machines), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { EmptyStateProjects } from "./EmptyState";
import type { NewChatEntrance } from "./newChatEntrance";
import type { TourOfferActions } from "./repoTour/TourOffer";
import type { Project } from "./ProjectChooser";

type Props = {
  project?: string;
  picker?: EmptyStateProjects;
  tour?: TourOfferActions;
  entrance?: NewChatEntrance;
  /** Draws the hero in a pane with a composer under it, as App.tsx lays out a new chat, so the
   *  entrance's composer part shows. The composer here is a stand-in box with a real textarea. */
  inPane?: boolean;
};

/** The hero, alone or in a pane over a composer (the entrance variants). */
const loadHero = () =>
  import("./EmptyState").then(({ EmptyState }) => {
    function Hero({ inPane, ...props }: Props) {
      if (!inPane) return <EmptyState {...props} />;
      return (
        <div
          className="acpmux-main"
          data-new-chat=""
          style={{ display: "flex", flexDirection: "column", height: "100%" }}
        >
          <EmptyState {...props} />
          <div className="acpmux-dock">
            <div className="acpmux-composer">
              <div className="acpmux-composer-box" style={{ padding: "12px 16px" }}>
                <textarea
                  aria-label="Message"
                  placeholder="Ask anything"
                  rows={2}
                  style={{
                    resize: "none",
                    border: 0,
                    outline: 0,
                    background: "transparent",
                    color: "inherit",
                    font: "inherit",
                  }}
                />
              </div>
            </div>
          </div>
        </div>
      );
    }
    return Hero;
  });

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
  covers: [
    "agent-session/acpmux/EmptyState.tsx#EmptyState",
    "agent-session/acpmux/repoTour/TourOffer.tsx#TourOffer",
    "agent-session/acpmux/newChatEntrance.ts#playNewChatEntrance",
  ],
  load: loadHero,
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 420,
  anchors: [{ selector: ".acpmux-project-button" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening the picker uses a portal and must not move the question." },
    layoutShiftMax: { value: 0, reason: "The menu floats below the question without reflowing the hero." },
    longFrameFailMs: { value: 33, reason: "The picker opens and filters on the first frames." },
  },
  keywords: ["entrance", "animation", "startup", "motion", "spring"],
  options: [
    {
      id: "entrance",
      label: "Entrance",
      kind: "choice",
      choices: [
        { value: "rise", label: "Rise (default)" },
        { value: "bloom", label: "Bloom" },
        { value: "focus", label: "Focus" },
        { value: "off", label: "Off" },
      ],
      defaultValue: "rise",
    },
  ],
  variants: {
    "entrance-rise": {
      note: 'The default (Leo 2026-11-22: "claude code has such a nice animation on startup"): the question, the line under it and the composer rise 10 px into place on one spring (response 0.42 s, damping 0.82, as iOS), 40 ms apart, at rest by 440 ms. The composer types at frame 0.',
      props: { picker: picker(), entrance: "rise", inPane: true },
    },
    "entrance-bloom": {
      note: "Bloom: the question grows from 92% at its center, then the rest rises after it.",
      props: { picker: picker(), entrance: "bloom", inPane: true },
    },
    "entrance-focus": {
      note: "Focus: the question and the line under it come from out of focus to sharp; the composer only rises.",
      props: { picker: picker(), entrance: "focus", inPane: true },
    },
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
