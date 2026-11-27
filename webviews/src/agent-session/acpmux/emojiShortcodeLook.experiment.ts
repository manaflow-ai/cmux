// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the prompt's `:shortcode` emoji menu draws (Leo, 2026-11-03: "yo wtf i want this kind of
/// feature in cmux-next too", of Claude desktop's `:` popover). Gallery `agent-pane.composer-emoji`.
export const emojiShortcodeLook = defineExperiment({
  id: "emoji-shortcode-look",
  title: "Composer emoji shortcodes",
  description:
    "How the menu that `:` and two letters open in the prompt lists emoji. Every arm takes arrows, Return or Tab and Esc the same way.",
  arms: {
    caret: {
      label: "Compact at the caret",
      description: "A narrow list over the typed `:`, glyph then `:shortcode:`, as Claude desktop draws it.",
    },
    wide: {
      label: "Full width",
      description: "The @ and / menus' full-width list over the composer, glyph then `:shortcode:`.",
    },
    strip: {
      label: "Glyph strip",
      description:
        "One row of large glyphs over the typed `:`, the chosen one's `:shortcode:` under them, as Slack draws it.",
    },
  },
  defaultArm: "caret",
});
