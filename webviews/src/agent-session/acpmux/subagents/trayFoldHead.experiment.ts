// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the running tray's folded header says (SubagentTray.tsx). Folded, it is the one line above
/// the composer, so it names what runs, as Claude Code's running-tasks list does: a subagent by its
/// task, a command by its description or its short command (Leo, 2026-11-03: "the "running" bar
/// above the composer is currently no longer usable bc it doesn't display much", on a bar that read
/// only "1 subagent running · 1 command 4s"). Open, the lines name them and the header keeps its
/// counts. Every arm stays one row. Compare them in the gallery's `agent-pane.subagent-tray-names`.
export const trayFoldHeadLook = defineExperiment({
  id: "subagent-tray-fold-head",
  title: "Running tray folded header",
  description:
    "What the running tray's header says: each kind's mark and count (hover a kind for its names), the newest two by name, the newest one, or only counts.",
  arms: {
    kinds: {
      label: "Kinds with marks",
      description:
        "Folded and open, each kind's mark and count (1 message · 1 wait); hovering a kind names what it counts.",
    },
    two: {
      label: "Newest two",
      description: "The newest two running items by name, then +N more; a narrow pane names the newest one.",
    },
    one: {
      label: "Newest one",
      description: "The newest running item by name, then +N more.",
    },
    counts: {
      label: "Counts",
      description: "Only counts (1 subagent · 1 command), as before, for comparison.",
    },
  },
  // One newest name that fits beats two cut ones (Leo, 2026-11-03, on a bar that read "Context
  // around the ask and memory search · glaeda-gh wait pid 88061 --timeout 800; tail -6 /t… +6 more").
  // Then the counts with each kind's mark won (Leo, 2026-11-21, on the open header's "1 message · 1
  // wait": "almost makes more sense to have at baseline"; he wants its icons folded, "like before",
  // to hover across).
  defaultArm: "kinds",
});
