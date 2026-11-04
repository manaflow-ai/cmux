// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the pull tab that brings back the tucked running tray sits on the composer's top edge
/// (TrayPullTab.tsx). Leo, 2026-11-04: "at the top of the middle, and then at the top of the hat,
/// there's some sort of little thing that's like, I don't know, like a special kind of chevron", then
/// "I also wonder if we'd want the grabber/dogear/whatever design thing on maybe the left… or the
/// right…". Compare the arms in the gallery's `agent-pane.subagent-tray-tuck`.
export const trayGrabberLook = defineExperiment({
  id: "subagent-tray-grabber",
  title: "Running tray: where its grabber sits",
  description: "Where the pull tab that brings back the tucked-away running tray sits on the composer's top edge.",
  arms: {
    center: {
      label: "Centre",
      description: "In the middle of the top edge, where Leo first put it.",
    },
    left: {
      label: "Left",
      description: "At the left end of the composer's top edge.",
    },
    right: {
      label: "Right",
      description: "At the right end of the composer's top edge.",
    },
  },
  defaultArm: "center",
});
