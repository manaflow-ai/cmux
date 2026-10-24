/// Applies a native Stop Agent Turn request to the current composer only while its snapshot still
/// says the turn is running. The snapshot guard drops a command that arrived after a session switch
/// or after the turn ended, so an old palette selection cannot cancel newer work.
export function stopTurnFromAction(isWorking: boolean, stop: () => void): boolean {
  if (!isWorking) return false;
  stop();
  return true;
}
