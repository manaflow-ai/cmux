// When a send goes slow, or a Stop does not end its turn, the pane checks whether it is missing the
// chat's events (user, 2026-10-30, session claude-7: prompts stayed "Still sending" while acpmux had
// run them, and the pane missed their replies; #32859: after acpmux was replaced under the app,
// sends never showed and Stop stayed on "Stopping…" while acpmux had ended the turn). A release
// build shows no pane state, so the pane says so in the log: console.error reaches the error journal
// (`cmux errors`) and the unified log in every build. Then it connects again (direct.ts
// `recoverStall`), so the chat catches up.

/// How old acpmux's first event after the pane's last one must be to count as missed, not in flight.
export const STALL_GRACE_MS = 5_000;

/// Why the pane checks: a send went slow, a Stop did not end its turn, a working chat went quiet
/// (`quiet`, direct.ts `quietCheck`), or the page was shown or focused again (`wake`).
export type StallCause = "send" | "stop" | "quiet" | "wake";
/// How long the check waits for acpmux's answer.
export const STALL_CHECK_MS = 10_000;
/// How long a Stop waits for its turn to end before the pane checks: past acpmux's own escalation
/// (cancel again at 10 s, end the turn at 15 s), so a turn still ending is not a stall.
///
/// `quietMs`: how long a chat that is working may send the pane nothing before the pane asks acpmux
/// whether it missed something (Leo, 2026-11-08: replies sat in acpmux for 30 minutes while the pane
/// showed none). A model may think for minutes without a word, so a quiet chat whose acpmux holds
/// nothing newer keeps its connection, and the next check waits twice as long, up to 8 times
/// `quietMs`; after `quietChecks` checks with nothing found the pane checks again only on the next
/// record, a list change, or when the page is shown or focused. Mutable for tests.
export const stallTiming = { stopMs: 20_000, quietMs: 20_000, quietChecks: 6, graceMs: STALL_GRACE_MS };

/// The wait before quiet check number `checks` (0 for the first): `quietMs`, doubling, at most 8 times.
export function quietDelay(checks: number): number {
  return stallTiming.quietMs * 2 ** Math.min(Math.max(0, checks), 3);
}

const CAUSE_TEXT: Record<StallCause, string> = {
  send: "a send is still pending",
  stop: "a Stop has not ended its turn",
  quiet: "the working chat sent nothing for a while",
  wake: "the page was shown again",
};

/// The log line for a pane at `paneSeq` whose chat's next event in acpmux is `newer`, or undefined
/// when nothing is missing (no newer event, or one written within the grace: still on its way).
export function stallLine(
  sessionId: string,
  paneSeq: number,
  newer: { seq: number; at?: number } | undefined,
  now: number,
  connection: string,
  cause: StallCause = "send",
): string | undefined {
  if (!newer || !(newer.seq > paneSeq)) return undefined;
  const age = typeof newer.at === "number" ? now - newer.at : Number.POSITIVE_INFINITY;
  if (age < stallTiming.graceMs) return undefined;
  const seconds = Number.isFinite(age) ? `${Math.round(age / 1000)} s ago` : "at an unknown time";
  // l10n-allow: a log line for the error journal and unified log; never shown in the pane.
  return `agent pane stall: session ${sessionId}: pane at seq ${paneSeq}, acpmux at seq ${newer.seq} (written ${seconds}); ${CAUSE_TEXT[cause]}; connection ${connection}`;
}
