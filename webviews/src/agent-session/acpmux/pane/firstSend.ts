/// A new chat's first send in a picked folder: `start` is its `chat.new`, `send` its `chat.send`.
///
/// With a pick holding the start (`heldPick` names a harness), `chat.new` lands on HarnessSwitch's
/// deferred switch, whose start resolves only once a prompt reaches it. So the prompt goes in the
/// same turn, queued on that switch, which owns the start's failure (its card, with Retry, and the
/// prompt back in the composer) and the folder's trust question. Waiting for the start first
/// deadlocked both: no prompt went and nothing showed (cmux#55755; the New Tab page's Send already
/// sends in the same turn, App.tsx).
///
/// Without a pick the start comes first, so a refused start never sends the prompt to another chat.
export async function startThenSend<T>(
  start: () => Promise<unknown>,
  send: () => Promise<T>,
  pickHoldsStart: boolean,
): Promise<T> {
  if (!pickHoldsStart) {
    await start();
    return send();
  }
  // The switch reports its own failure through the queued prompt's send, so nothing here waits on it.
  void start().catch(() => undefined);
  return send();
}
