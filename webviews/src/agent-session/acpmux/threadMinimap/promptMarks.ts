// Bookmarked prompts as the rail, its card and the transcript's own prompt rows see them. The
// marks live in bookmarks.ts (its store and persistence); this is the one place that reads its API,
// so a change in how a mark is keyed stays here.
import { createContext, useContext } from "react";
import { useBookmarks } from "./bookmarks";
import { turnKey } from "./model";

/// A prompt as a mark names it: its row id and its key (model.ts turnKey).
export type MarkedPrompt = { id: string; key: string };

/// The transcript's session, for prompt rows that key their own marks (VirtualTranscript provides it).
export const PromptMarksSession = createContext<string>("");

export function usePromptMarks(): {
  has: (prompt: MarkedPrompt) => boolean;
  toggle: (prompt: MarkedPrompt) => void;
  /// Changes with every mark, for memoized consumers.
  version: unknown;
} {
  const { marks, toggle } = useBookmarks();
  return { has: (prompt) => marks.has(prompt.key), toggle: (prompt) => toggle(prompt.key), version: marks };
}

/// The mark of a transcript prompt row in the session being shown.
export function usePromptRowMark(row: { id: string; text?: string }): { marked: boolean; toggle: () => void } {
  const sessionId = useContext(PromptMarksSession);
  const marks = usePromptMarks();
  const prompt = { id: row.id, key: turnKey(sessionId, row.id, row.text ?? "") };
  return { marked: marks.has(prompt), toggle: () => marks.toggle(prompt) };
}
