import type { AcpmuxRow } from "../model";

/// How thoughts draw, for comparing designs: the Debug choice `agentPane.debug.thoughtStyle`, which
/// the app sets on `<html>` as `data-thought-style` before the page loads (the dev server takes
/// `?data-thought-style=brain`). Unset is today's look.
/// - `plain`: a muted "Thought" beside its text; the notes an agent writes between steps draw as
///   replies.
/// - `brain`: each thought, and each such note in an open "Worked for", is one quiet line, a brain
///   and the thought's first line, that opens to "Thoughts" over the whole text (ThoughtFold.tsx).
export type ThoughtStyle = "plain" | "brain";

/// What the rows read from the page; tests swap it.
export const thoughtStyle = {
  current: (): ThoughtStyle =>
    typeof document !== "undefined" && document.documentElement.dataset.thoughtStyle === "brain" ? "brain" : "plain",
};

/// A note the agent wrote between steps of a finished turn (a reply copied under an open "Worked
/// for", turns.ts), when it draws as a thought line.
export const isThoughtNote = (row: AcpmuxRow) =>
  row.kind === "assistant" && row.settled === true && thoughtStyle.current() === "brain";
