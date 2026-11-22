// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Whether a transcript time's hover names its date. A clock time written with no date ("deploy
/// finished 03:22") resolves to the occurrence nearest its message, which may be the day before
/// or after; the date says which one was meant (ask-15a0d92575, Leo, 2026-11-07: "if you hover
/// over that, it'll just say, like, okay, it's in X amount of minutes"). Compare the arms in
/// `agent-pane.time-hover-detect`.
export const timeHoverDate = defineExperiment({
  id: "time-hover-date",
  title: "Transcript time hover, with or without the date",
  description: "Whether a hovered time names its local date before the time and how far away it is.",
  arms: {
    date: {
      label: "Always the date",
      description: '"Nov 7, 3:14 PM PST, in 14 min": the full local date and time, the year only when not this year.',
    },
    "other-day": {
      label: "Date when not today",
      description: '"3:14 PM PST, in 14 min" today, "Nov 8, 3:14 AM PST, in 12 hr" on another day.',
    },
    time: {
      label: "Time only",
      description: '"3:14 PM PST, in 14 min": the time and its distance, never the date.',
    },
  },
  defaultArm: "date",
});
