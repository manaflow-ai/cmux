// One state, drawn only when someone may have to look (Leo, 2026-11-23: ""running" doesn't need text.
// it can usually just be. you can put symbols for state. and state can fucking only be relevant when
// you may need to investigate/take action."). Every agent-pane row, card and header that names a
// state goes through here, so no surface words "Running" again on its own:
// - running: a spinner, no word (`mark`), or nothing where the row already spins;
// - done: nothing in sight;
// - failed, waiting, stopped, paused, queued: the word, since they ask for a look or an act.
// Hover and VoiceOver still get the word for every state.
import { Spinner } from "../conversation/icons";
import "./LiveCount.css";

/// The states that need no word: the row's own glyph (a spinner, a check) says them.
const QUIET_STATES: ReadonlySet<string> = new Set(["running", "active", "completed", "done", "complete"]);

/// Whether a state is worded on screen.
const stateWorded = (state: string) => !QUIET_STATES.has(state);

export function StateMark({
  state,
  label,
  mark = false,
  className,
}: {
  state: string;
  /// The state's word, for hover and screen readers always, on screen only when it asks for a look.
  label: string;
  /// Draw the spinner for a running state (a row with no spinner of its own).
  mark?: boolean;
  className?: string;
}) {
  if (stateWorded(state))
    return (
      <span className={className} data-state={state}>
        {label}
      </span>
    );
  if (mark && (state === "running" || state === "active"))
    return (
      <span
        className={`acpmux-live-count ${className ?? ""}`}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a spinner with a spoken name, not an image file
        role="img"
        aria-label={label}
        title={label}
        data-state={state}
      >
        <Spinner size={12} loading />
      </span>
    );
  return (
    <span className={`acpmux-state-mark--quiet ${className ?? ""}`} data-state={state}>
      {label}
    </span>
  );
}
