// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How "{names} started working" (SubagentStartedLine.tsx) reads when three or more subagents start at
/// once. Every name was a chip on one line, so seven of them were cut to a letter or two each ("M…, iO…,
/// i…, T…, S…, E…, and Li… started working"; Leo, 2026-11-22: "this is so fucking awkward as ui.
/// unilaterally, literally anything else would be a motherfucking improvement. go debate figure shit
/// out. try some variants."). Two names keep the sentence. Compare them in the gallery's
/// `agent-pane.subagent-started-crowd`.
export const startedLineCrowd = defineExperiment({
  id: "subagent-started-crowd",
  title: "Many subagents started",
  description:
    "Three or more subagents starting at once: one icon each and a count, a count alone, the first name and a count, or every name as a chip (before).",
  arms: {
    faces: {
      label: "Icons and a count",
      description:
        '"✦✦✦✦✦✦✦ 7 subagents started working": one icon per subagent, each naming and opening its own, as the composer hat\'s icons do.',
    },
    count: {
      label: "Count alone",
      description: '"✦ 7 subagents started working": the first one\'s icon and the count; the tray names them.',
    },
    first: {
      label: "First name, then a count",
      description: '"✦ Mango sweep +6 more started working": one whole name, the rest a count.',
    },
    chips: {
      label: "Every name (before)",
      description: "Every name a chip on the one line, cut to fit: seven read as a letter or two each.",
    },
  },
  // Nothing is cut, each subagent is still one click away and its name is under the pointer, as the
  // composer hat's icons are (cmux#49824).
  defaultArm: "faces",
});

export type StartedLineCrowd = keyof typeof startedLineCrowd.arms;

/// From how many subagents the crowd arms apply; fewer read as "A and B started working".
export const STARTED_CROWD_FROM = 3;
