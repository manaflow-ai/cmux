// The chat's one status line after a failed turn (Leo, 2026-11-23, on "Retrying (1/4) after a capacity
// error" over "Paused after an error: API Error: 503 no non-exhausted claude accounts available; next
// account frees up in 10m ...": "this looks ass idk"). The daemon's retry wait (`autoResume.retry`,
// whose attempt, reason and `nextAt` acpmux schedules) and the queue's pause (`queuePaused`, with the
// failed turn's error) are one state to the person: the turn failed and something waits. So one line
// says it in plain words ("Waiting for capacity", "Retrying in 9:42 · 1 of 4"), the raw error behind
// Details, never two lines and never the gateway's text as the sentence.
//
// The daemon decides the state (the retry's reason, its schedule); this only words it.
import type { StringKey, Translate } from "./i18n";
import type { RetryState } from "./subagents/retryState";

/// The line's words: `title` what happened, `retrying` whether a retry is scheduled (its countdown and
/// try count then follow the title), `error` the raw error for Details.
export type QueueStatus = {
  title: string;
  retry?: RetryState;
  error?: string;
};

const TITLE: Record<string, StringKey> = {
  capacity: "queueStatus.capacity",
  transport: "queueStatus.transport",
  agent_exited: "queueStatus.agentExited",
};

/// The status a failed turn leaves: with a scheduled retry, its reason in words; without one, a pause
/// the person resumes. Undefined when neither holds.
export function queueStatus(
  t: Translate,
  { retry, paused, error }: { retry?: RetryState; paused: boolean; error?: string },
): QueueStatus | undefined {
  const raw = error?.trim() || undefined;
  if (retry) {
    return {
      title: t((retry.reason && TITLE[retry.reason]) || "queueStatus.retrying"),
      retry,
      ...(raw && { error: raw }),
    };
  }
  if (!paused) return undefined;
  return { title: t("queueStatus.paused"), ...(raw && { error: raw }) };
}

/// A wait as a clock reads it: "9:42", "1:02:03"; "0:00" once it is due.
export function countdownText(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}
