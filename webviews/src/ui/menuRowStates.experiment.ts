// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Menu row states (Leo's taste build list, lane taste-menus-v2): a check column every row of a
/// menu with a checkable row reserves, a one-line amber reason under a disabled row ("Needs
/// sign-in"), an async row that spins in its trailing slot until its work settles and then closes
/// the menu (the menu keeps its size), and a menu button that takes the panel's fill while its menu is
/// open. The arm is `data-menu-states` on the menu's root and its button (popupSurface.css); `off`
/// draws neither, nor a reason, nor a spinner slot.
export const menuRowStates = defineExperiment({
  id: "menu-row-states",
  title: "Menu row states",
  description:
    "Disabled reasons, async rows with an inline spinner, a reserved check column and a trigger joined to its open menu.",
  arms: {
    off: {
      label: "Off",
      description: "Today's rows: a disabled row is only dimmed, a pick closes at once.",
    },
    on: {
      label: "On",
      description:
        "Amber reason under a disabled row, spinner in an async row's trailing slot until it settles, trigger filled like the panel.",
    },
    "on-quiet": {
      label: "On, quiet trigger",
      description: "As On, but the trigger keeps its own open fill (only the rows change).",
    },
  },
  defaultArm: "off",
});

export type MenuRowStatesArm = keyof typeof menuRowStates.arms;
