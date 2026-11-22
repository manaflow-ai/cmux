// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// A pull request row's own "Fix N failing checks" button in Session Info > Changes (FixChecksButton.tsx).
/// It counts and sends only the branch's own reds: a check that fails on the base branch's tip too is
/// listed as "failing on base too, not sent". Off ships today's row, where Labs' ⋯ menu item is the only way.
/// Compare the arms in the gallery's `agent-pane.session-info-changes-fix-checks`.
export const fixChecksButton = defineExperiment({
  id: "changes-fix-checks-button",
  title: "Changes: Fix failing checks button",
  description:
    "A button on the pull request row that sends the agent this branch's own failing checks, leaving out base reds.",
  arms: {
    off: {
      label: "Now",
      description: "No button; Labs' ⋯ menu Fix Failing Checks drafts the message into the composer.",
    },
    quiet: {
      label: "Quiet text button",
      description:
        "A muted text button under the row: Fix 2 failing checks. A click drafts the message into the composer.",
    },
    count: {
      label: "Count and hover list",
      description:
        "A red-count button; hovering it lists what it sends (name, failing step) and the base reds it leaves out. A click drafts it.",
    },
    preview: {
      label: "Preview, then Send",
      description: "A click opens the message the agent will get, with the base reds left out named; Send sends it.",
    },
  },
  defaultArm: "off",
});

export type FixChecksLook = keyof typeof fixChecksButton.arms;
