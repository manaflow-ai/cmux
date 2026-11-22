import { type ComposerAttachment } from "../attachments";
import { type KeptAttachments } from "../composer/keptAttachments";
import { callNative } from "../callNative";

/// Hands the host a new chat's typed text, kept with its tab across a relaunch (cx-z5vd).
/// The composer's text changed: the chat tells acpmux this pane types (never the text itself).
export const postTyping = (text: string, sessionId?: string) =>
  void window.cmuxAcpmuxActions?.["chat.typing"]?.({ text, sessionId }).catch(() => undefined);
const postUnsentDraft = (text: string) => callNative("chat.unsentDraft", { text }).catch(() => undefined);
/// The new chat's typed text, its prompts held for a trust answer, and held ones given back that no
/// composer took (`kept`, a new chat in another folder by then): the host keeps them all, so a held
/// prompt outlives the tab moving to another chat or folder as typed text does.
export const newChatDraft = { typed: "", held: [] as string[], kept: [] as string[] };
export const postNewChatDraft = () =>
  postUnsentDraft(
    [...newChatDraft.kept, ...newChatDraft.held, newChatDraft.typed].filter((part) => part.trim()).join("\n\n"),
  );
/// Each chat's unsent chips, kept by the host so reopening or restoring the chat brings them back
/// (AgentPaneDraftAttachments.swift). A host without the store (the gallery, an older app) keeps none.
export const keptAttachments: KeptAttachments = {
  read: (sessionId) =>
    callNative<unknown>("chat.draftAttachments.get", { sessionId }).then(
      (kept) => (Array.isArray(kept) ? (kept as ComposerAttachment[]) : []),
      () => [],
    ),
  write: (sessionId, attachments) =>
    callNative<{ held?: unknown } | null>("chat.draftAttachments", { sessionId, attachments }),
};
