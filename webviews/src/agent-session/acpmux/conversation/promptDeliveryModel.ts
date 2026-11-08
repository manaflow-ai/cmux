import { createContext } from "react";
import type { AcpmuxRow, PromptDelivery } from "../model";
import { type StringKey } from "../i18n";
import { type FailedRun } from "../sendFailure";

/// What the failure cards read from the chat (App.tsx): the runs of failed prompts, and the
/// folder's trust for a trust failure. Without it each failed prompt has its own card.
export type FailedSends = {
  runs: ReadonlyMap<string, FailedRun>;
  /// Why the folder's trust holds prompts now (its question is open, or Not now stands): a trust
  /// failure's Retry would be refused the same way, so it waits and says why.
  trustBlock?: StringKey;
  /// Trust the chat's folder, when the folder is not trusted and this pane may answer for it.
  trustFolder?: () => void;
};
export const FailedSendsContext = createContext<FailedSends | undefined>(undefined);

/// The debug text Copy debug info puts on the clipboard: plain lines, for a bug report.
export function deliveryDebugText(row: Pick<AcpmuxRow, "id" | "text">, delivery: PromptDelivery): string {
  const at = (ms: number | undefined) => (ms === undefined ? "-" : new Date(ms).toISOString());
  const after = (ms: number | undefined) => (ms === undefined ? "-" : `${ms - delivery.sentAt} ms`);
  return [
    `state: ${delivery.state}`,
    `hop: ${delivery.hop ?? "-"}`,
    `code: ${delivery.code ?? "-"}`,
    `reason: ${delivery.reason ?? "-"}`,
    `error: ${delivery.error ?? "-"}`,
    `sent: ${at(delivery.sentAt)}`,
    `accepted: ${at(delivery.acceptedAt)} (${after(delivery.acceptedAt)})`,
    `read: ${at(delivery.readAt)} (${after(delivery.readAt)})`,
    `failed: ${at(delivery.failedAt)} (${after(delivery.failedAt)})`,
    `session: ${delivery.sessionId}`,
    `prompt: ${delivery.promptId}`,
    `row: ${row.id}`,
    `connection: ${delivery.connection ?? "local"}`,
    `characters: ${row.text?.length ?? 0}`,
  ].join("\n");
}
