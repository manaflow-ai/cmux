// When a send goes slow, the pane checks whether it is missing the chat's events (user, 2026-10-30,
// session claude-7: prompts stayed "Still sending" while acpmux had run them, and the pane missed
// their replies). A release build shows no pane state, so the pane says so in the log: console.error
// reaches the error journal (`cmux errors`) and the unified log in every build.

/// How old acpmux's first event after the pane's last one must be to count as missed, not in flight.
export const STALL_GRACE_MS = 5_000;
/// How long the check waits for acpmux's answer.
export const STALL_CHECK_MS = 10_000;

/// The log line for a pane at `paneSeq` whose chat's next event in acpmux is `newer`, or undefined
/// when nothing is missing (no newer event, or one written within the grace: still on its way).
export function stallLine(
  sessionId: string,
  paneSeq: number,
  newer: { seq: number; at?: number } | undefined,
  now: number,
  connection: string,
): string | undefined {
  if (!newer || !(newer.seq > paneSeq)) return undefined;
  const age = typeof newer.at === "number" ? now - newer.at : Number.POSITIVE_INFINITY;
  if (age < STALL_GRACE_MS) return undefined;
  const seconds = Number.isFinite(age) ? `${Math.round(age / 1000)} s ago` : "at an unknown time";
  // l10n-allow: a log line for the error journal and unified log; never shown in the pane.
  return `agent pane stall: session ${sessionId}: pane at seq ${paneSeq}, acpmux at seq ${newer.seq} (written ${seconds}); a send is still pending; connection ${connection}`;
}
