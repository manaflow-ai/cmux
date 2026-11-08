// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the running tray's header counts (SubagentTray.tsx, trayHeadKinds.ts). Leo, 2026-11-03, on a
/// header that read only "4 commands 6m 47s" over four commands and a finished subagent: "the top
/// should be able to split per background task/scheduled wait/subagent/subsession? actually im not
/// sure if we want expectations for other sessions to be "sub" and idk how we wanna depict
/// "subagents of a different model family"... i feel like we should... but anyways the top bit aka
/// what the collapsed area shows i think can show much more interesting stuf fthan it does now". Every
/// arm keeps the one row, the time after the counts and the chevron in the lines' column. Compare them
/// in the gallery's `agent-pane.subagent-tray-kinds`.
export const trayHeadKindsLook = defineExperiment({
  id: "subagent-tray-head-kinds",
  title: "Running tray header kinds",
  description:
    "What the running tray's header counts: each kind, what ended and failed, and a subagent of another model family by its mark.",
  arms: {
    kinds: {
      label: "Kinds and marks",
      description:
        "Running subagents, sessions, commands and what waits, then what ended (done, failed in red); another model family's mark after its subagents.",
    },
    plain: {
      label: "Kinds, no marks",
      description: "The same counts, with no mark for a subagent of another model family.",
    },
    sub: {
      label: "Sessions as subagents",
      description: "A session the agent started counts as a subagent, as before; what ended and failed still count.",
    },
    running: {
      label: "Running only",
      description: "Only what runs (4 commands), as before, for comparison.",
    },
  },
  // Sessions read as sessions (another chat with its own sidebar row, not part of this one), and a
  // Codex subagent under Claude shows its mark: the line already draws it, so the header says the same.
  defaultArm: "kinds",
});
