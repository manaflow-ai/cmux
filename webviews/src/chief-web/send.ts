import { ChiefUnavailable, InvalidClientMessageId, type ChiefApi } from "./api";

/** Retry temporary gateway/network failures with the original id. Unmount/auth expiry aborts
 * both the request and its single backoff timer; queued messages keep their composer order. */
export async function sendWithRetry(
  api: ChiefApi,
  text: string,
  clientId: string,
  signal: AbortSignal,
  attempt = 0,
): Promise<void> {
  signal.throwIfAborted();
  try {
    await api.send(text, clientId, signal);
  } catch (error) {
    signal.throwIfAborted();
    if (error instanceof InvalidClientMessageId) throw error;
    if (
      !(error instanceof ChiefUnavailable) &&
      !(error instanceof TypeError) &&
      !(error instanceof DOMException && error.name === "TimeoutError")
    )
      throw error;
    await new Promise<void>((resolve, reject) => {
      const cancel = () => {
        clearTimeout(timer);
        reject(signal.reason);
      };
      const timer = setTimeout(
        () => {
          signal.removeEventListener("abort", cancel);
          resolve();
        },
        Math.min(30_000, 1_000 * 2 ** Math.min(attempt, 5)),
      );
      signal.addEventListener("abort", cancel, { once: true });
    });
    return sendWithRetry(api, text, clientId, signal, attempt + 1);
  }
}
