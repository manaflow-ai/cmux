// The Set Up cmux card's store: the host's whole state, read once with `state` and then replaced by
// every `cmux.setup.changed`. Gestures are one call each; the host answers on the stream.
import type { SetupState } from "../home-messages/cards/setup/setupModel";
import type { PageClient } from "../shared/pageClient";
import { SETUP_OPS } from "./ops";

export class SetupCardStore {
  private state: SetupState | null = null;
  private readonly listeners = new Set<() => void>();
  private unsubscribe: (() => void) | null = null;
  private stopped = false;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): SetupState | null => this.state;

  /** Subscribes first, then reads: a change that lands before the read's answer is newer. */
  async start(): Promise<void> {
    const client = this.client;
    if (!client) return;
    let changed = false;
    const unsubscribe = await client.subscribe<SetupState>(SETUP_OPS.changed, (next) => {
      changed = true;
      this.set(next);
    });
    if (this.stopped) return unsubscribe();
    this.unsubscribe = unsubscribe;
    try {
      const first = await client.call<SetupState>(SETUP_OPS.state, {});
      if (!changed) this.set(first);
    } catch {
      // The host pushes the state on its next change.
    }
  }

  stop(): void {
    this.stopped = true;
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  /** A call the host answers on the stream; a refusal (no gesture) changes nothing. */
  send(op: string, params: unknown): void {
    void this.client?.call(op, params).catch(() => {});
  }

  private set(next: SetupState): void {
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}
