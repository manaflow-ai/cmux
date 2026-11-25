// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import type { QuickActionId } from "./quickActions";

/// The switch in Settings > Advanced > Experiments (`experiments.glassToolbarGroups`, off by default)
/// that turns the glass toolbar on; experiments/switches.ts carries it to the page.
export const GLASS_TOOLBAR_SWITCH = "glassToolbarGroups";

/// How the glass toolbar looks once the switch is on (the desktop coordinator's taste build list,
/// 2026-11-19, item 4: "Glass toolbar groups with shortcut keycaps"). Every arm draws single actions
/// as round glass buttons, the related split actions (Terminal, Split Down, Browser, New tab) in one
/// glass capsule, "..." as a round glass button and a search chip that opens the command palette.
/// The arms differ in how much of each shortcut shows. With the switch off no arm draws anything:
/// the header is today's row.
export const glassToolbarLook = defineExperiment({
  id: "glass-toolbar-look",
  title: "Glass toolbar groups",
  description:
    "The chat header's buttons as round glass singles and one glass capsule for the split actions, with a ⌘K search chip; the arms vary how shortcuts show.",
  arms: {
    keycaps: {
      label: "Keycaps",
      description:
        "Each capsule button carries its shortcut as a small keycap after its glyph; the search chip shows ⌘K.",
    },
    groups: {
      label: "Groups",
      description: "Glyphs only in the capsule; shortcuts stay in tooltips, and only the search chip shows its keycap.",
    },
    labels: {
      label: "Labels",
      description:
        "Capsule buttons show glyph, a short name and the keycap, as a web nav's buttons do; they fold to glyphs when the pane is narrow.",
    },
  },
  defaultArm: "keycaps",
});

export type GlassToolbarLook = keyof typeof glassToolbarLook.arms;

/// The quick actions that share the capsule, in its order: the split and tab actions. The rest
/// (Changes, Files, Preview) stay single round buttons.
export const GLASS_CAPSULE_ACTIONS: ReadonlySet<QuickActionId> = new Set<QuickActionId>([
  "terminal",
  "splitDown",
  "browser",
  "newTab",
]);

/// What the search chip runs and whose keycap it shows: the command palette's chats page, ⌘K in an
/// agent pane by default (`key.agentPane.searchChats`).
export const SEARCH_CHATS_ACTION = "agentPane.searchChats";
