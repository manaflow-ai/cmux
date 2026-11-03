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
    "What the folded running tray's one line says: what runs by kind with times, the newest two by name, the newest one, or only counts.",
  arms: {
    kinds: {
      label: "By kind",
      description:
        "Each kind's count and its oldest one's time: subagents, chats, messages, waits, servers, commands (2 subagents 4m / 2 waits 30s).",
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
      description: "Only counts (1 subagent running · 1 command), as before, for comparison.",
    },
  },
  // By kind (trayKinds.ts; Leo, 2026-11-03: "you can split up commands/waits/bg tasks/subagents/maybe
  // agent sessions you expect something from ... so you can fit that all in counts of stuff and maybe
  // times all in one line like a \ b \ c or a | b| c or a / b / c"). Before it, one newest name that
  // fits beat two cut ones (on a bar that read "Context around the ask and memory search · glaeda-gh
  // wait pid 88061 --timeout 800; tail -6 /t… +6 more").
  defaultArm: "kinds",
});
