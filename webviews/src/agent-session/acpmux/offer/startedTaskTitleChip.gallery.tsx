// l10n-allow-file: gallery fixtures and comparison notes.
// Settings > Advanced > Experiments > Started Tasks: Title Opens Chat, side by side with today's row.
// Leo 2026-11-05: "subagents need to have their clickable bit be highlighted instead of the whole line
// click sending me to the subagent righ split". With the switch on, a started task opens its chat
// and lights from its title chip only, as a returned result's line already does.
import { setExperimentSwitches } from "../../../experiments/switches";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxSessionOffer } from "../model";
import { SuggestedTasks } from "./SuggestedTasks";

type Props = { offers: AcpmuxSessionOffer[] };

const started = (n: number, title: string, status: string, activity?: string): AcpmuxSessionOffer => ({
  offerId: `offer-${n}`,
  title,
  prompt: title,
  cwd: "/Users/you/Projects/storefront",
  worktree: false,
  outcome: "accepted",
  childSessionId: `child-${n}`,
  childStatus: status,
  ...(activity ? { activity } : {}),
});

const live = [
  started(1, "Cart: add width and height to thumbnails", "running", "Reading CartLineItem.tsx"),
  started(2, "Images: lazy-load below the fold", "waiting"),
  started(3, "Checkout: label the form fields", "idle"),
];

const long = [
  started(
    1,
    "Checkout: label every form field, group the shipping and billing addresses, and announce errors",
    "running",
    "Reading CheckoutForm.tsx and AddressFields.tsx",
  ),
  started(2, "Images: lazy-load below the fold", "idle"),
];

function GalleryStartedTasks({ offers }: Props) {
  return (
    <div className="acpmux-shell">
      <div data-tasks-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
        <SuggestedTasks
          offers={offers}
          actions={{
            start: async () => undefined,
            here: async () => undefined,
            dismiss: async () => undefined,
            open: () => undefined,
            reserve: async () => "ticket",
          }}
        />
      </div>
    </div>
  );
}

function show(on: boolean) {
  return async (ctx: PlayContext) => {
    setExperimentSwitches({ startedTaskTitleChip: on });
    await ctx.waitFor(() => {
      const rows = ctx.document.querySelectorAll(".acpmux-task-started");
      if (rows.length === 0) return false;
      const chips = ctx.document.querySelectorAll(".acpmux-task-started .cv-agent-tag.is-open");
      const buttons = ctx.document.querySelectorAll("button.acpmux-task-row");
      return on ? chips.length === rows.length && buttons.length === 0 : buttons.length === rows.length;
    });
  };
}

export default componentEntry<Props>({
  id: "agent-pane.started-task-title-chip",
  title: "Started tasks: title opens chat",
  area: "Agent pane",
  pane: true,
  height: 150,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-tasks-fixture]" }],
  covers: ["agent-session/acpmux/offer/SuggestedTasks.tsx#SuggestedTasks"],
  styles: () => import("../styles.css"),
  load: async () => GalleryStartedTasks,
  variants: {
    row: {
      note: "Switch off (today): each started task is one button; the whole line lights and opens its chat.",
      props: { offers: live },
      play: show(false),
    },
    chip: {
      note: "Switch on: only the title chip opens the chat; status, activity and the dot are plain text.",
      props: { offers: live },
      play: show(true),
    },
    "chip-hover": {
      note: "Switch on, pointer on the first title: the chip and its chevron light, the row stays unlit.",
      props: { offers: live },
      play: async (ctx) => {
        await show(true)(ctx);
        await ctx.hover({ selector: ".acpmux-task-started .cv-agent-tag.is-open" });
      },
    },
    "chip-long": {
      note: "Switch on, a long title: the chip truncates at 70% and the activity keeps its room.",
      props: { offers: long },
      height: 120,
      play: show(true),
    },
  },
});
