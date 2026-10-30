// The one way a failed turn goes on, shared by its error card (TurnRows.tsx TurnFailure, its first
// and filled button, Return on the focused card) and the native "Continue After Error" command
// (palette, CLI, MCP; App.tsx's `continueAfterError` menu command). Lawrence 2026-10-29: "should
// have a try again/continue type button here".
import type { AcpmuxRow } from "../model";
import { failureKind, failureRecovery, type FailureRoute } from "../failureCopy";
import type { TurnActions } from "./turnActions";
import { isFailed } from "./turns";

/// What the lead action says and does: `continue` resumes the turn with what it already did (the
/// turn had done work, or has no prompt of its own), `retry` sends its prompt again (nothing ran).
export type ErrorRecovery = { label: "continue" | "retry"; run: () => Promise<void> };

/// The failed turn's way on, or undefined: a sign-in or trust failure would fail the same way again
/// (failureCopy.ts `failureRecovery`), and a chat that cannot send now (View Only, disconnected)
/// has neither action.
export function errorRecovery(
  row: AcpmuxRow,
  route: FailureRoute | undefined,
  actions: Pick<TurnActions, "resume" | "retry">,
): ErrorRecovery | undefined {
  if (!isFailed(row) || failureRecovery(failureKind(row.error, route, row.errorCode)) === undefined) return undefined;
  const { resume, retry } = actions;
  const resendable = retry !== undefined && row.prompt !== undefined && row.retryRowId !== undefined;
  if (row.continuable && resume) return { label: "continue", run: resume };
  // A turn that did work on a chat that cannot resume still goes on by sending its prompt again.
  if (resendable) return { label: "retry", run: async () => retry(row.retryRowId!, row.prompt!) };
  return undefined;
}

/// The transcript's last turn footer when that turn failed, for the native command: an older failed
/// turn is history, and a later prompt already went on from it.
export function lastFailedTurn(rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "user") return undefined;
    if (row.kind === "turnSummary") return isFailed(row) ? row : undefined;
  }
  return undefined;
}
