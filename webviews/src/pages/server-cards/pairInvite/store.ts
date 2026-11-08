// The Pair Another Machine card's state owner: the host's status, read again on every change event.
// React reads it through `useSyncExternalStore`; a reply older than a newer read is dropped.
import type { PageClient } from "../../shared/pageClient";
import { PairInviteOps, type CopyTarget, type PairInviteStatus } from "./types";

export interface PairInviteSnapshot {
  status?: PairInviteStatus;
  /** What was copied in this session (its button says Copied until the next invite). */
  copied: CopyTarget | null;
}

export class PairInviteStore {
  private snapshot: PairInviteSnapshot = { copied: null };
  private readonly listeners = new Set<() => void>();
  private request = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** Follows the host's change events, then reads the status once. */
  async start(): Promise<void> {
    if (!this.client) return;
    try {
      const stop = await this.client.subscribe(PairInviteOps.changes, () => void this.refresh());
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the card still reads on open and after each of its own calls.
    }
    await this.refresh();
  }

  stop(): void {
    this.stopped = true;
    this.stopChanges?.();
    this.stopChanges = undefined;
  }

  async refresh(): Promise<void> {
    if (!this.client) return;
    const id = ++this.request;
    try {
      const status = await this.client.call<PairInviteStatus>(PairInviteOps.status, {});
      if (id !== this.request) return;
      const sameSession = this.snapshot.status?.session === status.session;
      this.set({ status, copied: sameSession ? this.snapshot.copied : null });
    } catch {
      // The last status stays; the next change event reads again.
    }
  }

  async copy(target: CopyTarget): Promise<void> {
    if (await this.run(PairInviteOps.copy, { target })) this.set({ ...this.snapshot, copied: target });
  }

  newCode(): Promise<boolean> {
    return this.run(PairInviteOps.newCode, {});
  }

  setRunChief(on: boolean): Promise<boolean> {
    return this.run(PairInviteOps.setRunChief, { on });
  }

  /** The host takes it only from the person's own click on the card. */
  confirm(name: string): Promise<boolean> {
    return this.run(PairInviteOps.confirm, { name });
  }

  private async run(op: string, params: unknown): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(op, params);
      return true;
    } catch {
      return false;
    } finally {
      void this.refresh();
    }
  }

  private set(snapshot: PairInviteSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
