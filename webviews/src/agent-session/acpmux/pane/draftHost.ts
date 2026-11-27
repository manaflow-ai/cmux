import { type ComposerAttachment } from "../attachments";
import { type KeptAttachments } from "../composer/keptAttachments";
import { callNative } from "../callNative";
import { adoptDraft, carriedChips, draftIdOf, noteBytes, validDraftId } from "../composer/carriedDraftImages";

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
///
/// The chat's acpmux draft id is kept with the host's chips: a reopened page and a second pane write
/// the same draft. A host with none for the chat takes the one draft acpmux holds for it, or none
/// when several do (carriedDraftImages.ts carriedDraft).
export const keptAttachments: KeptAttachments = {
  read: async (sessionId) => {
    // `withDraftId` asks for `{attachments, draftId?}`; an older app ignores it and answers the list.
    const kept = await callNative<unknown>("chat.draftAttachments.get", { sessionId, withDraftId: true }).then(
      nativeDraft,
      (): NativeDraft => ({ attachments: [] }),
    );
    if (kept.attachments.length) {
      noteBytes(sessionId, kept.attachments);
      adoptDraft(sessionId, kept.draftId ?? draftIdOf(sessionId), kept.attachments);
      return kept.attachments;
    }
    const carried = await Promise.resolve(draftImagesAction("chat.draftImages.get")?.({ sessionId })).catch(
      () => undefined,
    );
    const chips = carriedAttachments(carried);
    noteBytes(sessionId, chips);
    return chips;
  },
  write: (sessionId, attachments) => {
    noteBytes(sessionId, attachments);
    const draftId = draftIdOf(sessionId);
    const images = carriedChips(sessionId, attachments);
    void Promise.resolve(
      draftImagesAction("chat.draftImages.set")?.({ sessionId, draftId, attachments: images }),
    ).catch(() => undefined);
    return callNative<{ held?: unknown } | null>("chat.draftAttachments", { sessionId, attachments, draftId });
  },
};

/// The host's kept chips and draft id: `{attachments, draftId?}`, or an older app's bare list.
type NativeDraft = { attachments: ComposerAttachment[]; draftId?: string };
function nativeDraft(reply: unknown): NativeDraft {
  if (Array.isArray(reply)) return { attachments: reply as ComposerAttachment[] };
  if (!reply || typeof reply !== "object") return { attachments: [] };
  const { attachments, draftId } = reply as { attachments?: unknown; draftId?: unknown };
  return {
    attachments: Array.isArray(attachments) ? (attachments as ComposerAttachment[]) : [],
    ...(validDraftId(draftId) ? { draftId } : {}),
  };
}

/// The chips acpmux gave back (`chat.draftImages.get`): `{attachments}` (its draft is adopted as it is
/// read), or a list from an older page script.
function carriedAttachments(reply: unknown): ComposerAttachment[] {
  if (Array.isArray(reply)) return reply as ComposerAttachment[];
  const attachments = reply && typeof reply === "object" ? (reply as { attachments?: unknown }).attachments : undefined;
  return Array.isArray(attachments) ? (attachments as ComposerAttachment[]) : [];
}
