// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a running turn draws above its one live status line. The default is `open`: every finished
/// call stays in sight on its own line and nothing folds until the turn ends, when its work folds
/// once under "Worked for" (the ended-turn path, `shapeTurn`). A steer or a reply mid-turn then
/// changes nothing above it (Leo, 2026-11-21 05:47Z, on runs folding around his steers: "why are
/// you folding these after my message while you're in teh middle of a turn? i thought we dont fold
/// while you're still going. but my steers affect these. they shouldn't be like this. it's fucking
/// weird. the behaiour is odd."). `runs` draws a running turn as the Codex app does: each finished
/// run folds into its summary line as soon as a reply or a steer ends it, which a click opens, and
/// the turn's thinking shows as it goes (Lucas, 2026-11-12: under `line` "no thinking at all, until
/// after the turn finished"). `line` draws it as chatgpt.com does: one line that says what the agent
/// does now and replaces itself at each step, with no finished run stacked over it (the user,
/// 2026-11-10: "it says 'worked for 36s' but if i hide it, it still shows a bunch of tool calls ...
/// we need to match and be the same"). Replies to the person always stay in sight (Leo, 2026-11-06),
/// and so does a file change waiting for the person's permission (Lawrence, 2026-11-10,
/// 8a37e5fcf650). `open` is how a running turn drew before `runs` (Leo, 2026-11-08, cmux#38339).
/// Compare in `agent-pane.live-turn-work`.
export const liveTurnWork = defineExperiment({
  id: "live-turn-work",
  title: "Work in a running turn",
  description:
    "What a running turn draws above its live status line: every call on its own line, every finished run folded, or nothing but the replies.",
  arms: {
    open: {
      label: "Every call in sight until the turn ends",
      description:
        "Each finished call keeps its own line while the turn runs, so a steer regroups nothing; the work folds once, when the turn ends.",
    },
    line: {
      label: "One live line",
      description: "The replies stay in sight; the work is the one live line, which replaces itself.",
    },
    runs: {
      label: "Finished runs in sight",
      description:
        "Each finished run stays in sight above the live line as its folded summary line, as the Codex app draws it.",
    },
  },
  defaultArm: "open",
});
