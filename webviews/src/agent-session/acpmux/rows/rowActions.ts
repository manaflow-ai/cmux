// Host actions the transcript rows and the pane both start (each through callNative).
import { callNative } from "../callNative";
import type { IncomingMessage } from "../conversation/incomingMessage";
import type { QueueEdit } from "../model";

/// Resumes the chat's paused messages with another agent (conversation/AgentPairNote.tsx).
export const resumeAgentPair = (peer: string) => callNative("chat.agentPair.resume", { peer });
/// Changes a waiting prompt (`_acpmux/queue_edit`); false when it already started.
export const editQueued = (promptId: string, edit: QueueEdit) =>
  callNative<{ ok?: boolean } | null>("chat.queue.edit", { promptId, ...edit }).then((result) => result?.ok === true);
/// Send now on a steer the agent has not read (`_acpmux/queue_edit` send_now with its promptId).
export const sendSteerNow = (promptId: string) => void editQueued(promptId, { op: "send_now" }).catch(() => false);
/// Opens a chat started from an offer (`chat.offer.open`): beside this one, else here.
export const openOfferChat = (sessionId: string) =>
  void callNative("chat.offer.open", { sessionId }).catch(() => undefined);
/// Opens the chat that sent this one a message, from its received line's chip: any chat the daemon
/// lists, this Mac's or a peer's, beside this one or in the tab that shows it (`sender`).
export const openSenderChat = (sessionId: string) =>
  void callNative("chat.offer.open", { sessionId, sender: true }).catch(() => undefined);
/// Reply on another agent's message card (`chat.message.reply`): its sender gets it in the thread.
export const replyToMessage = (message: IncomingMessage, text: string) =>
  callNative<void>("chat.message.reply", {
    sessionId: message.sessionId,
    msgId: message.msgId,
    threadId: message.threadId,
    text,
  });
