import { isTrustRefusal } from "./direct";

/// The failed prompt row a refused send left (direct.ts `send`), when it left one.
export function failedRowOf(error: unknown): string | undefined {
  const row = (error as { failedRow?: unknown } | null)?.failedRow;
  return typeof row === "string" ? row : undefined;
}

/// Hands a trust refusal, with the step Trust re-runs, to the shown chat's folder question; true
/// when that question took it (App.tsx checks the refusal still belongs to the chat it was sent in).
export type TrustRouter = (error: unknown, again: () => void, declined?: () => void) => boolean;

/// Retry on a failed prompt row, and the re-send Trust makes of such a row (cx-nn3e). A row's
/// Retry that acpmux refuses with `trust.pending` shows the folder's Trust question like a send
/// does, and Trust sends the row's whole run again with the gesture the refused retry kept
/// (heldPrompt.ts), so one Trust click is enough: no second manual Retry.
export function failedRowTrustRetry<Copy = unknown>(deps: {
  /// direct.ts `retryPrompts`: the run goes again as one prompt, over `anchor`'s row.
  retry: (rowIds: readonly string[], ticket?: string, anchor?: string) => Promise<string | undefined>;
  /// The rows of the run `row` belongs to now (its failure card), else the row alone.
  runOf: (row: string) => readonly string[];
  /// Keeps the refused gesture for `row`'s prompt, before the Trust click spends its own.
  hold: (row: string) => void;
  /// The gesture `hold` kept, once.
  takeTicket: () => string | undefined;
  /// What the run's rows hold at the refusal (direct.ts `failedPromptCopies`), and putting back the
  /// part a chat switch cleared before Trust (`restoreFailedPrompts`): A refused, B shown, back to A,
  /// Trust still sends A's prompt.
  copy?: (rowIds: readonly string[]) => Copy;
  restore?: (copy: Copy) => void;
}) {
  /// A refusal that left a failed row: Trust re-sends that row's run. False when the refusal
  /// left no row or the question did not take it.
  const replayAfterTrust = (error: unknown, route: TrustRouter): boolean => {
    const row = failedRowOf(error);
    if (row === undefined) return false;
    const refusedRun = deps.runOf(row);
    const kept = deps.copy?.(refusedRun);
    const owns = route(error, () => {
      if (kept !== undefined) deps.restore?.(kept);
      // The run as its card shows it now (a send's row may not have been drawn at its refusal);
      // after a chat switch cleared the card, the run as it was at the refusal.
      const shown = deps.runOf(row);
      const run = shown.length > 1 || refusedRun.length <= 1 ? shown : refusedRun;
      // A replay refused again routes again itself; nothing waits on it.
      void retry(run, route, deps.takeTicket(), row).catch(() => undefined);
    });
    if (owns) deps.hold(row);
    return owns;
  };
  /// The failure card's Retry: a trust refusal of it shows the question and keeps the replay;
  /// the promise still rejects as before.
  const retry = (
    rowIds: readonly string[],
    route: TrustRouter,
    ticket?: string,
    anchor?: string,
  ): Promise<string | undefined> =>
    deps.retry(rowIds, ticket, anchor).catch((error: unknown) => {
      if (isTrustRefusal(error)) replayAfterTrust(error, route);
      throw error;
    });
  return { retry, replayAfterTrust };
}
