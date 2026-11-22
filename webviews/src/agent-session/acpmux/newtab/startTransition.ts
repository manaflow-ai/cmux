/** Waits for a New Tab's host start before leaving the page. */
export async function startNewTabTransition<T>(
  start: () => Promise<T>,
  leave: () => void,
  isCurrent: () => boolean = () => true,
): Promise<T | undefined> {
  try {
    const result = await start();
    if (!isCurrent()) return undefined;
    leave();
    return result;
  } catch (error) {
    if (!isCurrent()) return undefined;
    // A refused start still needs to hand the prompt back to the chat composer.
    leave();
    throw error;
  }
}
