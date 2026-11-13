// The Machines section's state owner: the app's snapshot, read once, then replaced by each one the
// `changes` stream carries (the host sends none while the section is hidden). React reads it through
// `useSyncExternalStore`; a read older than a newer snapshot is dropped.
import type { PageClient } from "../shared/pageClient";
import { MachinesOps, type MachinesSnapshot } from "./types";

export interface MachinesState {
  snapshot?: MachinesSnapshot;
  /** The page has no host to ask. */
  unavailable?: boolean;
  /** The row whose native menu is open: its controls stay shown and its button lit. */
  menuOpen?: string;
  /** The joined row whose Remove question is open. */
  confirmRemove?: string;
  /** Rows the person removed: they leave the list in the frame of the click, before the host answers.
   * A row comes back only if the host refused (its caption then says so). */
  removed: ReadonlySet<string>;
}

export class MachinesStore {
  private state: MachinesState = { removed: new Set() };
  private readonly listeners = new Set<() => void>();
  /** Bumped by every snapshot that lands, so a read that started before it is dropped. */
  private version = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.state;

  /** Follows the host's snapshots, then reads the current one. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ ...this.state, unavailable: true });
    try {
      const stop = await this.client.subscribe<MachinesSnapshot>(MachinesOps.changes, (snapshot) =>
        this.land(snapshot),
      );
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without the stream the section still shows what the read below returns.
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
    const started = this.version;
    try {
      const snapshot = await this.client.call<MachinesSnapshot>(MachinesOps.snapshot, {});
      if (started === this.version) this.land(snapshot);
    } catch {
      // A failed read keeps what the section shows.
    }
  }

  /** Shows `snapshot` (the host's newest). A removed row it no longer lists as joined is done: gone,
   * or (a joined machine this app also runs) back as a plain machine row with the same id. */
  land(snapshot: MachinesSnapshot): void {
    this.version += 1;
    const joined = new Set(snapshot.rows.filter((row) => row.joined).map((row) => row.id));
    const removed = new Set([...this.state.removed].filter((id) => joined.has(id)));
    this.set({ ...this.state, snapshot, removed });
  }

  /** Asks before Remove (the page's own dialog). */
  askRemove(row: string): void {
    this.set({ ...this.state, confirmRemove: row });
  }

  cancelRemove(): void {
    this.set({ ...this.state, confirmRemove: undefined });
  }

  /** Remove, confirmed: the row leaves now; the host revokes it and takes it off every list. A refusal
   * brings it back. */
  async remove(row: string): Promise<void> {
    const removed = new Set(this.state.removed).add(row);
    this.set({ ...this.state, confirmRemove: undefined, removed });
    let ok = false;
    try {
      ok = (await this.client?.call<{ removed?: boolean }>(MachinesOps.remove, { row }))?.removed === true;
    } catch {
      ok = false;
    }
    if (ok) return;
    const back = new Set(this.state.removed);
    back.delete(row);
    this.set({ ...this.state, removed: back });
  }

  newWorkspace(machine: string): void {
    void this.client?.call(MachinesOps.newWorkspace, { machine }).catch(() => undefined);
  }

  addMachine(): void {
    void this.client?.call(MachinesOps.addMachine, {}).catch(() => undefined);
  }

  /** Opens a row's native menu at the page point (x, y); the row stays revealed until it closes. */
  async openMenu(row: string, menu: "row" | "joined", x: number, y: number): Promise<void> {
    if (!this.client) return;
    this.set({ ...this.state, menuOpen: row });
    try {
      await this.client.call(MachinesOps.menu, { row, menu, x, y });
    } catch {
      // No menu (no window, or the page closed): nothing to undo.
    } finally {
      if (this.state.menuOpen === row) this.set({ ...this.state, menuOpen: undefined });
    }
  }

  private set(state: MachinesState) {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
