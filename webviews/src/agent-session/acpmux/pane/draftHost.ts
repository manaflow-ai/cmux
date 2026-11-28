import { type ComposerAttachment } from "../attachments";
import { type KeptAttachments } from "../composer/keptAttachments";
import { callNative } from "../callNative";
import { draftAttachmentsStore } from "../composer/draftAttachmentsStore";
import { onDraftActionsChanged } from "../composerDraft";
import { composerFilledReporter } from "../conversation/toggleDraft";

/// Hands the host a new chat's typed text, kept with its tab across a relaunch (cx-z5vd).
/// The composer's text changed: the chat tells acpmux this pane types (never the text itself).
export const postTyping = (text: string, sessionId?: string) =>
  void window.cmuxAcpmuxActions?.["chat.typing"]?.({ text, sessionId }).catch(() => undefined);
const postUnsentDraft = (text: string) => callNative("chat.unsentDraft", { text }).catch(() => undefined);
/// Whether the composer holds anything, for Toggle Terminal and Chat (toggleDraft.ts): sent when it changes.
export const postComposerFilled = composerFilledReporter(
  (filled) => void callNative("pane.composerFilled", { filled }).catch(() => undefined),
);
/// The new chat's typed text, its prompts held for a trust answer, and held ones given back that no
/// composer took (`kept`, a new chat in another folder by then): the host keeps them all, so a held
/// prompt outlives the tab moving to another chat or folder as typed text does.
export const newChatDraft = { typed: "", held: [] as string[], kept: [] as string[] };
export const postNewChatDraft = () =>
  postUnsentDraft(
    [...newChatDraft.kept, ...newChatDraft.held, newChatDraft.typed].filter((part) => part.trim()).join("\n\n"),
  );
/// The host's store of each chat's unsent chips (AgentPaneDraftAttachments.swift), where they lived
/// before acpmux kept them. A host without the store (the gallery, an older app) keeps none.
const hostKeptAttachments: KeptAttachments = {
  read: (sessionId) =>
    callNative<unknown>("chat.draftAttachments.get", { sessionId }).then(
      (kept) => (Array.isArray(kept) ? (kept as ComposerAttachment[]) : []),
      () => [],
    ),
  write: (sessionId, attachments) =>
    callNative<{ held?: unknown } | null>("chat.draftAttachments", { sessionId, attachments }),
};
/// Each chat's unsent chips, kept by acpmux with the chat's session so reopening, restoring, a
/// restart or another client brings them back; an older daemon's page keeps them with the host
/// (composer/draftAttachmentsStore.ts).
export const keptAttachments: KeptAttachments = draftAttachmentsStore(
  () => {
    const actions = window.cmuxAcpmuxActions;
    const read = actions?.["chat.readDraftAttachments"];
    const write = actions?.["chat.writeDraftAttachments"];
    return {
      read: read && ((sessionId) => read({ sessionId })),
      write: write && ((sessionId, attachments) => write({ sessionId, attachments })),
    };
  },
  hostKeptAttachments,
  { actionsChanged: onDraftActionsChanged },
);
