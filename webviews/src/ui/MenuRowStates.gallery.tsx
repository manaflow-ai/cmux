// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
// Experiment menu-row-states (menuRowStates.experiment.ts): a disabled row's amber reason, an async
// row's inline spinner, the reserved check column and the trigger joined to its open menu. View
// Compare arms puts off, on and on-quiet side by side; the `*-on` variants pin the arm for stills.
import { componentEntry } from "../gallery/format";
import { menuRowStates } from "./menuRowStates.experiment";
import { menuStyleV2 } from "./menuStyleV2.experiment";
import {
  MenuTasteGallery,
  openPicker,
  openPrMidSpin,
  openPrSettled,
  openSceneMenu,
  type MenuTasteProps,
} from "./menuTaste.galleryFixtures";

const on = { [menuRowStates.id]: "on" };
const onV2 = { ...on, [menuStyleV2.id]: "v2" };

export default componentEntry<MenuTasteProps>({
  id: "ui.menu-row-states",
  title: "Menu row states (experiment)",
  area: "UI primitives",
  experimental: true,
  height: 420,
  widths: { narrow: 420, normal: 560, wide: 820 },
  covers: ["ui/Menu.tsx#MenuItem", "ui/Menu.tsx#MenuRadioItem", "ui/Menu.tsx#MenuButton"],
  anchors: [{ selector: ".menu-taste-trigger" }],
  load: async () => MenuTasteGallery,
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./menuTaste.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening the menu or a row's spinner must not move the trigger.",
    },
    popupLayer: { value: true, reason: "The menu stays topmost and inside the stage." },
    settleMaxMs: { value: 250, reason: "Opening a menu and picking a row are local interactions." },
  },
  experiment: {
    definition: menuRowStates,
    script: [{ name: "Open the menu (Open PR picked in the actions menu)", run: openSceneMenu }],
  },
  variants: {
    "model-picker": {
      note: "The model picker: Claude Opus checked, Codex disabled (its reason under row states).",
      props: { scene: "picker" },
      play: openPicker,
    },
    "model-picker-on": {
      note: "Row states on: 'Needs sign-in' under Codex in amber, the trigger in the panel's fill.",
      props: { scene: "picker", arms: on },
      play: openPicker,
    },
    "open-pr": {
      note: "Open PR picked: under row states it spins in its trailing slot and the menu keeps its size.",
      props: { scene: "actions" },
      play: openPrMidSpin,
    },
    "open-pr-on": {
      note: "Row states on: Open PR mid-spin.",
      props: { scene: "actions", arms: on },
      play: openPrMidSpin,
    },
    "open-pr-settles-on": {
      note: "Row states on: Open PR spins about a second at the menu's size, then the menu closes.",
      props: { scene: "actions", arms: onV2, settleMs: 1200 },
      play: openPrSettled,
    },
    "open-pr-on-v2": {
      note: "Row states on with menu style v2: Open PR mid-spin, Stop Agent in red.",
      props: { scene: "actions", arms: onV2 },
      play: openPrMidSpin,
    },
  },
});
