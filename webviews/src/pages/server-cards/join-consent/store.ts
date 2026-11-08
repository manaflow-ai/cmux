// The join consent ask's state owner: the host's status, read again on every change event. React
// reads it through `useSyncExternalStore`; a reply older than a newer read is dropped.
import type { PageClient } from "../../shared/pageClient";
import { JoinConsentOps, type JoinConsentStatus } from "./types";

export class JoinConsentStore {
  private status?: JoinConsentStatus;
  private readonly listeners = new Set<() => void>();
  private request = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(private readonly client: Pick<PageClient, "call" | "subscribe"> | null) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.status;

  /** Follows the host's change events, then reads the status once. */
  async start(): Promise<void> {
    if (!this.client) return;
    try {
      const stop = await this.client.subscribe(JoinConsentOps.changes, () => void this.refresh());
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the ask still reads on open and after each answer.
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
      const status = await this.client.call<JoinConsentStatus>(JoinConsentOps.status, {});
      if (id !== this.request) return;
      this.status = status;
      for (const listener of this.listeners) listener();
    } catch {
      // The last status stays; the next change event reads again.
    }
  }

  /** Deny; none while a write is in flight. Allow is the panel's native button, never the page's. */
  async deny(): Promise<void> {
    if (!this.client || !this.status?.ask || this.status.writing) return;
    try {
      await this.client.call(JoinConsentOps.deny, {});
    } catch {
      // Refused (no gesture): the ask stays as it is.
    }
    await this.refresh();
  }
}
