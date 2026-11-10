// The Task Manager page's state owner: the last snapshot the app pushed, the column order and the
// selected row. React reads it through `useSyncExternalStore`; each change makes a new state object,
// so a component given the state as an argument redraws with it.
import type { PageClient } from "../shared/pageClient";
import { keptSelection, killableRow, nextOrder, sortRows } from "./model";
import { TaskManagerOps, type SortKey, type SortOrder, type TaskManagerRow, type TaskManagerSnapshot } from "./types";

export interface TaskManagerState {
  snapshot: TaskManagerSnapshot;
  order: SortOrder | null;
  /** The rows as shown: the snapshot's in `order`. */
  rows: TaskManagerRow[];
  selected: string | null;
  /** The page has no host to ask (a browser without the bridge). */
  unavailable: boolean;
}

/** What a kill needs from the event that asked for it: a real click, key or menu choice. */
export interface KillGesture {
  readonly isTrusted: boolean;
}

export const EMPTY_SNAPSHOT: TaskManagerSnapshot = { revision: 0, rows: [], total: "" };

export class TaskManagerStore {
  private state: TaskManagerState;
  private listeners = new Set<() => void>();
  private unsubscribe?: () => void;
  /** The selection the app holds, as last heard (a snapshot's `selected`) or last told. */
  private hostSelected: string | null;

  constructor(
    private readonly client: PageClient | null,
    initial: { snapshot?: TaskManagerSnapshot; order?: SortOrder | null; selected?: string | null } = {},
  ) {
    const snapshot = initial.snapshot ?? EMPTY_SNAPSHOT;
    const order = initial.order ?? null;
    this.state = {
      snapshot,
      order,
      rows: sortRows(snapshot.rows, order),
      selected: keptSelection(initial.selected ?? null, snapshot.rows),
      unavailable: client === null,
    };
    this.hostSelected = this.state.selected;
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getState = () => this.state;

  /** Follows the app's samples until `stop`. */
  async start(): Promise<void> {
    if (!this.client || this.unsubscribe) return;
    this.unsubscribe = await this.client.subscribe<TaskManagerSnapshot>(TaskManagerOps.snapshot, (snapshot) =>
      this.replace(snapshot),
    );
  }

  stop() {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  /**
   * A new snapshot replaces the rows. The app's `selected` is the one selection every page shows
   * (another window's click moves it here too); a host without it leaves the page's own, kept
   * while its process is listed.
   */
  replace(snapshot: TaskManagerSnapshot) {
    const authoritative = snapshot.selected !== undefined;
    const selected = keptSelection(authoritative ? (snapshot.selected ?? null) : this.state.selected, snapshot.rows);
    const lost = !authoritative && selected !== this.state.selected;
    if (authoritative) this.hostSelected = selected;
    this.set({ ...this.state, snapshot, rows: sortRows(snapshot.rows, this.state.order), selected });
    if (lost) this.tellSelection();
  }

  /** A header click. */
  sortBy(key: SortKey) {
    const order = nextOrder(this.state.order, key);
    this.set({ ...this.state, order, rows: sortRows(this.state.snapshot.rows, order) });
  }

  /**
   * Selects one row (or none); the app learns it for `cmux app kill-process` with no pid. It is
   * sent whenever it differs from the app's selection, even if this page already shows it, so a
   * row another window selected since never stays the app's while this page shows its own.
   */
  select(id: string | null) {
    const selected = keptSelection(id, this.state.snapshot.rows);
    if (selected === this.hostSelected && selected === this.state.selected) return;
    if (selected !== this.state.selected) this.set({ ...this.state, selected });
    this.tellSelection();
  }

  /**
   * Kill Process for the selected row, only from the person's own gesture (`event.isTrusted`) and
   * only when the app's policy allows it. The app asks first, then ends it; the next sample shows it gone.
   */
  kill(event: KillGesture): boolean {
    const row = killableRow(this.state.snapshot.rows, this.state.selected);
    if (!event.isTrusted || !row || !this.client) return false;
    void this.client.call(TaskManagerOps.kill, { id: row.id }).catch(() => {});
    return true;
  }

  private tellSelection() {
    this.hostSelected = this.state.selected;
    const ids = this.state.selected === null ? [] : [this.state.selected];
    void this.client?.call(TaskManagerOps.select, { ids }).catch(() => {});
  }

  private set(state: TaskManagerState) {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
