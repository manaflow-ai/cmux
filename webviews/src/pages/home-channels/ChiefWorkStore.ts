// An opened Chief work panel reads one authoritative snapshot. No poll or transcript inference:
// Refresh asks the same owner again. A closed/replaced panel cannot receive an old Chief's answer.
import type { PageClient } from "../shared/pageClient";
import { HomeOps } from "./types";
import type { HomeChiefWork } from "./chiefWorkTypes";

export interface ChiefWorkSnapshot {
  chief?: string;
  snapshot?: HomeChiefWork;
  loading: boolean;
  failed: boolean;
}

export class ChiefWorkStore {
  private state: ChiefWorkSnapshot = { loading: false, failed: false };
  private readonly listeners = new Set<() => void>();
  private generation = 0;

  constructor(private readonly client: PageClient | null) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.state;

  /** Showing a different Chief drops every previous row before the read starts. */
  select(chief?: string): void {
    if (chief === this.state.chief) return;
    this.generation++;
    this.set({ chief, loading: false, failed: false });
    if (chief) void this.refresh();
  }

  /** One in-flight read; a failed refresh keeps the last snapshot visibly stale. */
  refresh = async (): Promise<void> => {
    const { chief, loading } = this.state;
    if (!chief || loading) return;
    const generation = ++this.generation;
    this.set({ ...this.state, loading: true, failed: false });
    try {
      if (!this.client) throw new Error("unavailable");
      const snapshot = await this.client.call<HomeChiefWork>(HomeOps.chiefWork, { chief });
      if (generation === this.generation) this.set({ chief, snapshot, loading: false, failed: false });
    } catch {
      if (generation === this.generation) this.set({ ...this.state, loading: false, failed: true });
    }
  };

  private set(state: ChiefWorkSnapshot): void {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
