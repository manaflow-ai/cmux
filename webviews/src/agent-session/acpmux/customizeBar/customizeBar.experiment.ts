// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the chat shows a live customization's preview with its Apply, Discard, Undo and Save as
/// profile (CustomizeBar.tsx). Leo, 2026-11-25: "the customization live... in the gui chat". Off
/// ships: compare the arms in the gallery's `agent-pane.customize-bar`, then pick one.
export const customizeBarPlace = defineExperiment({
  id: "chat-customize-bar",
  title: "Chat: live customization's Apply / Undo bar",
  description:
    "While a customization previews live (the chat's agent changed cmux), the chat shows its wish, the parts it changed and Apply, Discard, Undo and Save as profile: a slim strip over the composer, a card in the hat, or a chip that opens them.",
  arms: {
    off: {
      label: "Off",
      description: "No bar: the person says apply, discard or undo in the chat (/customize apply).",
    },
    strip: {
      label: "Strip",
      description: "One row in the composer's hat: the wish, the changed parts, and the four buttons inline.",
    },
    card: {
      label: "Card",
      description: "A card in the hat: the wish as its title, the parts as tags, problems listed, buttons in a footer.",
    },
    chip: {
      label: "Chip",
      description: "A small 'Previewing' chip in the hat; a click opens the wish, parts and buttons.",
    },
  },
  defaultArm: "off",
});
