// A failed turn's Retry (the card's and the footer's): acpmux's own turn retry (`_acpmux/retry`,
// `turn-retry-v1`) where it serves one, else the prompt sent again. acpmux's continues a turn the
// model had started instead of rerunning it, takes over a retry it already has waiting instead of
// racing it, and lets the prompts the failed turn held go on once its turn completes
// (auto_resume/retry_turn.rs). The Retry under a prompt that did not fail still sends it again.
import { RETRY_METHOD, TURN_RETRY, refusalNote, type RetryNote } from "../subagents/retryState";

export type TurnRetryDeps = {
  /// The chat the pane shows, whose last turn failed.
  sessionId: string | undefined;
  /// The capabilities acpmux named; undefined from one that names none (Retry tries the method).
  capabilities: ReadonlySet<string> | undefined;
  request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  /// The prompt sent again through the composer's send, as a prompt's Retry does.
  resend: () => Promise<unknown>;
};

/// Settles with the note a refusal leaves on the card, or undefined once the retry went. Only a
/// daemon without the method, or one whose last turn did not fail (the pane's failed row is older),
/// falls back to sending the prompt again; a busy, stopped or unanswered retry never sends a second
/// prompt beside the one acpmux may be running.
export async function retryFailedTurn(deps: TurnRetryDeps): Promise<RetryNote | undefined> {
  const served = deps.capabilities === undefined || deps.capabilities.has(TURN_RETRY);
  if (deps.sessionId && served) {
    try {
      await deps.request(RETRY_METHOD, { sessionId: deps.sessionId });
      return undefined;
    } catch (error) {
      const note = refusalNote(error);
      if (note !== "unknown-method" && note !== "retry.nothingFailed" && note !== "ask") return note;
    }
  }
  try {
    await deps.resend();
    return undefined;
  } catch {
    return "retry.failed";
  }
}
