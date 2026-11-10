// The team board's state owner. Rows live in a keyed map: a row component subscribes to its own id
// (`subscribeRow`), so one machine's change re-renders that row only. Changes land in the map at
// once and are published once per frame (`schedule`, requestAnimationFrame in the page): a burst of
// a hundred changes costs one flush. The totals move by each change's difference (O(1)); the list
// re-sorts only when an order key changed (model.ts `orderKeyChanged`), so a cost tick never does.
import type { PageClient } from "../shared/pageClient";
import {
  addToTotals,
  compareRows,
  contextOf,
  emptyTotals,
  joinRows,
  liveOf,
  matches,
  orderKeyChanged,
  rowOf,
  searchText,
  type BoardFilter,
  type BoardRow,
  type BoardTotals,
  type JoinContext,
} from "./model";
import { BoardOps, type BoardEvent, type BoardSnapshot, type TeamMachine } from "./types";

export interface BoardState {
  /** No host answered yet. */
  loading: boolean;
  /** The page has no host, or the host does not serve the board. */
  unavailable: boolean;
  /** The last read failed: its message, until a read succeeds. */
  failure?: string;
  /** Ids of the rows the filter and search keep, in board order. */
  visible: readonly string[];
  totals: Readonly<BoardTotals>;
  filter: BoardFilter;
  query: string;
}

/** What a row reads: its record, and the board's own state for it. */
export interface RowView {
  row: BoardRow;
  /** Stop was asked and the host has not answered. */
  stopping: boolean;
  /** The host refused the last Stop or Open: its message. */
  refused?: string;
}

export type Schedule = (flush: () => void) => void;

const frame: Schedule = (flush) =>
  typeof requestAnimationFrame === "function" ? requestAnimationFrame(() => flush()) : queueMicrotask(flush);

export class BoardStore {
  private rows = new Map<string, RowView>();
  private texts = new Map<string, string>();
  private order: string[] = [];
  private context: JoinContext = contextOf({ machines: [] });
  private totals: BoardTotals = emptyTotals();
  private state: BoardState = {
    loading: true,
    unavailable: false,
    visible: [],
    totals: emptyTotals(),
    filter: "all",
    query: "",
  };
  private readonly listeners = new Set<() => void>();
  private readonly rowListeners = new Map<string, Set<() => void>>();
  private dirtyRows = new Set<string>();
  private orderDirty = false;
  private orderGone = false;
  private pageDirty = false;
  private scheduled = false;
  /** Per row, bumped by each record the host sends for it, so a late Stop answer cannot undo a newer one. */
  private seen = new Map<string, number>();
  /** Events that arrived while a snapshot was being read: applied over it once it lands. */
  private held: BoardEvent[] | null = null;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(
    private readonly client: PageClient | null,
    private readonly schedule: Schedule = frame,
  ) {}

  // ---- reads (React: useSyncExternalStore) ----

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.state;

  /** Subscribes to one row's changes. */
  subscribeRow = (id: string, listener: () => void) => {
    let set = this.rowListeners.get(id);
    if (!set) this.rowListeners.set(id, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0) this.rowListeners.delete(id);
    };
  };

  getRow = (id: string): RowView | undefined => this.rows.get(id);

  // ---- host ----

  async start(): Promise<void> {
    if (!this.client) return this.publishState({ ...this.state, loading: false, unavailable: true });
    try {
      const stop = await this.client.subscribe<BoardEvent>(BoardOps.changes, (event) => this.apply(event));
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without the stream the board still shows what the read below returns.
    }
    await this.refresh();
  }

  stop(): void {
    this.stopped = true;
    this.stopChanges?.();
    this.stopChanges = undefined;
  }

  /**
   * Reads the snapshot. The stream keeps running meanwhile: its events are held and applied over
   * the snapshot once it lands, in order. Each event carries a whole record, so one the snapshot
   * already reflects applies again to the same result.
   */
  async refresh(): Promise<void> {
    if (!this.client || this.held) return;
    this.held = [];
    try {
      const snapshot = await this.client.call<BoardSnapshot>(BoardOps.snapshot, {});
      this.load(snapshot);
    } catch (error) {
      this.releaseHeld();
      const code = (error as { code?: unknown } | null)?.code;
      const unknown = typeof code === "string" && /unknown_op|op\.unknown|unsupported/.test(code);
      this.publishState({
        ...this.state,
        loading: false,
        unavailable: unknown,
        failure: unknown ? undefined : errorMessage(error),
      });
      return;
    }
    this.releaseHeld();
  }

  private releaseHeld(): void {
    const held = this.held ?? [];
    this.held = null;
    for (const event of held) this.apply(event);
  }

  // ---- changes ----

  /** One event of the host's stream. */
  apply(event: BoardEvent): void {
    if (this.held) {
      this.held.push(event);
      return;
    }
    switch (event.kind) {
      case "snapshot":
        return this.load(event.snapshot);
      case "machine":
        return this.upsert(event.machine);
      case "gone":
        return this.remove(event.id);
      case "audit": {
        const row = event.row;
        if (row.target !== "machine") return;
        const seen = this.context.last.get(row.targetId);
        if (seen && seen.at > row.at) return;
        this.context.last.set(row.targetId, row);
        return this.rejoin(row.targetId);
      }
      case "sessions":
        this.context.sessions[event.machine] = event.sessions;
        return this.rejoin(event.machine);
    }
  }

  /** Replaces everything with a snapshot (the first read, or the host's full resend). */
  load(snapshot: BoardSnapshot): void {
    this.context = contextOf(snapshot);
    const previous = this.rows;
    this.rows = new Map();
    this.texts = new Map();
    this.totals = emptyTotals();
    for (const row of joinRows(snapshot)) {
      const before = previous.get(row.id);
      this.seen.set(row.id, (this.seen.get(row.id) ?? 0) + 1);
      this.rows.set(row.id, { row, stopping: before?.stopping === true && row.state === "running" });
      this.texts.set(row.id, searchText(row));
      addToTotals(this.totals, row, 1);
    }
    for (const id of previous.keys()) if (!this.rows.has(id)) this.dirtyRows.add(id);
    for (const id of this.rows.keys()) this.dirtyRows.add(id);
    this.order = [...this.rows.keys()];
    this.state = { ...this.state, loading: false, unavailable: false, failure: undefined };
    this.markOrder();
  }

  private upsert(machine: TeamMachine): void {
    if (!machine?.id) return;
    this.seen.set(machine.id, (this.seen.get(machine.id) ?? 0) + 1);
    const next = rowOf(machine, this.context);
    const before = this.rows.get(machine.id);
    if (before) addToTotals(this.totals, before.row, -1);
    else this.order.push(machine.id);
    addToTotals(this.totals, next, 1);
    // A Stop is done once the machine left running.
    const stopping = before?.stopping === true && next.state === "running";
    const text = searchText(next);
    // A newer record supersedes a refusal the row was showing.
    this.rows.set(machine.id, { row: next, stopping });
    this.dirtyRows.add(machine.id);
    // A record that keeps its place and its filter result (a cost tick) moves nothing in the list.
    const filtered = this.state.filter !== "all" || this.state.query.trim() !== "";
    const query = this.state.query.trim().toLowerCase();
    if (!before || orderKeyChanged(before.row, next)) this.markOrder();
    else if (
      filtered &&
      matches(before.row, this.state.filter, query, this.texts.get(machine.id) ?? "") !==
        matches(next, this.state.filter, query, text)
    )
      this.markOrder();
    else this.markPage();
    this.texts.set(machine.id, text);
  }

  private remove(id: string): void {
    const before = this.rows.get(id);
    if (!before) return;
    this.seen.set(id, (this.seen.get(id) ?? 0) + 1);
    addToTotals(this.totals, before.row, -1);
    this.rows.delete(id);
    this.texts.delete(id);
    // The id leaves `order` at the next flush, which walks the list anyway.
    this.orderGone = true;
    this.dirtyRows.add(id);
    this.markOrder();
  }

  /** Re-joins one row after its audit or sessions changed. */
  private rejoin(id: string): void {
    const view = this.rows.get(id);
    if (!view) return;
    const merged: BoardRow = { ...view.row, ...liveOf(id, this.context) };
    addToTotals(this.totals, view.row, -1);
    addToTotals(this.totals, merged, 1);
    this.rows.set(id, { ...view, row: merged });
    this.dirtyRows.add(id);
    if (merged.waiting !== view.row.waiting) this.markOrder();
    else this.markPage();
  }

  // ---- intents ----

  setFilter(filter: BoardFilter): void {
    if (filter === this.state.filter) return;
    this.state = { ...this.state, filter };
    this.refilter();
  }

  setQuery(query: string): void {
    if (query === this.state.query) return;
    this.state = { ...this.state, query };
    this.refilter();
  }

  /**
   * Pauses a running machine. The row says Stopping until the host answers. The answer's record is
   * shown only when nothing newer came for the row meanwhile (the stream may already have sent the
   * paused machine, or its removal).
   */
  async stopMachine(id: string): Promise<void> {
    const view = this.rows.get(id);
    if (!this.client || !view || view.stopping) return;
    this.setRow(id, { ...view, stopping: true, refused: undefined });
    const pressed = this.seen.get(id) ?? 0;
    try {
      const machine = await this.client.call<TeamMachine>(BoardOps.stop, { machine: id });
      if (machine?.id === id && this.rows.has(id) && (this.seen.get(id) ?? 0) === pressed) this.upsert(machine);
      const now = this.rows.get(id);
      if (now?.stopping) this.setRow(id, { ...now, stopping: false });
    } catch (error) {
      const now = this.rows.get(id);
      if (now) this.setRow(id, { ...now, stopping: false, refused: errorMessage(error) });
    }
  }

  /** Opens the machine in this app. */
  async openMachine(id: string): Promise<void> {
    if (!this.client || !this.rows.has(id)) return;
    try {
      await this.client.call(BoardOps.open, { machine: id });
    } catch (error) {
      const now = this.rows.get(id);
      if (now) this.setRow(id, { ...now, refused: errorMessage(error) });
    }
  }

  // ---- publishing ----

  private setRow(id: string, view: RowView): void {
    this.rows.set(id, view);
    this.dirtyRows.add(id);
    this.markPage();
  }

  private refilter(): void {
    this.orderDirty = true;
    // A filter or search answers in the frame of the key press, not the next one.
    this.flush();
  }

  private markOrder(): void {
    this.orderDirty = true;
    this.markPage();
  }

  private markPage(): void {
    this.pageDirty = true;
    if (this.scheduled) return;
    this.scheduled = true;
    this.schedule(() => this.flush());
  }

  /** Publishes every change since the last flush: rows first, then the page. */
  flush(): void {
    this.scheduled = false;
    if (this.orderGone) {
      this.orderGone = false;
      this.order = this.order.filter((id) => this.rows.has(id));
      this.orderDirty = true;
    }
    if (this.orderDirty) {
      this.orderDirty = false;
      this.order.sort((a, b) => compareRows(this.rows.get(a)!.row, this.rows.get(b)!.row));
      const { filter } = this.state;
      const query = this.state.query.trim().toLowerCase();
      const visible =
        filter === "all" && !query
          ? this.order.slice()
          : this.order.filter((id) => matches(this.rows.get(id)!.row, filter, query, this.texts.get(id) ?? ""));
      this.state = { ...this.state, visible };
      this.pageDirty = true;
    }
    const dirty = this.dirtyRows;
    this.dirtyRows = new Set();
    for (const id of dirty) for (const listener of this.rowListeners.get(id) ?? []) listener();
    if (this.pageDirty) {
      this.pageDirty = false;
      this.publishState({ ...this.state, totals: { ...this.totals } });
    }
  }

  private publishState(state: BoardState) {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return String(error);
}
