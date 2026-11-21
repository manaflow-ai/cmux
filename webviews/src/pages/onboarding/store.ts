// The onboarding page's store: the host's whole state (ops.ts), read once with `state` and then
// replaced by every `cmux.onboarding.changed`. Every gesture is one call; the host answers on the
// stream within a frame, so nothing here is optimistic.
import type { PageClient } from "../shared/pageClient";
import { OPS, type OnboardingOps, type OnboardingState } from "./ops";

type GestureOp = Exclude<keyof OnboardingOps, "cmux.onboarding.state" | "cmux.onboarding.focused">;

export class OnboardingStore {
  private state: OnboardingState | null;
  private readonly listeners = new Set<() => void>();
  private unsubscribe: (() => void) | null = null;
  private stopped = false;
  /** Tells the host the page gained focus (back from a Sign In). */
  private readonly onFocus = (): void => {
    void this.client?.call(OPS.focused, {}).catch(() => {});
  };

  constructor(
    private readonly client: PageClient | null,
    initial: OnboardingState | null = null,
  ) {
    this.state = initial;
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): OnboardingState | null => this.state;

  /** Subscribes first, then reads: a change that lands before the read's answer is newer, so the
   * answer is dropped then. */
  async start(): Promise<void> {
    const client = this.client;
    if (!client) return;
    let changed = false;
    const unsubscribe = await client.subscribe<OnboardingState>(OPS.changed, (next) => {
      changed = true;
      this.set(next);
    });
    if (this.stopped) {
      unsubscribe();
      return;
    }
    this.unsubscribe = unsubscribe;
    if (typeof window !== "undefined") window.addEventListener("focus", this.onFocus);
    try {
      const first = await client.call<OnboardingState>(OPS.state, {});
      if (!changed) this.set(first);
    } catch {
      // The host pushes the state on its next change; the page keeps its slots until then.
    }
  }

  stop(): void {
    this.stopped = true;
    if (typeof window !== "undefined") window.removeEventListener("focus", this.onFocus);
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  /** One gesture; its result comes back on the stream. */
  call<Op extends GestureOp>(op: Op, params: OnboardingOps[Op][0] = {} as OnboardingOps[Op][0]): void {
    void this.client?.call(op, params).catch(() => {});
  }

  /** The gallery and tests set a state directly. */
  set(next: OnboardingState): void {
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}
