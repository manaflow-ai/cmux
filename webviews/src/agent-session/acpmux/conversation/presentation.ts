// The chat's presentation: Messages is the bottom rung of the chat's detail ladder (chatDetail.ts,
// chatDetailChoice.ts), the bubble view with tool rows hidden; every other level is the Transcript.
// The presentation only changes which rows are drawn; row components remain responsible for their
// own content. This module keeps the old names for the callers that read or set one.
import {
  chatDetailOf,
  hasOwnChatDetail,
  makeChatDetailDefault,
  resetChatDetails,
  setChatDetail,
  useChatDetail,
} from "./chatDetailChoice";
import { presentationOfDetail, type Presentation } from "../chatDetail";
import { defaultChatDetail } from "../chatDisplay";

export { PRESENTATIONS, isPresentation, type Presentation } from "../chatDetail";

/// The chat's presentation: Messages at the Messages level, else Transcript.
export const presentationOf = (sessionId: string | undefined): Presentation =>
  presentationOfDetail(chatDetailOf(sessionId));

/// Whether the chat has a level of its own.
export const hasOwnPresentation = hasOwnChatDetail;

/// The chat's presentation as a hook.
export const usePresentation = (sessionId: string | undefined): Presentation =>
  presentationOfDetail(useChatDetail(sessionId));

/// The level a presentation puts a chat at: Transcript keeps a transcript level, else the default's,
/// else Normal.
function levelOf(sessionId: string | undefined, presentation: Presentation) {
  if (presentation === "messages") return "messages" as const;
  const now = chatDetailOf(sessionId);
  if (now !== "messages") return now;
  const fallback = defaultChatDetail();
  return fallback === "messages" ? "normal" : fallback;
}

/// Set a presentation for this chat only.
export const setPresentation = (sessionId: string, presentation: Presentation): void =>
  setChatDetail(sessionId, levelOf(sessionId, presentation));

/// Make a presentation the global default and clear this chat's own level, if any.
export const makePresentationDefault = (sessionId: string | undefined, presentation: Presentation): void =>
  makeChatDetailDefault(sessionId, levelOf(sessionId, presentation));

/// Test and gallery reset: every chat follows the global default again.
export const resetPresentations = resetChatDetails;
