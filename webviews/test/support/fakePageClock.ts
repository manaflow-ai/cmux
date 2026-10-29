// A page clock on a document and timers the test moves (ui/pageClock.ts), for a
// poll that must run no timer while its page is hidden.
import { type LifecycleDocument, PageLifecycle } from "../../src/pages/shared/pageLifecycle";
import { type ClockTimers, PageClock } from "../../src/ui/pageClock";

/** A document whose visibility the test sets; it tells its `visibilitychange` listeners. */
export class FakeVisibilityDocument implements LifecycleDocument {
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

  hide(): void {
    this.set("hidden");
  }

  show(): void {
    this.set("visible");
  }

  private set(state: string): void {
    this.visibilityState = state;
    for (const listener of this.listeners.get("visibilitychange") ?? []) listener({ type: "visibilitychange" });
  }
}

/** One-shot timers on a clock the test moves; `live` counts the pending ones, `armed` all of them. */
export class FakeClockTimers implements ClockTimers {
  armed = 0;
  private next = 1;
  private readonly pending = new Map<number, { due: number; callback: () => void }>();

  constructor(private time: number) {}

  now(): number {
    return this.time;
  }

  after(ms: number, callback: () => void): unknown {
    this.armed += 1;
    const id = this.next++;
    this.pending.set(id, { due: this.time + ms, callback });
    return id;
  }

  cancel(handle: unknown): void {
    this.pending.delete(handle as number);
  }

  /** The timers armed and not yet run or cancelled. */
  get live(): number {
    return this.pending.size;
  }

  /** Moves the clock by `ms`, running each timer when it comes due. */
  advance(ms: number): void {
    const end = this.time + ms;
    for (;;) {
      let first: [number, { due: number; callback: () => void }] | undefined;
      for (const entry of this.pending) if (!first || entry[1].due < first[1].due) first = entry;
      if (!first || first[1].due > end) break;
      this.pending.delete(first[0]);
      this.time = Math.max(this.time, first[1].due);
      first[1].callback();
    }
    this.time = end;
  }
}

/** A visible page at `start` (epoch ms) with its lifecycle, clock and the timers behind it. */
export function fakePage(start: number): {
  doc: FakeVisibilityDocument;
  lifecycle: PageLifecycle;
  timers: FakeClockTimers;
  clock: PageClock;
} {
  const doc = new FakeVisibilityDocument();
  const lifecycle = new PageLifecycle(doc);
  const timers = new FakeClockTimers(start);
  return { doc, lifecycle, timers, clock: new PageClock(lifecycle, timers) };
}
