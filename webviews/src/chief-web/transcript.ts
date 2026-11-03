import type { AcpmuxRow } from "../agent-session/acpmux/model";

/** Topology changes notify the virtualizer; token changes notify only their mounted reply.
 * The committed prefix is copied only when committed rows or live run membership changes. */
export class ChiefTranscript {
  private committed: readonly AcpmuxRow[] = [];
  private live: readonly AcpmuxRow[] = [];
  private value: { rows: readonly AcpmuxRow[]; working: boolean } = { rows: [], working: false };
  private readonly listeners = new Set<() => void>();
  private readonly rowListeners = new Map<string, Set<() => void>>();
  private current = new Map<string, AcpmuxRow>();

  snapshot = () => this.value;
  row = (id: string) => this.current.get(id);
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  subscribeRow = (id: string, listener: () => void) => {
    let group = this.rowListeners.get(id);
    if (!group) this.rowListeners.set(id, (group = new Set()));
    group.add(listener);
    return () => {
      group.delete(listener);
      if (!group.size) this.rowListeners.delete(id);
    };
  };

  update = (committed: readonly AcpmuxRow[], live: readonly AcpmuxRow[]) => {
    const structural =
      committed !== this.committed ||
      live.length !== this.live.length ||
      live.some((row, i) => row.id !== this.live[i]?.id || row.streaming !== this.live[i]?.streaming);
    const previous = this.current;
    this.current = new Map(live.map((row) => [row.id, row]));
    this.committed = committed;
    this.live = live;
    if (structural) {
      this.value = { rows: [...committed, ...live], working: live.some((row) => row.streaming) };
      for (const listener of this.listeners) listener();
    }
    for (const id of new Set([...previous.keys(), ...this.current.keys()])) {
      if (previous.get(id) !== this.current.get(id)) {
        for (const listener of this.rowListeners.get(id) ?? []) listener();
      }
    }
  };
}
