/// Applies a native Stop Agent Turn request to the requested session only while the current snapshot
/// still names that session and says its turn is running. The identity guard drops a command that
/// arrived after a session switch, so an old palette selection cannot cancel newer work.
export function stopTurnFromAction(
  snapshot: { sessionId?: string; isWorking: boolean },
  requestedSessionId: string | undefined,
  selectedSessionId: string | undefined,
  stop: () => void,
): boolean {
  if (
    !requestedSessionId ||
    snapshot.sessionId !== requestedSessionId ||
    selectedSessionId !== requestedSessionId ||
    !snapshot.isWorking
  )
    return false;
  stop();
  return true;
}
