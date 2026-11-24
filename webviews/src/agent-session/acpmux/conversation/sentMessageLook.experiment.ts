// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How an opened sent message shows its words and the call behind them (ask-64e107ccf0; Leo,
/// 2026-11-07, on a "Sent to" row whose Raw showed a heavy Shell card under the message: "Did we not
/// fix this formatting yet? Um, like the raw thing? This is just weird. ... it's just not good,
/// compared to the normal ones."). Every arm draws the line as a received message's (the mark, the
/// recipient's chip, the machine after it, the first line muted) and keeps Raw closed until asked
/// for; opened, Raw is the call's plain command row. Gallery `agent-pane.sent-like-received`.
export const sentMessageLook = defineExperiment({
  id: "sent-message-look",
  title: "Sent message body",
  description: "How an opened message this agent sent draws its words and the Raw affordance for the call behind them.",
  arms: {
    link: {
      label: "Card, Raw link",
      description:
        "The message in the light card a received message opens to, and a quiet Raw link with a chevron under it, as a received message's Details.",
    },
    chevron: {
      label: "Card, chevron only",
      description: "The same card; Raw is a bare chevron at the card's end, named Raw for a screen reader.",
    },
    hover: {
      label: "Card, Raw on hover",
      description: "The same card; the Raw link shows only while the pointer or focus is in the card.",
    },
    plain: {
      label: "Plain, Raw link",
      description: "The words under the line with no card around them, then the Raw link.",
    },
  },
  defaultArm: "link",
});
