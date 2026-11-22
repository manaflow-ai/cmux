// Bookmarked prompts as the rail, its card and the transcript's own prompt rows see them. acpmux
// keeps the marks with the session (bookmarks.ts, `_acpmux/bookmark_set`): a mark is the seq of the
// prompt's `user_message` record, which is its row id (`user-<seq>`). A message's Pin is the same mark:
// on a prompt, or on an answer through its turn's `turn_result` (`summary-<seq>`). This is the one place that
// reads that API, so the rail and the rows never key a mark on their own.
import { createContext, useContext } from "react";
import { markSeq, useBookmarks } from "./bookmarks";
import { useTranscriptReadOnly } from "../conversation/readOnly";

/// A prompt as a mark names it: its row id. A rail tick that folds a run of other chats' messages
/// (model.ts `foldIncoming`) also names every message's row: it shows as marked when any of them is,
/// a toggle on it takes off every mark among them, or else marks its own (the run's first) message.
export type MarkedPrompt = { id: string; members?: readonly string[] };

/// The transcript's session, for prompt rows that mark themselves (VirtualTranscript provides it).
export const PromptMarksSession = createContext<string | undefined>(undefined);

/// The session acpmux keeps marks for: none for a subagent's view (`<session>:subagent:<id>`), whose
/// prompts are not the chat's.
const markedSession = (sessionId: string | undefined) =>
  sessionId && !sessionId.includes(":subagent:") ? sessionId : undefined;

export function usePromptMarks(sessionId: string | undefined): {
  has: (prompt: MarkedPrompt) => boolean;
  /// Whether a prompt can carry a mark: acpmux has logged it.
  can: (prompt: MarkedPrompt) => boolean;
  toggle: (prompt: MarkedPrompt) => void;
} {
  // Read only (a guest), marks are the owner's: none are read or set.
  const readOnly = useTranscriptReadOnly();
  const session = markedSession(sessionId);
  const { marks, toggle } = useBookmarks(session, readOnly);
  const can = (prompt: MarkedPrompt) => !readOnly && session !== undefined && markSeq(prompt.id) !== undefined;
  const marked = (prompt: MarkedPrompt) =>
    (prompt.members ?? [prompt.id]).map(markSeq).filter((seq): seq is number => seq !== undefined && marks.has(seq));
  return {
    has: (prompt) => marked(prompt).length > 0,
    can,
    toggle: (prompt) => {
      if (readOnly) return;
      const on = marked(prompt);
      if (on.length) for (const seq of on) toggle(seq);
      else {
        const seq = markSeq(prompt.id);
        if (seq !== undefined) toggle(seq);
      }
    },
  };
}

/// The pin of a transcript row (a prompt, or an answer's footer) in the session being shown.
export function useRowMark(row: { id: string }): { can: boolean; marked: boolean; toggle: () => void } {
  const marks = usePromptMarks(useContext(PromptMarksSession));
  return { can: marks.can(row), marked: marks.has(row), toggle: () => marks.toggle(row) };
}
