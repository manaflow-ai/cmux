import { createContext, useEffect, useState } from "react";
import { PROMPT_PENDING_AFTER_MS, type AcpmuxRow, type PromptDelivery } from "../model";
import { type StringKey } from "../i18n";
import { sendRetriesItself, type FailedRun } from "../sendFailure";

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

const PENDING_AFTER_MS = PROMPT_PENDING_AFTER_MS;

/// A prompt that did not get there and goes again by itself: shown as on its way, never as failed.
export const resendsItself = (delivery: PromptDelivery | undefined): boolean =>
  delivery?.state === "failed" && sendRetriesItself(delivery);

/// Whether `delivery` draws its pending row now: on its way past its first second, held for the host
/// or not, so a send that lands within a second shows nothing (Leo, 2026-11-24: "this "sending" is
/// bad"), or going again by itself. Re-renders once when the second passes. `queued`: a steer acpmux
/// holds for the running turn draws that row on its own terms (PendingSteer.tsx).
export function usePendingShown(delivery: PromptDelivery | undefined, queued = false): boolean {
  const sending = delivery?.state === "sending";
  const sentAt = delivery?.sentAt ?? 0;
  const [late, setLate] = useState(() => Date.now() - sentAt >= PENDING_AFTER_MS);
  useEffect(() => {
    if (!sending || late) return;
    const timer = setTimeout(() => setLate(true), Math.max(0, PENDING_AFTER_MS - (Date.now() - sentAt)));
    return () => clearTimeout(timer);
  }, [sending, late, sentAt]);
  // Once it went again by itself, its next try keeps the row from its first frame: no footer
  // flashing between tries.
  const again = resendsItself(delivery);
  useEffect(() => {
    if (again && !late) setLate(true);
  }, [again, late]);
  if (again) return true;
  return sending && late && !queued;
}

/// What a prompt still on its way says: the one sentence its footer shows.
export function pendingLabel(delivery: PromptDelivery): StringKey {
  return delivery.waitingForHost ? "prompt.delivery.whenReady" : "prompt.delivery.sending";
}
