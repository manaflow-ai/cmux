/// A refused handshake that offers Restart acpmux (`details.restartAcpmux`): another binary's
/// daemon holds this app's acpmux socket, so asking the host again alone cannot connect.
export function offersAcpmuxRestart(error: unknown): boolean {
  const details = (error as { details?: unknown } | null)?.details;
  return !!details && typeof details === "object" && (details as { restartAcpmux?: unknown }).restartAcpmux === true;
}

/// Refusals that offer Restart acpmux before the pane stops asking on its own and waits for the
/// person (Retry, or Restart acpmux): the first ask and two automatic retries.
export const REFUSED_AUTO_RETRIES = 3;

/// After a failed handshake: how many refusals offered Restart acpmux since the last connect,
/// whether the card offers it, and whether the pane stops retrying on its own. Any other failure
/// keeps retrying (a daemon that is starting, or not installed yet, may be there on the next ask)
/// and keeps the count, so failures that alternate cannot retry forever; only a connect resets it.
export function afterHostFailure(
  refusedInRow: number,
  error: unknown,
): { refusedInRow: number; offersRestart: boolean; stopped: boolean } {
  const offersRestart = offersAcpmuxRestart(error);
  const count = offersRestart ? refusedInRow + 1 : refusedInRow;
  return { refusedInRow: count, offersRestart, stopped: offersRestart && count >= REFUSED_AUTO_RETRIES };
}
