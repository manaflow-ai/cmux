import { type ComposerAttachment } from "../attachments";
import { type KeptAttachments } from "../composer/keptAttachments";
import { callNative } from "../callNative";
import { carriedChips, noteBytes } from "../composer/carriedDraftImages";

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
/// The page's action that keeps a draft's images in acpmux (`chat.draftImages.*`, paneSnapshot.ts),
/// or none (the gallery, a pane without its client).
const draftImagesAction = (name: "chat.draftImages.get" | "chat.draftImages.set") => window.cmuxAcpmuxActions?.[name];

/// Each chat's unsent chips, kept by the host so reopening or restoring the chat brings them back
/// (AgentPaneDraftAttachments.swift). A host without the store (the gallery, an older app) keeps none.
/// The images among them are kept in acpmux too (composer/carriedDraftImages.ts, RFD 0138): they move
/// with the chat to Cloud or another machine, where the host keeps none for it and they come back
/// from acpmux. The host's answer is the write's; acpmux's is best effort and never holds it.
export const keptAttachments: KeptAttachments = {
  read: async (sessionId) => {
    const kept = await callNative<unknown>("chat.draftAttachments.get", { sessionId }).then(
      (kept) => (Array.isArray(kept) ? (kept as ComposerAttachment[]) : []),
      () => [] as ComposerAttachment[],
    );
    if (kept.length) {
      noteBytes(sessionId, kept);
      return kept;
    }
    const carried = await Promise.resolve(draftImagesAction("chat.draftImages.get")?.({ sessionId })).catch(
      () => undefined,
    );
    const chips = Array.isArray(carried) ? (carried as ComposerAttachment[]) : [];
    noteBytes(sessionId, chips);
    return chips;
  },
  write: (sessionId, attachments) => {
    noteBytes(sessionId, attachments);
    const images = carriedChips(sessionId, attachments);
    void Promise.resolve(draftImagesAction("chat.draftImages.set")?.({ sessionId, attachments: images })).catch(
      () => undefined,
    );
    return callNative<{ held?: unknown } | null>("chat.draftAttachments", { sessionId, attachments });
  },
};
