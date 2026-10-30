/**
 * A new chat's typed text on its way to the host (`chat.unsentDraft`), which keeps it with the tab across a
 * relaunch. It goes at most every `intervalMs` while the person types (leading and trailing edge: the first
 * change goes at once, and the last text always goes), and at once on `flush()` (blur, the page hidden, a
 * send). Before, a 300 ms debounce held every change until typing paused, so a crash lost all text typed
 * since the last pause.
 *
 * Seed guard: "" never goes before a non-empty text went. A relaunched chat starts with "" and its kept
 * draft comes later in the handshake; "" sent first would remove that draft from the host's file.
 */
export interface UnsentDraftThrottle {
  /** The composer's text changed. */
  push(text: string, generation?: number): void;
  /** Sends the waiting text now, if any. */
  flush(): void;
  /** Sends the waiting text now and resolves once the host answered the last send (a quit waits on it).
   * A send the host refused resolves too: the text stays in the page, and a quit cannot retry it. */
  settle(): Promise<void>;
  /** Stops the timer (a waiting text is not sent: call `flush()` first to keep it). */
  dispose(): void;
}

export interface UnsentDraftThrottleOptions {
  send(text: string, generation: number): unknown;
  intervalMs?: number;
  now?: () => number;
  setTimer?: (run: () => void, ms: number) => unknown;
  clearTimer?: (timer: unknown) => void;
}

export function createUnsentDraftThrottle(options: UnsentDraftThrottleOptions): UnsentDraftThrottle {
  const interval = options.intervalMs ?? 300;
  const now = options.now ?? (() => Date.now());
  const setTimer = options.setTimer ?? ((run, ms) => setTimeout(run, ms));
  const clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
  let lastSent: string | undefined;
  let lastGeneration = -1;
  let lastSentAt = -Infinity;
  let pending: { text: string; generation: number } | undefined;
  let timer: unknown;
  let sentNonEmpty = false;
  let lastDelivery: Promise<unknown> = Promise.resolve();

  const deliver = (text: string, generation: number) => {
    lastGeneration = generation;
    lastSent = text;
    lastSentAt = now();
    if (text) sentNonEmpty = true;
    lastDelivery = Promise.resolve(options.send(text, generation)).catch(() => undefined);
  };
  const stopTimer = () => {
    if (timer !== undefined) clearTimer(timer);
    timer = undefined;
  };
  const sendPending = () => {
    stopTimer();
    const state = pending;
    pending = undefined;
    if (state && (state.text !== lastSent || state.generation !== lastGeneration))
      deliver(state.text, state.generation);
  };
  return {
    push(text, generation = 0) {
      if (!text && !sentNonEmpty && generation === 0) return; // only a legacy empty seed is ignored
      if (generation < lastGeneration || (pending && generation < pending.generation)) return;
      if (text === lastSent && generation === lastGeneration && pending === undefined) return;
      pending = { text, generation };
      const wait = lastSentAt + interval - now();
      if (wait <= 0) return sendPending();
      if (timer === undefined) timer = setTimer(sendPending, wait);
    },
    flush: sendPending,
    settle() {
      sendPending();
      return lastDelivery.then(() => undefined);
    },
    dispose: stopTimer,
  };
}
