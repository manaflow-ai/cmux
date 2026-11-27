// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
// Experiment menu-style-v2 (menuStyleV2.experiment.ts): the page-drawn menus' v2 look. View
// Compare arms puts off, v2 and v2-glass side by side; the `*-v2` and `*-v2-glass` variants pin an
// arm for plain stills (light and dark: the env's colour scheme).
import { componentEntry } from "../gallery/format";
import { menuStyleV2 } from "./menuStyleV2.experiment";
import { menuRowStates } from "./menuRowStates.experiment";
import {
  MenuTasteGallery,
  openPicker,
  openSceneMenu,
  openWorkspaceSplit,
  type MenuTasteProps,
} from "./menuTaste.galleryFixtures";

const style = (arm: string) => ({ [menuStyleV2.id]: arm });
const pickerArms = (arm: string) => ({ ...style(arm), [menuRowStates.id]: "on" });

export default componentEntry<MenuTasteProps>({
  id: "ui.menu-style-v2",
  title: "Menu style v2 (experiment)",
  area: "UI primitives",
  experimental: true,
  height: 520,
  widths: { narrow: 480, normal: 640, wide: 820 },
  covers: ["ui/ContextMenu.tsx#ContextMenu", "ui/Menu.tsx#MenuPopup", "ui/Menu.tsx#Submenu"],
  anchors: [{ testId: "workspace-row" }],
  load: async () => MenuTasteGallery,
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./menuTaste.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening a menu or its submenu must not move the row that opened it.",
    },
    popupLayer: {
      value: true,
      reason: "The menu and its submenu stay topmost and inside the stage.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Opening a menu and hovering a submenu row are local interactions.",
    },
  },
  experiment: {
    definition: menuStyleV2,
    script: [{ name: "Open the menu (the workspace menu with Split open)", run: openSceneMenu }],
  },
  variants: {
    "workspace-split": {
      note: "The workspace's right-click menu, Split open: the arm the URL names (Compare arms: off, v2, v2-glass).",
      props: { scene: "workspace" },
      play: openWorkspaceSplit,
    },
    "workspace-split-v2": {
      note: "V2: inset pills, shortcut column, Split flush with its row, icons all-or-none per group, Close Workspace last in red.",
      props: { scene: "workspace", arms: style("v2") },
      play: openWorkspaceSplit,
    },
    "workspace-split-v2-glass": {
      note: "V2 glass: the same rows on a clearer 12 px panel with a soft shadow in dark too.",
      props: { scene: "workspace", arms: style("v2-glass") },
      play: openWorkspaceSplit,
    },
    "model-picker": {
      note: "The model picker, Claude Opus checked, Codex disabled with its reason (row states on).",
      props: { scene: "picker", arms: { [menuRowStates.id]: "on" } },
      play: openPicker,
    },
    "model-picker-v2": {
      note: "The model picker in v2 with row states on.",
      props: { scene: "picker", arms: pickerArms("v2") },
      play: openPicker,
    },
  },
});
