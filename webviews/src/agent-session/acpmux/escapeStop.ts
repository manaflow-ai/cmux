// Esc on an empty composer stops a running turn. By default it takes two presses, as in Claude
// Code (Leo 2026-10-19: "when we want to cancel chats with escape, I think we want to do a double
// tap"): the first arms the stop and the prompt's placeholder says to press Esc again; a second
// inside the window stops the turn. Debug Settings' "Esc stops a turn on a double press" (Swift
// AgentPaneTunables.escapeStopDoublePress, the `composer` event's `escapeDoublePress`) turns it off,
// and one press stops the turn again.

/// How long after the first Esc a second one still stops the turn.
export const ESCAPE_STOP_WINDOW_MS = 800;

export type EscapeStopPress = {
  /// Whether this press stops the turn.
  stop: boolean;
  /// When the stop was armed, if this press left it armed (the hint shows until the window ends).
  armedAt?: number;
};

/// One Esc on an empty composer while a turn runs. `armedAt` is the previous press that armed the
/// stop, if any; `double` is the Debug Settings choice.
export function escapeStopPress(armedAt: number | undefined, now: number, double: boolean): EscapeStopPress {
  if (!double) return { stop: true };
  if (armedAt !== undefined && now - armedAt >= 0 && now - armedAt <= ESCAPE_STOP_WINDOW_MS) return { stop: true };
  return { stop: false, armedAt: now };
}
