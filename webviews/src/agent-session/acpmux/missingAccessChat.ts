// What the missing-access card (MissingAccessNotice.tsx) reads from a chat: its last turn's failure
// and the prompt that turn sent, and the cmux model router's route among the chat's routes.
import type { ChatAccountList } from "./chatAccounts";
import type { AcpmuxRow } from "./model";

/// acpmux's harness that runs Claude Code on the cmux model router (cmux-tui acpmux
/// config/discover.rs `CMUX_ROUTER_PROFILE`): a chat with no session yet that picks cmux credits
/// starts on it.
export const CMUX_ROUTER_HARNESS = "cmux";

/// The model a chat moved onto the router runs: the router's first model, the one acpmux's `cmux`
/// harness starts on (config/discover.rs `CMUX_ROUTER_MODELS`). The router serves only its own
/// open models, so a Claude model id would be refused there.
export const CMUX_ROUTER_DEFAULT_MODEL = "qwen/qwen3.7-flash";

/// The chat's last turn, when it failed: its error and typed code, and the prompt it sent (the row
/// Retry sends again, with its attachments).
export type AccessFailure = { error: string; code?: string; rowId?: string; prompt?: string };

export function accessFailure(rows: readonly AcpmuxRow[]): AccessFailure | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind !== "turnSummary") continue;
    const failed = row.failed === true || row.status === "failed" || row.status === "error";
    if (!failed || !row.error) return undefined;
    const sent = row.retryRowId ? rows.find((candidate) => candidate.id === row.retryRowId) : undefined;
    const prompt = row.prompt ?? sent?.resend ?? sent?.text;
    return {
      error: row.error,
      ...(row.errorCode ? { code: row.errorCode } : {}),
      ...(row.retryRowId ? { rowId: row.retryRowId } : {}),
      ...(prompt ? { prompt } : {}),
    };
  }
  return undefined;
}

/// The cmux model router's route among the chat's routes (acpmux lists only the routes that serve
/// its harness): kind `cmux-router`.
export function cmuxRouterRoute(list: ChatAccountList): string | undefined {
  return list.accounts.find((account) => account.kind === "cmux-router")?.id;
}
