// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What sits between the running tray header's counts (trayHeadKinds.ts). Leo, 2026-11-03: "so you
/// can fit that all in counts of stuff and maybe times all in one line like a \ b \ c or a | b| c or
/// a / b / c and whatnot". Compare them in the gallery's `agent-pane.subagent-tray-command-kinds`.
export const trayKindLineLook = defineExperiment({
  id: "subagent-tray-kind-line",
  title: "Running tray count separator",
  description: "What separates the running tray header's counts: a middot, a slash, a pipe or a backslash.",
  arms: {
    dot: { label: "Middot", description: "2 subagents running · 1 test run · 2 waits" },
    slash: { label: "Slash", description: "2 subagents running / 1 test run / 2 waits" },
    pipe: { label: "Pipe", description: "2 subagents running | 1 test run | 2 waits" },
    backslash: { label: "Backslash", description: "2 subagents running \\ 1 test run \\ 2 waits" },
  },
  // The middot is the pane's one meta separator (the turn line, Session Info), so the header reads as
  // the rest of the pane does.
  defaultArm: "dot",
});

export type TrayKindLine = keyof typeof trayKindLineLook.arms;

/// Each arm's separator, spaced.
export const KIND_LINE_SEPARATOR: Record<TrayKindLine, string> = {
  dot: " · ",
  slash: " / ",
  pipe: " | ",
  backslash: " \\ ",
};
