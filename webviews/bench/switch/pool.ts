// Prototype of the warm session pool the daemon should own (plans/cmux-next/acp-usability.md).
// Here it runs in the page so the effect can be measured without a daemon change; the policy is
// the one proposed for acpmux: keep at most one pre-created session for the LAST-USED harness and
// one for the harness under the pointer or the picker's highlight, per cwd, and release an idle
// one after `idleMs` on an injected clock (no sleep-based timers).

export type Cancel = () => void;
/** The only time source the pool uses. Tests drive it by hand; the bench uses the page's timers. */
export interface Clock {
  now(): number;
  after(ms: number, run: () => void): Cancel;
}
export const pageClock: Clock = {
  now: () => performance.now(),
  after(ms, run) {
    const id = window.setTimeout(run, ms);
    return () => window.clearTimeout(id);
  },
};

export type Role = "last-used" | "hover";
type Entry = {
  harness: string;
  roles: Set<Role>;
  ready: Promise<string | undefined>;
  sessionId?: string;
  startedAt: number;
  readyAt?: number;
  release?: Cancel;
};

export type PoolOps = {
  /** session/new for `harness` without selecting it. */
  create(harness: string): Promise<string | undefined>;
  /** Stops and removes a pooled session nobody took. */
  discard(sessionId: string): Promise<void>;
};

export class WarmPool {
  private readonly entries = new Map<string, Entry>();
  constructor(
    private readonly ops: PoolOps,
    private readonly clock: Clock = pageClock,
    private readonly idleMs = 10 * 60_000,
  ) {}

  /** Harnesses with a pre-created session (or one being created). */
  warm(): Map<string, { ready: boolean; ms?: number }> {
    return new Map(
      [...this.entries].map(([h, e]) => [
        h,
        { ready: e.sessionId !== undefined, ms: e.readyAt && e.readyAt - e.startedAt },
      ]),
    );
  }

  /** Gives `harness` the role, starting its session if none is pooled; the role moves off any other harness. */
  hold(harness: string, role: Role): void {
    for (const [other, entry] of this.entries)
      if (other !== harness && entry.roles.delete(role) && entry.roles.size === 0) this.idle(entry);
    const existing = this.entries.get(harness);
    if (existing) {
      existing.roles.add(role);
      existing.release?.();
      existing.release = undefined;
      return;
    }
    const entry: Entry = {
      harness,
      roles: new Set([role]),
      startedAt: this.clock.now(),
      ready: Promise.resolve(undefined),
    };
    entry.ready = this.ops.create(harness).then(
      (id) => {
        entry.sessionId = id;
        entry.readyAt = this.clock.now();
        return id;
      },
      () => {
        this.entries.delete(harness);
        return undefined;
      },
    );
    this.entries.set(harness, entry);
  }

  /** Drops a role without taking the session (pointer left the row). */
  drop(harness: string, role: Role): void {
    const entry = this.entries.get(harness);
    if (entry?.roles.delete(role) && entry.roles.size === 0) this.idle(entry);
  }

  /** The pooled session for `harness` (ready or still starting), removed from the pool. */
  take(harness: string): Promise<string | undefined> | undefined {
    const entry = this.entries.get(harness);
    if (!entry) return undefined;
    this.entries.delete(harness);
    entry.release?.();
    return entry.ready;
  }

  /** A session for a harness nobody warmed: the pool's create path, never pooled. */
  start(harness: string): Promise<string | undefined> {
    return this.ops.create(harness);
  }

  private idle(entry: Entry): void {
    entry.release?.();
    entry.release = this.clock.after(this.idleMs, () => {
      if (this.entries.get(entry.harness) !== entry || entry.roles.size > 0) return;
      this.entries.delete(entry.harness);
      void entry.ready.then((id) => (id ? this.ops.discard(id) : undefined));
    });
  }

  dispose(): void {
    for (const entry of this.entries.values()) {
      entry.release?.();
      void entry.ready.then((id) => (id ? this.ops.discard(id) : undefined));
    }
    this.entries.clear();
  }
}
