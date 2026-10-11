// Rule (g): heavy work leaves the input frame. `afterPaint` runs a task after the next paint (the
// input frame shows the state change first); `runChunked` splits work over frames within a time
// budget; both stop when their signal aborts, so superseded work is dropped.

type Yield = () => Promise<void>;

const defaultYield: Yield = () =>
  new Promise((resolve) => {
    // A macrotask lets the browser paint and handle input between chunks.
    if (typeof MessageChannel !== "undefined") {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        channel.port1.close();
        resolve();
      };
      channel.port2.postMessage(null);
    } else setTimeout(resolve, 0);
  });

/**
 * Runs `task` after the next paint: one animation frame, then a macrotask. Returns a cancel
 * function; an aborted `signal` cancels too.
 */
export function afterPaint(task: () => void, signal?: AbortSignal): () => void {
  let cancelled = false;
  const cancel = () => {
    cancelled = true;
  };
  signal?.addEventListener("abort", cancel, { once: true });
  const run = () => {
    void defaultYield().then(() => {
      signal?.removeEventListener("abort", cancel);
      if (!cancelled && !signal?.aborted) task();
    });
  };
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(run);
  else run();
  return cancel;
}

export interface ChunkedOptions {
  signal?: AbortSignal;
  /** Time per chunk, in ms (default 8, half a 60 Hz frame). */
  budgetMs?: number;
  now?: () => number;
  yieldToHost?: Yield;
}

/**
 * Calls `each` for every item, yielding to the host whenever a chunk exceeds the budget. Resolves
 * true when done, false when the signal aborted first.
 */
export async function runChunked<T>(
  items: Iterable<T>,
  each: (item: T) => void,
  options: ChunkedOptions = {},
): Promise<boolean> {
  const budget = options.budgetMs ?? 8;
  const clock = options.now ?? (() => performance.now());
  const yieldToHost = options.yieldToHost ?? defaultYield;
  let start = clock();
  for (const item of items) {
    if (options.signal?.aborted) return false;
    each(item);
    if (clock() - start >= budget) {
      await yieldToHost();
      start = clock();
    }
  }
  return !options.signal?.aborted;
}
