import type { TranscriptFindResult, TranscriptHit, TranscriptPage, TranscriptProvider, TranscriptTurn } from "./types";
import { TERMINAL_HISTORY_FIND, TERMINAL_HISTORY_PAGE } from "./types";

export type HistorySnapshot = {
  title: string;
  turns: TranscriptTurn[];
  before: number | null;
  loading: boolean;
  loadingOlder: boolean;
  query: string;
  hits: TranscriptHit[];
  hasNewer: boolean;
  error?: string;
};

export class TerminalHistoryStore {
  private snapshot: HistorySnapshot = {
    title: "Terminal agent history",
    turns: [],
    before: null,
    loading: true,
    loadingOlder: false,
    query: "",
    hits: [],
    hasNewer: false,
  };
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private findGeneration = 0;
  private findAbort?: AbortController;

  private static readonly MAX_VISIBLE_TURNS = 360;

  constructor(private readonly provider: TranscriptProvider | null, readonly key: string) {}

  getSnapshot = (): HistorySnapshot => this.snapshot;
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(patch: Partial<HistorySnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    this.listeners.forEach((listener) => listener());
  }

  async load(): Promise<void> {
    if (!this.provider) {
      this.set({ loading: false, error: "Transcript history is unavailable." });
      return;
    }
    const generation = ++this.generation;
    this.set({ loading: true, error: undefined });
    try {
      const page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, { key: this.key });
      if (generation !== this.generation) return;
      this.set({ title: page.title || "Terminal agent history", turns: page.turns, before: page.before, loading: false, hasNewer: false });
    } catch {
      if (generation === this.generation) this.set({ loading: false, error: "Couldn’t load this transcript." });
    }
  }

  async loadOlder(): Promise<void> {
    if (!this.provider || this.snapshot.before === null || this.snapshot.loadingOlder) return;
    const before = this.snapshot.before;
    this.set({ loadingOlder: true });
    try {
      const page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, { key: this.key, before });
      if (this.snapshot.before !== before) return;
      const merged = [...page.turns, ...this.snapshot.turns];
      const turns = merged.slice(0, TerminalHistoryStore.MAX_VISIBLE_TURNS);
      this.set({ turns, before: page.before, loadingOlder: false, hasNewer: merged.length > turns.length });
    } catch {
      this.set({ loadingOlder: false, error: "Couldn’t load earlier transcript pages." });
    }
  }

  async find(query: string): Promise<void> {
    this.findAbort?.abort();
    const controller = new AbortController();
    this.findAbort = controller;
    const generation = ++this.findGeneration;
    this.set({ query, hits: [] });
    if (!this.provider || !query.trim()) return;
    try {
      let before: number | undefined;
      const hits: TranscriptHit[] = [];
      // Search in bounded pages. A stale query aborts the in-flight call and never updates the page.
      for (let page = 0; page < 128; page += 1) {
        const result = await this.provider.call<TranscriptFindResult>(TERMINAL_HISTORY_FIND, {
          key: this.key,
          query,
          ...(before === undefined ? {} : { before }),
        }, { signal: controller.signal });
        hits.push(...result.hits);
        if (result.before === null || result.before === undefined) break;
        before = result.before;
      }
      if (generation === this.findGeneration && this.snapshot.query === query) this.set({ hits });
    } catch {
      if (!controller.signal.aborted && generation === this.findGeneration) this.set({ error: "Couldn’t search this transcript." });
    }
  }

  async jumpToHit(hit: TranscriptHit): Promise<void> {
    if (!this.provider) return;
    const currentText = this.snapshot.turns.some((turn) => includesHit(turn, hit.snippet));
    if (currentText) return;
    try {
      const page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, { key: this.key, before: hit.pageEnd });
      const merged = [...page.turns, ...this.snapshot.turns];
      const turns = merged.slice(0, TerminalHistoryStore.MAX_VISIBLE_TURNS);
      this.set({ turns, before: page.before, hasNewer: merged.length > turns.length });
    } catch {
      this.set({ error: "Couldn’t open that transcript result." });
    }
  }

  async returnToLatest(): Promise<void> {
    await this.load();
  }
}

function includesHit(turn: TranscriptTurn, snippet: string): boolean {
  const text = `${turn.prompt}\n${turn.answer}`.toLocaleLowerCase();
  return text.includes(snippet.toLocaleLowerCase());
}
