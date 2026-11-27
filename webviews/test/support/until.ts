// Waits on state, not on time (scripts/check-test-determinism.py: a test waits on a real signal and
// never sleeps then asserts).

/**
 * Resolves once `holds()` is true: a poll of real state, looked at again after each turn of the event
 * loop. `turn` is that turn; a React test passes `() => act(async () => {})`, which also flushes the
 * renders the turn caused. A state that never comes fails the test at its own timeout.
 */
export async function until(holds: () => boolean, turn?: () => Promise<unknown>): Promise<void> {
  while (!holds()) await (turn ? turn() : new Promise((resolve) => setTimeout(resolve, 0)));
}

/**
 * One turn of the event loop inside React's `act`, for `until` while a real timer (an auto-retry's
 * backoff) has to fire: `act(async () => {})` alone settles in microtasks and never lets it run.
 */
export async function actTurn(): Promise<void> {
  const { act } = await import("react");
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}
