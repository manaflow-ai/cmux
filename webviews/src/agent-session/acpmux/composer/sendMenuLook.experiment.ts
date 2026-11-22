// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the send slot's menu (SendMenu.tsx) draws each row's key. Every arm is the house context
/// menu with the same rows; only the right-hand key and a leading icon differ. In the app the
/// host draws the menu natively from the same rows and shortcut text. Gallery
/// `agent-pane.composer-send-menu`.
export const sendMenuLook = defineExperiment({
  id: "send-menu-look",
  title: "Send menu keys",
  description: "The send button's right-click menu: how each row shows the key that sends that way from the prompt.",
  arms: {
    text: {
      label: "Shortcut text",
      description: "The key as plain secondary text on the right, as every house menu and the native menu draw it.",
    },
    caps: {
      label: "Key caps",
      description: "Each key in its own small cap on the right, as the permission card's answer keys.",
    },
    icons: {
      label: "Icons + text",
      description: "A leading icon per row (send, waiting, fork) and the key as plain text.",
    },
  },
  defaultArm: "text",
});

export type SendMenuLookArm = keyof typeof sendMenuLook.arms;
