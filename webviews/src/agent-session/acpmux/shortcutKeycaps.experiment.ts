// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Shortcut keycaps in buttons (Taste Board #136, #137): a button whose action has a shortcut draws
/// that shortcut inside itself as small keycaps, so the key is learned where the button is pressed,
/// not only in a tooltip. Off by default. The keycaps come from the host's live bindings
/// (AgentPaneShortcuts, applyShortcuts), so a rebind in Settings or cmux.json shows at once.
/// Dogfood opts in from `cmux.experiments`: {"shortcut-keycaps":"filled"}.
export const shortcutKeycaps = defineExperiment({
  id: "shortcut-keycaps",
  title: "Shortcut keycaps in buttons",
  description:
    "The header New button, All sessions and All Chats draw their shortcut as inline keycaps. Watch the row's width, how the caps read on light and dark themes, and whether a rebind shows at once.",
  arms: {
    off: { label: "Off (today)", description: "No keycaps in buttons; the shortcut stays in the tooltip." },
    filled: { label: "Filled", description: "One tinted cap per key, as the permission card's keycaps." },
    outlined: { label: "Outlined", description: "One hairline-outlined cap per key, no fill." },
    compact: { label: "Compact", description: "The whole shortcut in one small tinted cap, as menus show it." },
  },
  defaultArm: "off",
});

export type ShortcutKeycapLook = keyof typeof shortcutKeycaps.arms;
