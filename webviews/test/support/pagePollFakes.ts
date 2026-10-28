// Fakes for page polls (src/pages/shared/pagePoll.ts): a document whose lifecycle the test moves
// and a clock that fires one-shot timers when the test advances it.
import type { LifecycleDocument } from "../../src/pages/shared/pageLifecycle";
import type { PollTimers } from "../../src/pages/shared/pagePoll";

export class FakeLifecycleDocument implements LifecycleDocument {
  visibilityState = "visible";
  private readonly listeners = new Map<string, Set<(event: { type: string }) => void>>();

  addEventListener(type: string, listener: (event: { type: string }) => void): void {
    const set = this.listeners.get(type) ?? new Set();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: (event: { type: string }) => void): void {
    this.listeners.get(type)?.delete(listener);
  }

  listenerCount(): number {
    let count = 0;
    for (const set of this.listeners.values()) count += set.size;
    return count;
  }

  private dispatch(type: string): void {
    for (const listener of this.listeners.get(type) ?? []) listener({ type });
  }

  hide(): void {
    this.visibilityState = "hidden";
    this.dispatch("visibilitychange");
  }

  show(): void {
    this.visibilityState = "visible";
    this.dispatch("visibilitychange");
  }

  /** Native's order: hidden, then frozen. */
  freeze(): void {
    if (this.visibilityState !== "hidden") this.hide();
    this.dispatch("freeze");
  }

  /** Native's order: resumed, then visible. */
  resume(): void {
    this.dispatch("resume");
    this.show();
  }
}

/**
 * One-shot timers the test fires by moving the clock. `armed` counts the timers waiting, `started`
 * every timer ever armed. `settle` runs after each fired timer, so an async read finishes before
 * the next timer fires.
 */
export class FakePollClock implements PollTimers {
  now = 0;
  started = 0;
  private next = 1;
  private readonly due = new Map<number, { at: number; callback: () => void }>();

  constructor(private readonly settle: () => Promise<void> | void = () => undefined) {}

  get armed(): number {
    return this.due.size;
  }

  after(ms: number, callback: () => void): unknown {
    this.started += 1;
    const handle = this.next++;
    this.due.set(handle, { at: this.now + ms, callback });
    return handle;
  }

  cancel(handle: unknown): void {
    this.due.delete(handle as number);
  }

  /** Moves the clock by `ms`, firing each timer as its time comes. */
  async advance(ms: number): Promise<void> {
    const end = this.now + ms;
    for (;;) {
      const first = [...this.due].sort((a, b) => a[1].at - b[1].at)[0];
      if (!first || first[1].at > end) break;
      this.due.delete(first[0]);
      this.now = first[1].at;
      first[1].callback();
      await this.settle();
    }
    this.now = end;
  }
}

/** Lets a few promise turns run: a fake read's reply and the poll's next arm. */
export async function flushMicrotasks(turns = 4): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) await Promise.resolve();
}
