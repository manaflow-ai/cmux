// The reader's seen cursor for the chat on screen (direct.ts `readCursor`, acpmux hub/seen.rs), as a
// small store the transcript reads with useSyncExternalStore (VirtualTranscript.tsx, the jump
// control). The cursor moves as rows come into view while the reader attends; a snapshot of the
// whole pane for each move re-rendered the pane, its header and Session Info
// (agent-pane-tool-tick-pane-renders.test.ts), so only the transcript hears it here.

let cursor: { sessionId: string; seq: number } | undefined;
const listeners = new Set<() => void>();

/// The cursor moved (or another chat's took its place).
export function publishReadThrough(sessionId: string, seq: number): void {
  if (cursor?.sessionId === sessionId && cursor.seq === seq) return;
  cursor = { sessionId, seq };
  for (const listener of listeners) listener();
}

export function subscribeReadThrough(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/// The cursor of chat `sessionId`, if this page holds it.
export function readThroughOf(sessionId: string | undefined): number | undefined {
  return sessionId !== undefined && cursor?.sessionId === sessionId ? cursor.seq : undefined;
}
