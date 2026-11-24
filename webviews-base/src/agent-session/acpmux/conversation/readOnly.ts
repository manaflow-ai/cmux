// A transcript drawn for someone who may only read it: a shared chat's guest (guest/GuestPage.tsx).
// Every control that acts on the owner's machine or daemon reads this and does not draw: Reply,
// Send now, queue edits, permission and question answers, Approve and Decline, Retry, fork and
// branch, pins, Undo, restarting or stopping work, and opening files, chats, pages or links in the
// host. What stays is the reader's own: expand and collapse, Copy, wrap. VirtualTranscript provides
// it (`readOnly`) and draws the rows with `readOnlyRegistry` (App.tsx).
import { createContext, useContext } from "react";

export const TranscriptReadOnly = createContext(false);

/** True inside a transcript drawn read only. */
export function useTranscriptReadOnly(): boolean {
  return useContext(TranscriptReadOnly);
}
