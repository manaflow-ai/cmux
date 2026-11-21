// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a line in the composer hat opens what it stands for (SubagentTray.tsx `line`, AgentLine.tsx).
/// Lawrence, 2026-11-20: "ui for opening subagents is very confusing". Today one chevron means two
/// things: a subagent's line opens its view on a click, while a command's or a started chat's line
/// expands in place and holds Open chat or Open in terminal inside. The arms try three ways out. The
/// header's own Rolodex of marks (cmux #47923) is a separate experiment that pairs with the `rolodex`
/// arm. Compare them in the gallery's `agent-pane.composer-hat-open`.
export const hatOpenLook = defineExperiment({
  id: "composer-hat-open",
  title: "Composer hat: opening a line",
  description:
    "How a hat line opens its subagent, command or chat: as today, a hover Rolodex card with a click that opens, the whole row opening with a chevron for details, or today's lines with the hide control in the header.",
  arms: {
    today: {
      label: "Today",
      description:
        "A subagent's line opens its view; a command's or a chat's line expands in place with Open chat or Open in terminal inside. The tuck control hangs from the hat's top edge.",
    },
    rolodex: {
      label: "Hover Rolodex",
      description:
        "Pointing at a line flips a card up over it with its whole task, state and latest step; running the pointer down the list flips from card to card. A click on a subagent opens it; a command or a chat still expands in place for its output and Open chat.",
    },
    row: {
      label: "Row opens, chevron details",
      description:
        "The whole row opens what it stands for, for every kind of line; the chevron is its own button and expands the line's details in place.",
    },
    hide: {
      label: "Hide in the header",
      description:
        "Today's lines; the hide control leaves the hat's top edge (which keeps only the resize rim) for a hide button in the header's trailing controls, shown while the pointer is on the hat.",
    },
  },
  defaultArm: "today",
});
