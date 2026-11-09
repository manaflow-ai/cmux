// An attachment read or upload that fails tries again on its own, a few times with a growing
// wait, before its tile shows Retry (Leo, 2026-11-06: "why does it not retry this? The
// screenshots, or whatever, or any sort of attachment when it fails, like you can't simply just do
// nothing about it"). Most failures are a moment's: the socket reconnecting, a session switch, the
// daemon busy. The tries stop after the last wait; what fails then shows Retry, never nothing.

/// The waits before each try again, in ms: three more tries, about nine seconds in all. Tests set
/// shorter ones.
export const attachmentRetry = { delaysMs: [500, 2_000, 6_000] as readonly number[] };

/// Runs `run`, and again after each wait in `attachmentRetry.delaysMs` while it throws an error
/// `retries` accepts (any error but an abort by default). Rejects with the last error once the
/// tries are spent, or at once when `signal` aborts.
export async function withAttachmentRetries<T>(
  run: () => Promise<T>,
  options: { retries?: (error: unknown) => boolean; signal?: AbortSignal } = {},
): Promise<T> {
  const { retries = (error) => !isAbort(error), signal } = options;
  const delays = attachmentRetry.delaysMs;
  for (let attempt = 0; ; attempt++) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= delays.length || signal?.aborted || !retries(error)) throw error;
      await wait(delays[attempt]!, signal);
    }
  }
}

export function isAbort(error: unknown): boolean {
  return (error as { name?: unknown } | undefined)?.name === "AbortError";
}

function wait(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const aborted = () => {
      clearTimeout(timer);
      reject(new DOMException("cancelled", "AbortError"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", aborted);
      resolve();
    }, ms);
    signal?.addEventListener("abort", aborted, { once: true });
  });
}
