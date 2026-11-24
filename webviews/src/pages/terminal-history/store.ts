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
  searchBefore: number | null;
  searchComplete: boolean;
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
    searchBefore: null,
    searchComplete: true,
    hasNewer: false,
  };
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private findGeneration = 0;
  private findAbort?: AbortController;

  private static readonly MAX_VISIBLE_TURNS = 360;

  constructor(
    private readonly provider: TranscriptProvider | null,
    readonly key: string,
  ) {}

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
      this.set({
        title: page.title || "Terminal agent history",
        turns: withPageEnd(page),
        before: page.before,
        loading: false,
        hasNewer: false,
      });
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
      const merged = [...withPageEnd(page), ...this.snapshot.turns];
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
    this.set({ query, hits: [], searchBefore: null, searchComplete: true });
    if (!this.provider || !query.trim()) return;
    try {
      await this.findPages(query, undefined, generation, controller.signal, []);
    } catch {
      if (!controller.signal.aborted && generation === this.findGeneration)
        this.set({ error: "Couldn’t search this transcript." });
    }
  }

  async continueFind(): Promise<void> {
    const { query, searchBefore } = this.snapshot;
    if (!query.trim() || searchBefore === null || this.snapshot.searchComplete) return;
    this.findAbort?.abort();
    const controller = new AbortController();
    this.findAbort = controller;
    const generation = ++this.findGeneration;
    try {
      await this.findPages(query, searchBefore, generation, controller.signal, this.snapshot.hits);
    } catch {
      if (!controller.signal.aborted && generation === this.findGeneration)
        this.set({ error: "Couldn’t search this transcript." });
    }
  }

  private async findPages(
    query: string,
    startBefore: number | undefined,
    generation: number,
    signal: AbortSignal,
    existing: TranscriptHit[],
  ): Promise<void> {
    const provider = this.provider;
    if (!provider) return;
    let before = startBefore;
    const hits: TranscriptHit[] = [];
    let previousBefore: number | undefined;
    const maxHits = 2_000;
    // Search every page. A stale query aborts the in-flight call and never updates the page.
    for (;;) {
      const result = await provider.call<TranscriptFindResult>(
        TERMINAL_HISTORY_FIND,
        {
          key: this.key,
          query,
          ...(before === undefined ? {} : { before }),
        },
        { signal },
      );
      hits.push(...result.hits);
      if (hits.length + existing.length >= maxHits) {
        const capped = [...existing, ...hits].slice(0, maxHits);
        this.set({
          hits: capped,
          searchBefore: result.before,
          searchComplete: result.before === null || result.before === undefined,
        });
        return;
      }
      if (result.before === null || result.before === undefined || result.before === previousBefore) {
        const all = [...existing, ...hits];
        if (generation === this.findGeneration && this.snapshot.query === query)
          this.set({ hits: all, searchBefore: null, searchComplete: true });
        return;
      }
      previousBefore = result.before;
      before = result.before;
    }
  }

  async jumpToHit(hit: TranscriptHit): Promise<void> {
    if (!this.provider) return;
    const currentText = this.snapshot.turns.some((turn) => includesHit(turn, hit.snippet));
    if (currentText) return;
    try {
      const page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, {
        key: this.key,
        before: hit.pageEnd,
      });
      this.set({ turns: withPageEnd(page), before: page.before, hasNewer: true });
    } catch {
      this.set({ error: "Couldn’t open that transcript result." });
    }
  }

  async returnToLatest(): Promise<void> {
    await this.load();
  }

  async loadMore(turnIndex: number, role: "user" | "assistant"): Promise<void> {
    const turn = this.snapshot.turns[turnIndex];
    const offset = role === "user" ? turn?.promptMore : turn?.answerMore;
    if (!this.provider || !turn?.pageEnd || offset === undefined) return;
    try {
      const result = await this.provider.call<{ text: string; nextOffset: number | null }>(TERMINAL_HISTORY_PAGE, {
        key: this.key,
        before: turn.pageEnd,
        turn: turnIndex,
        role,
        offset,
      });
      const turns = [...this.snapshot.turns];
      const next = { ...turn };
      if (role === "user") {
        next.prompt += result.text;
        next.promptMore = result.nextOffset ?? undefined;
      } else {
        next.answer += result.text;
        next.answerMore = result.nextOffset ?? undefined;
      }
      turns[turnIndex] = next;
      this.set({ turns });
    } catch {
      this.set({ error: "Couldn’t load the rest of this turn." });
    }
  }
}

function withPageEnd(page: TranscriptPage): TranscriptTurn[] {
  return page.turns.map((turn) => (page.pageEnd === undefined ? turn : { ...turn, pageEnd: page.pageEnd }));
}

function includesHit(turn: TranscriptTurn, snippet: string): boolean {
  const text = `${turn.prompt}\n${turn.answer}`.toLocaleLowerCase();
  return text.includes(snippet.toLocaleLowerCase());
}
