// Why the running turn's model has not answered (acpmux `turn_silent` `reason`, hub/silent_turn.rs),
// so the line never says a bare "No response from the model yet" (Leo, 2026-11-03: "and why am i
// getting this"). acpmux decides the reason from the harness's API retries and its stderr; the pane
// only names it, shows the harness's own line on hover, and offers Retry, which ends the silent
// turn and sends it again (`_acpmux/retry` `silent`).
import { createContext } from "react";
import type { StringKey } from "../i18n";
import { RETRY_METHOD, refusalNote, type RetryNote } from "../subagents/retryState";

export type SilentReasonKind = "no_answer" | "retrying" | "capacity" | "auth" | "unavailable";

export type SilentReason = {
  kind: SilentReasonKind;
  /// The harness's retry of its model API: which attempt of how many.
  attempt?: number;
  of?: number;
  /// The harness's own line (credentials masked by acpmux).
  detail?: string;
};

const KINDS: ReadonlySet<string> = new Set<SilentReasonKind>([
  "no_answer",
  "retrying",
  "capacity",
  "auth",
  "unavailable",
]);

const count = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;

/// acpmux's `reason`; an older acpmux sends none, and an unknown kind reads as no reason known.
export function readSilentReason(raw: unknown): SilentReason | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const value = raw as Record<string, unknown>;
  if (typeof value.kind !== "string" || !KINDS.has(value.kind)) return undefined;
  const attempt = count(value.attempt);
  const of = count(value.of);
  return {
    kind: value.kind as SilentReasonKind,
    ...(attempt !== undefined && { attempt }),
    ...(attempt !== undefined && of !== undefined && { of: Math.max(attempt, of) }),
    ...(typeof value.detail === "string" && value.detail && { detail: value.detail }),
  };
}

/// The line's words for each reason.
export const SILENT_LABEL: Record<SilentReasonKind, StringKey> = {
  no_answer: "turn.waiting.model",
  retrying: "turn.silent.retrying",
  capacity: "turn.silent.capacity",
  auth: "turn.silent.auth",
  unavailable: "turn.silent.unavailable",
};

/// The silent turn's reason and its Retry, for the running turn's line (WaitingLabel.tsx).
export type SilentTurn = {
  reason?: SilentReason;
  /// Ends the silent turn and sends it again; settles with the note a refusal leaves.
  retry?: () => Promise<RetryNote | undefined>;
};

export const SilentTurnContext = createContext<SilentTurn | undefined>(undefined);

export type SilentRetryDeps = {
  /// The chat the line was drawn for.
  sessionId: string;
  /// Whether the pane still shows that chat (restart.ts `restartReaches`): nothing goes to the next.
  reaches: () => boolean;
  request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
};

/// The silent line's Retry: acpmux ends the silent turn as failed and sends it again
/// (`_acpmux/retry` `silent`). Settles with the note a refusal leaves, or undefined once it went.
export async function retrySilentTurn(deps: SilentRetryDeps): Promise<RetryNote | undefined> {
  if (!deps.reaches()) return undefined;
  try {
    await deps.request(RETRY_METHOD, { sessionId: deps.sessionId, silent: true });
    return undefined;
  } catch (error) {
    const note = refusalNote(error);
    return note === "ask" || note === "unknown-method" ? "retry.failed" : note;
  }
}
