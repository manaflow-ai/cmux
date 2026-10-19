import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { renderAttachment, subscribeRenderAttachment } from "./renderExecution";

/// View state belongs to its chat and row, even when virtual rows remount (Lucas 2026-10-18).
export const ChatSessionContext = createContext("");
export const TranscriptRowContext = createContext<string | undefined>(undefined);

/// A replayed reply cannot authorize script execution, even if its turn is unfinished.
export const RenderLiveContext = createContext<boolean | { attachment: number }>(false);

/// Reattachment revokes mounted frames too, including rows retained by transcript memoization.
export function useRenderAttachment() {
  const session = useContext(ChatSessionContext);
  const subscribe = useCallback((listener: () => void) => subscribeRenderAttachment(session, listener), [session]);
  return useSyncExternalStore(
    subscribe,
    () => renderAttachment(session),
    () => 0,
  );
}
