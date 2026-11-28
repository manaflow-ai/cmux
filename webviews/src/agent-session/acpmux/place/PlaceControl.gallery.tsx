// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { PlaceControl } from "./PlaceControl";
import { PLACES } from "./fixtures";

type Props = Parameters<typeof PlaceControl>[0];

const onMode = () => undefined;

const open: Play = async (ctx) => {
  await ctx.click({ selector: 'button[data-menu="Place"]' });
};

export default componentEntry<Props>({
  id: "agent-pane.place-control",
  title: "Place control: Local, Cloud, Auto",
  area: "Agent pane",
  covers: ["agent-session/acpmux/place/PlaceControl.tsx#PlaceControl"],
  pane: true,
  load: () => import("./PlaceControl").then((module) => module.PlaceControl),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 260,
  variants: {
    "menu-local": {
      note: "Shipped, in the composer's location row beside the picker: one chip with the place and a menu of Local, Cloud and Auto. Costs one chip of width, and Auto's rule shows in the menu where it is chosen.",
      props: { look: "menu", place: PLACES.local, onMode },
    },
    "menu-open": {
      note: "The chip's menu: three radio rows, Auto's rule on one line under it.",
      props: { look: "menu", place: PLACES.autoLocal, onMode },
      play: open,
    },
    "autocloud-off": {
      note: 'Settings > Machines\' AutoCloud on, Cloud Toggle off: this chat with AutoCloud off. Leo, 2026-11-27: "remember we need to be able to toggle a chat on and off of autocloud".',
      props: { look: "menu", place: PLACES.twoLocal, onMode },
    },
    "autocloud-open": {
      note: "The same chat's menu: two rows, Local (AutoCloud off) and Auto (AutoCloud on); no Cloud row without Cloud Toggle.",
      props: { look: "menu", place: PLACES.twoLocal, onMode },
      play: open,
    },
    "autocloud-on": {
      note: "AutoCloud on for this chat, still on this Mac.",
      props: { look: "menu", place: PLACES.twoAuto, onMode },
    },
    "autocloud-on-cloud": {
      note: "AutoCloud on and moved to its Cloud VM; picking Local brings it back.",
      props: { look: "menu", place: PLACES.twoAutoCloud, onMode },
    },
    "menu-auto-cloud": {
      note: "Auto, running on its Cloud VM now: the face says both.",
      props: { look: "menu", place: PLACES.autoCloud, onMode },
    },
    "menu-moving": {
      note: "While a move runs the face says where it goes; the card above the composer has the detail.",
      props: { look: "menu", place: PLACES.moving, onMode },
    },
    "segmented-local": {
      note: "Rejected for the composer row: three segments always visible, one click to any place. It is about 220 px wide, more than the row has next to the folder and machine chips.",
      props: { look: "segmented", place: PLACES.local, onMode },
    },
    "segmented-cloud": {
      note: "Cloud picked: the dot marks where it runs.",
      props: { look: "segmented", place: PLACES.cloud, onMode },
    },
    "segmented-auto": {
      note: "Auto picked: its rule shows beside the segments on one line.",
      props: { look: "segmented", place: PLACES.autoLocal, onMode },
    },
    "segmented-moving": {
      note: "The segments dim while a move runs.",
      props: { look: "segmented", place: PLACES.moving, onMode },
    },
    "rows-local": {
      note: "Better for a settings page or the session info panel than the composer row: three stacked rows, each with where it runs under its name.",
      props: { look: "rows", place: PLACES.local, onMode },
    },
    "rows-auto": {
      note: "Auto picked: its rule is the row's second line.",
      props: { look: "rows", place: PLACES.autoCloud, onMode },
    },
  },
});
