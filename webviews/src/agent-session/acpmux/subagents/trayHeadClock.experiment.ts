// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The time a running tray's header shows after its counts when it holds more than one item
/// (SubagentTray.tsx). It was the time since the first item still in the tray started
/// (trayHeadOrder.ts `runSince`), finished and stopped ones too, so "53 subagents running · 5 waits ·
/// 5 commands · 8 done · 5 stopped 1h 23m 25s" timed nothing anyone could name (Leo, 2026-11-22: "i
/// have no idea what the point of putting time when there's shit like this supposed to be for. what
/// the fuck are you timing man"). Each line keeps its own time, and a lone item's header keeps its
/// own. Compare them in the gallery's `agent-pane.subagent-tray-command-kinds`.
export const trayHeadClockLook = defineExperiment({
  id: "subagent-tray-head-clock",
  title: "Running tray header time",
  description:
    "The several-item header's time: none (each line has its own), the longest still-running item's, or the time since the first item ever started (before).",
  arms: {
    none: {
      label: "No time",
      description: "The counts alone; each line, and a lone item's header, still says its own time.",
    },
    running: {
      label: "Longest running",
      description: "The time of the longest item still running; nothing once only finished items are left.",
    },
    run: {
      label: "Since the first (before)",
      description: "Since the first item still in the tray started, finished and stopped ones too.",
    },
  },
  // What a bare time means is never in doubt when there is none: each line names its own.
  defaultArm: "none",
});

export type TrayHeadClock = keyof typeof trayHeadClockLook.arms;
