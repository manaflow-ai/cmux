// The transcript's view, Claude Code desktop's Transcript view (Leo, 2026-10-29: "i like these kinds
// of settings from claude code desktop..."): Normal is the compact transcript, Thinking also opens
// every thought, Verbose also opens every tool's output. A view only changes what opens by default
// (transcriptDisclosure.tsx `useTranscriptDisclosure`, ThoughtRow.tsx), never how a row draws.
//
// The view is now the upper three rungs of the chat's detail ladder (chatDetail.ts,
// chatDetailChoice.ts): this module reads a chat's level as the view its rows open by (Messages reads
// as Normal) and keeps the old names for the callers that set one.
import {
  chatDetailOf,
  makeChatDetailDefault,
  resetChatDetails,
  setChatDetail,
  useChatDetail,
} from "./chatDetailChoice";
import { transcriptViewOfDetail, type TranscriptView } from "../chatDetail";

export { TRANSCRIPT_VIEWS, isTranscriptView, type TranscriptView } from "../chatDetail";
export { foldPlays } from "./chatDetailChoice";

/// The chat's view: its level's (Messages opens as Normal).
export const transcriptViewOf = (sessionId: string | undefined): TranscriptView =>
  transcriptViewOfDetail(chatDetailOf(sessionId));

/// The chat's view as a hook (the disclosure provider reads it once for its rows).
export const useTranscriptView = (sessionId: string | undefined): TranscriptView =>
  transcriptViewOfDetail(useChatDetail(sessionId));

/// Puts this chat at the view's level.
export const setTranscriptView = (sessionId: string, view: TranscriptView): void => setChatDetail(sessionId, view);

/// Makes the view's level the default.
export const makeTranscriptViewDefault = (sessionId: string | undefined, view: TranscriptView): void =>
  makeChatDetailDefault(sessionId, view);

/// Test and gallery reset: every chat follows the default again.
export const resetTranscriptViews = resetChatDetails;
