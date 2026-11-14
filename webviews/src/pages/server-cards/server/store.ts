// The server surfaces' state owner on the page: the app's status, read again on every change event
// and after each of the page's own calls. React reads it through `useSyncExternalStore`; a reply
// older than a newer read is dropped.
import type { PageClient } from "../../shared/pageClient";
import { ServerOps, type ServerIntent, type ServerStatus } from "./types";

export class ServerStore {
  private status: ServerStatus | undefined;
  private readonly listeners = new Set<() => void>();
  private request = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.status;

  /** Follows the app's change events, then reads the status once. */
  async start(): Promise<void> {
    if (!this.client) return;
    try {
      const stop = await this.client.subscribe(ServerOps.changes, () => void this.refresh());
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the page still reads on open and after each of its own calls.
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
      const status = await this.client.call<ServerStatus>(ServerOps.status, {});
      if (id === this.request) this.set(status);
    } catch {
      // The last status stays; the next change event reads again.
    }
  }

  /** The switch, Show Pairing Code, Fix, Revoke: the app takes them only from the person's own click or key. */
  send(intent: ServerIntent): Promise<boolean> {
    return this.run(ServerOps.send, intent);
  }

  setCode(code: string): Promise<boolean> {
    return this.run(ServerOps.setCode, { code });
  }

  setName(name: string): Promise<boolean> {
    return this.run(ServerOps.setName, { name });
  }

  setTeam(team: string): Promise<boolean> {
    return this.run(ServerOps.setTeam, { team });
  }

  setRunChief(on: boolean): Promise<boolean> {
    return this.run(ServerOps.setRunChief, { on });
  }

  cancel(): Promise<boolean> {
    return this.run(ServerOps.cancel, {});
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

  private set(status: ServerStatus) {
    this.status = status;
    for (const listener of this.listeners) listener();
  }
}
