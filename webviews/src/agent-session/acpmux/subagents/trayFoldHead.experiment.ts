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
    "What the running tray's header says: one plain line (10 subagents working, 2 background commands running), two groups (subagents, background) in words that shrink, a summary in words that shrinks with the width, each kind's mark and count (hover a kind for its names), the newest two by name, the newest one, or only counts.",
  arms: {
    line: {
      label: "One line: what runs, in plain words",
      description:
        "One muted line, as Claude Code's: 10 subagents working, 2 background commands running. A part at 0 is left out; waiting and failed follow; with nothing running, what just finished. No marks, no time, no chevron. A click or Return opens the list of what runs (name, state, time, Stop); a click again or Esc tucks it.",
    },
    groups: {
      label: "Groups: subagents and background, in words that shrink",
      description:
        "Two kinds only: subagents, and everything else backgrounded (commands, waits, monitors). 3 subagents · 2 tasks in background, then 3 subagents · 2 tasks, then each group's mark and number. A lone item reads its name; waiting and failed follow only when they need you. The lines keep each item's own mark.",
    },
    "group-marks": {
      label: "Groups: two marks and their numbers",
      description:
        "The same two groups as marks and numbers at every width (a lone item still reads its name); hover a group for its names.",
    },
    summary: {
      label: "Summary: words that shrink step by step",
      description:
        "One line that says what runs in words (2 subagents running · 1 command running) when there is room, then short words (2 subagents · 1 command), then each kind's mark and number, then +N for the kinds past the edge. Every kind takes the same step; a lone item reads its name. The time and the controls never move.",
    },
    tally: {
      label: "Tally: a mark and a count per kind",
      description:
        "Each kind's mark and its number only (subagents by harness, then each command kind), no words like running; a state only when it needs you (waiting, failed). Hover names them. One layout at every width.",
    },
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
  // Then only a mark and a number per kind (Leo, 2026-11-23: "just listing the # of each type of
  // ongoing thing would be better. symbol for subagents, potentially per harness, then whatever other
  // commands with their own symbols"; ""running" doesn't need text. it can usually just be. you can
  // put symbols for state. and state can fucking only be relevant when you may need to
  // investigate/take action").
  // Then the tally's lone number read as too little, so the line says it in words while there is room
  // and gives them up step by step (Leo, 2026-11-23, on a hat that read the Claude mark and "2": "this 2
  // is too bare. it being alone, it's just bad. ... we need to have it meaningful even when there's
  // only 1 thing ... like just im saying x subagents running y commands running etc with full text
  // when you have space and it gradually shrinks when there is none... and have it not shift too
  // much"). traySummaryFit.ts picks the step.
  // Then two groups, not a kind per command (Leo, 2026-11-24 00:18Z: "the background command type
  // delineation was my doing anyways. the simplest view is just... subagents. other background things.
  // boom. waits, etc, they're just normal tool calls that are backgrounded instead of dozesns of
  // possible different buttons. we can obviously keep the icons the stuff but... we can group them up
  // more"). trayHeadKinds.ts `trayHeadGroups` counts them.
  // Then one plain line, as Claude Code tucks it after the latest message, with no tall bar around a
  // few marks (Leo, 2026-11-25: "did we not finish the composer hat improvements? there's tons of
  // unnecessary space to the point where it's just... not great" / "like claude code just has this and
  // they tuck it at the very bottom of the transcript after the latest message"). trayHeadKinds.ts
  // `trayHeadLine` writes it.
  // Then back to the rounded two-group hat with its full header height (Leo, 2026-11-27: "as for the
  // hat, let's just restore it and add those strict improvements. im not sure if the text is better
  // than just the rounded hat" / on the line's open header: "this is just too thin. idk why the top
  // was reduced in this way"). The line stays an arm for comparison.
  defaultArm: "groups",
});

/// One of the folded header's arms.
export type TrayFoldHeadArm = keyof typeof trayFoldHeadLook.arms;
