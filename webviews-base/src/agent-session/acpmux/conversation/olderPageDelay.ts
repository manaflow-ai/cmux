/** One cancellable backoff, owned by the selected direct client. No idle scheduling. */
export class OlderPageDelay {
  private pending?: { timer: ReturnType<typeof setTimeout>; resolve: (ready: boolean) => void };

  wait(ms: number): Promise<boolean> {
    this.cancel();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending = undefined;
        resolve(true);
      }, ms);
      this.pending = { timer, resolve };
    });
  }

  // Selection reset/close cancels the timer AND releases its waiter. A late timer never asks
  // for the old session, and callers waiting on loadOlder do not remain pending indefinitely.
  cancel(): void {
    const pending = this.pending;
    this.pending = undefined;
    if (!pending) return;
    clearTimeout(pending.timer);
    pending.resolve(false);
  }
}
