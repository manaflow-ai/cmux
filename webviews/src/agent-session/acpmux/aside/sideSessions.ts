import { useHeaderState } from "../header/headerState";
import type { AcpmuxSessionEntry } from "../sessionList";

/// Side sessions (`/btw <question>` opens a read-only side session beside the chat): the one gate
/// every entry point reads. It is Debug Settings' Side sessions (/btw) (`agentPane.debug.sideSessions`, off by
/// default), which the app sends as `sideSessions` in the chat's header state; absent means off.
export function useSideSessions(): boolean {
  return useHeaderState().sideSessions;
}

/// A newly-created side session may be selected before its `side` tag reaches the watched list.
/// Callers add ids as soon as they create them so the composer can hide nested `/btw` immediately.
export function isSideSession(
  sessionId: string | undefined,
  sessions: readonly AcpmuxSessionEntry[],
  knownSideSessionIds: ReadonlySet<string>,
): boolean {
  return Boolean(
    sessionId &&
      (knownSideSessionIds.has(sessionId) ||
        sessions.some((session) => session.sessionId === sessionId && session.side === true)),
  );
}
