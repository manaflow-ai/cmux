import { type AcpmuxRow } from "../model";
import { type HeldAnswer } from "../conversation/QueuedMessageCard";
import { isTrustRefusal } from "../direct";
import { failedRowOf } from "../failedRowTrustRetry";
import { postNative } from "../native";
import { type ComposerAttachment } from "../attachments";
import { type SendGesture } from "../heldPrompt";
import { callNative } from "../callNative";
import { untilLinked } from "../offlineSends";
import { keptUnsent } from "../lostPrompt";

/// A start the host refused with a typed code: a chat on another machine (`agent_session.*`, the
/// session daemon's agent-session-start). A trust refusal has its own question.
export function isStartRefusal(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && code.startsWith("agent_session.") && !isTrustRefusal(error);
}

/// The machine a refused handshake names (`details.machineName`), for the composer's chip.
export function refusedMachine(error: unknown): string | undefined {
  const details = (error as { details?: unknown } | null)?.details;
  const name = details && typeof details === "object" ? (details as { machineName?: unknown }).machineName : undefined;
  return typeof name === "string" && name ? name : undefined;
}

/// The failed prompt rows a failure card's action names: its run's (`rowIds`), else its own.
export function failedRowIds(rowId: unknown, rowIds: unknown): string[] {
  if (Array.isArray(rowIds) && rowIds.length) return rowIds.map(String);
  return [String(rowId)];
}

/// Whether a failed send's prompt stays in the chat, never back in the composer: its failed row,
/// or the transcript, which drew it once acpmux took it (direct.ts `send`).
export function keptInChat(error: unknown): boolean {
  return failedRowOf(error) !== undefined || (error as { taken?: unknown } | null)?.taken === true || keptUnsent(error);
}

/// Stops the shown chat's turn; refused while the pane cannot reach acpmux (stopThroughReconnect.ts).
export const cancelTurn = () => callNative<unknown>("chat.cancel");

/// Withdraws a queued prompt before its turn starts; false when it already started.
export const removeQueued = (promptId: string) =>
  callNative<{ removed?: boolean } | null>("chat.queue.remove", { promptId }).then(
    (result) => result?.removed === true,
  );

/// Sends a prompt that waited for a new chat; settles once acpmux took it (its turn's later failure
/// is the transcript's), and rejects when it was refused before. One acpmux refused for the folder's
/// trust that joined the pane's hold (`holdRefused`) counts as taken: it waits in the queue now.
/// `gesture`: the Enter or click the composer bound to a send it held for its files.
/// `chat`: the chat it must go to; a pane showing another one by then refuses it (`startCancelled`).
/// While the pane reconnects it waits for the link, never refused for it (offlineSends.ts).
const sendWhenTaken =
  (steer: boolean, chat?: string) => (text: string, attachments: ComposerAttachment[], gesture?: SendGesture) =>
    untilLinked().then(
      () =>
        new Promise<void>((resolve, reject) => {
          callNative("chat.send", {
            text,
            attachments,
            accepted: () => resolve(),
            steer,
            ...(chat ? { expectedSessionId: chat } : {}),
            ...(gesture ? { gesture } : {}),
          }).then(
            () => resolve(),
            (error: unknown) => (heldRefusal(error) ? resolve() : reject(error)),
          );
        }),
    );

/// Keeps the current gesture for prompt `promptId`, which the folder's trust holds (trustHeld.ts).
export const reserveHeldPrompt = (promptId: string) =>
  postNative<{ ticket?: string }>("transport.gesture", {
    intent: { method: "session/prompt", params: { promptId } },
  }).then((reply) => reply?.ticket);

/// acpmux's trust refusals of prompts that joined the pane's hold (`holdRefused`): the composer that
/// sent one lets it go, as if acpmux took it, since it waits in the queue now.
export const heldRefusals = new WeakSet<object>();
export const heldRefusal = (error: unknown) => typeof error === "object" && error !== null && heldRefusals.has(error);
/// The Trust re-run of a refusal whose prompt the pane's hold owns: none, since the hold sends it
/// after Trust. It replaces the step a refused start kept (`client.create`'s), which would start a
/// second chat beside the hold's own send.
export const heldGoesAfterTrust = () => undefined;
/// Where a prompt was sent: the chat and its folder (a new chat's picked one), as trustHeld.ts keeps them.
export type SentFrom = { chat: string | undefined; cwd: string | undefined };
/// A send of a prompt the folder's trust held: its id and its send's ticket (in-page only).
export type HeldSend = { promptId: string; ticket?: string };
/// The in-page `gesture` of `chat.send` (Composer `onBindSendGesture`), or undefined.
export function sendGestureParam(value: unknown): SendGesture | undefined {
  const gesture = value as { promptId?: unknown; ticket?: unknown } | null | undefined;
  if (typeof gesture?.promptId !== "string" || !(gesture.ticket instanceof Promise)) return undefined;
  return { promptId: gesture.promptId, ticket: gesture.ticket as Promise<string | undefined> };
}
export function heldPromptParams(value: unknown): HeldSend | undefined {
  const held = value as { promptId?: unknown; ticket?: unknown } | null | undefined;
  if (typeof held?.promptId !== "string") return undefined;
  return { promptId: held.promptId, ...(typeof held.ticket === "string" ? { ticket: held.ticket } : {}) };
}

/// A guest's queued prompt (held for the owner, or approved and waiting): a person's, drawn on its own.
export const isPersonQueuedRow = (row: AcpmuxRow) => Boolean(row.queuedMessage?.person || row.queuedMessage?.held);

/// The owner's Approve or Decline of a guest's held prompt (conversation/QueuedMessageCard.tsx).
export const answerHeld = (promptId: string, approve: boolean, revision?: number): Promise<HeldAnswer> =>
  callNative(approve ? "chat.queue.approve" : "chat.queue.decline", {
    promptId,
    ...(approve && revision !== undefined ? { revision } : {}),
  }).then(
    () => "ok",
    (error: { reason?: unknown } | null) =>
      error?.reason === "queue.stale" ? "stale" : error?.reason === "queue.not_found" ? "gone" : "failed",
  );

export { sendWhenTaken };
