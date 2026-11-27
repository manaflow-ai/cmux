// One detail ladder for every chat surface (Leo, 2026-11-01: "whatever stuff im capable of seeing and
// doing in the gui i should be able to do in the chief and likewise the minimalist imessage (for now)
// ui of chief should be doable"). The agent chat (conversation/chatDetailChoice.ts, the chat menu) and
// Home Channels (pages/home-channels/presentation.tsx) read these four levels and nothing else:
//
//   Messages  text bubbles, questions, permission asks; a subagent report is one line.
//   Normal    adds the tool rows and groups, folded.
//   Thinking  adds the thoughts, opened.
//   Verbose   adds every tool group opened, with its raw output.
//
// A pending question or permission ask shows at every level (messagesRows keeps them).
//
// The ladder replaces two knobs, `agentPane.display.presentation` (Transcript | Messages) and
// `agentPane.display.transcriptView` (Normal | Thinking | Verbose). Both still read
// (detailFromLegacy): Messages wins, else the old view carries over. New choices go to DETAIL_KEY.
import type { AcpmuxRow } from "./model";
import { messagesRows } from "./conversation/messagesRows";

export type ChatDetail = "messages" | "normal" | "thinking" | "verbose";
export const CHAT_DETAILS: readonly ChatDetail[] = ["messages", "normal", "thinking", "verbose"];
export const isChatDetail = (value: unknown): value is ChatDetail =>
  value === "messages" || value === "normal" || value === "thinking" || value === "verbose";

/// Settings > Agent Chat > Chat Detail: the level of a chat with none of its own.
export const DETAIL_KEY = "agentPane.display.detail";
/// The two settings the ladder replaced; they keep reading (defaultDetailOf).
export const TRANSCRIPT_VIEW_KEY = "agentPane.display.transcriptView";
export const PRESENTATION_KEY = "agentPane.display.presentation";

/// Normal: the compact transcript. Thinking: thoughts open. Verbose: tool output open too.
export type TranscriptView = "normal" | "thinking" | "verbose";
export const TRANSCRIPT_VIEWS: readonly TranscriptView[] = ["normal", "thinking", "verbose"];
export const isTranscriptView = (value: unknown): value is TranscriptView =>
  value === "normal" || value === "thinking" || value === "verbose";

export type Presentation = "transcript" | "messages";
export const PRESENTATIONS: readonly Presentation[] = ["transcript", "messages"];
export const isPresentation = (value: unknown): value is Presentation => value === "transcript" || value === "messages";

/// What a level shows: tool rows at all, thoughts opened, tool groups opened.
export interface DetailParts {
  tools: boolean;
  thoughtsOpen: boolean;
  toolsOpen: boolean;
}

export function detailParts(detail: ChatDetail): DetailParts {
  return {
    tools: detail !== "messages",
    thoughtsOpen: detail === "thinking" || detail === "verbose",
    toolsOpen: detail === "verbose",
  };
}

/// The rows a level draws: Messages keeps the speakers, pending asks and failed turns; every other
/// level keeps them all (and opens more of them, detailParts).
export const detailRows = (rows: AcpmuxRow[], detail: ChatDetail): AcpmuxRow[] =>
  detail === "messages" ? messagesRows(rows) : rows;

/// A level from the two old knobs: Messages wins, else the old view; undefined when neither says.
export function detailFromLegacy(presentation: unknown, view: unknown): ChatDetail | undefined {
  if (presentation === "messages") return "messages";
  return isTranscriptView(view) ? view : undefined;
}

/// The default level from the settings: the new key, else the two old ones, else Normal.
export function defaultDetailOf(raw: Readonly<Record<string, unknown>>): ChatDetail {
  const own = raw[DETAIL_KEY];
  if (isChatDetail(own)) return own;
  return detailFromLegacy(raw[PRESENTATION_KEY], raw[TRANSCRIPT_VIEW_KEY]) ?? "normal";
}

/// The level as the old two knobs the rows still draw by (PresentationContext, the disclosure view).
export const presentationOfDetail = (detail: ChatDetail): Presentation =>
  detail === "messages" ? "messages" : "transcript";
export const transcriptViewOfDetail = (detail: ChatDetail): TranscriptView =>
  detail === "messages" ? "normal" : detail;
