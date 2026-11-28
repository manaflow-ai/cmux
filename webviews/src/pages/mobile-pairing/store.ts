// The Mobile Pairing page's state owner: the host's pairing status, read again on every change
// event and whenever the shown QR code expires. React reads it through `useSyncExternalStore`; a
// reply older than a newer read is dropped.
import type { PageClient } from "../shared/pageClient";
import { ACTION_RUN, MobilePairingOps, PairingActions, type MobilePairingStatus } from "./types";

export interface MobilePairingSnapshot {
  status?: MobilePairingStatus;
  loading: boolean;
  /** The status did not load; the page says so in its own words. */
  failed?: { message?: string };
  /** The page has no host to ask; the page says so in its own words. */
  unavailable?: boolean;
}

export class MobilePairingStore {
  private snapshot: MobilePairingSnapshot = { loading: true };
  private readonly listeners = new Set<() => void>();
  private request = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(
    private readonly client: PageClient | null,
    private readonly now: () => number = Date.now,
  ) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** Follows the host's change events, then reads the status once. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ loading: false, unavailable: true });
    try {
      const stop = await this.client.subscribe(MobilePairingOps.changes, () => void this.refresh());
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the page still reads on open, on a click and on expiry.
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
    this.set({ ...this.snapshot, loading: true });
    try {
      const status = await this.client.call<MobilePairingStatus>(MobilePairingOps.status, {});
      if (id === this.request) this.set({ status, loading: false });
    } catch {
      if (id === this.request) this.set({ status: this.snapshot.status, loading: false, failed: {} });
    }
  }

  /** Reads again once the shown code has expired (the host mints the next one). */
  async refreshIfExpired(): Promise<void> {
    const qr = this.snapshot.status?.qr;
    if (qr && this.now() >= qr.expiresAt) await this.refresh();
  }

  /** Turns iPhone connections on or off; the host takes it only from the person's own click. */
  async setAllowed(on: boolean): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(MobilePairingOps.setAllowed, { on });
    } catch {
      this.set({ ...this.snapshot, failed: {} });
      return;
    }
    await this.refresh();
  }

  /** Allow or Don't Allow on a phone's waiting request; the host takes it only from the person's own click. */
  async answerPair(id: string, allow: boolean): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(MobilePairingOps.answerPair, { id, allow });
    } catch {
      this.set({ ...this.snapshot, failed: {} });
      return;
    }
    await this.refresh();
  }

  signIn(): Promise<void> {
    return this.run(PairingActions.signIn);
  }

  openAccounts(): Promise<void> {
    return this.run(PairingActions.accounts);
  }

  private async run(action: string): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(ACTION_RUN, { action });
    } catch {
      this.set({ ...this.snapshot, failed: {} });
    }
  }

  private set(snapshot: MobilePairingSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
