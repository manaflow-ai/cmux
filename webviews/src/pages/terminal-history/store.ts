import { userMessage } from "../shared/userMessage";
import type {
  RawChunk,
  RawSection,
  TranscriptFindResult,
  TranscriptHit,
  TranscriptPage,
  TranscriptProvider,
  TranscriptTurn,
} from "./types";
import { hitTurn, TERMINAL_HISTORY_FIND, TERMINAL_HISTORY_PAGE } from "./types";

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
  searching: boolean;
  hasNewer: boolean;
  error?: string;
};

export class TerminalHistoryStore {
  private snapshot: HistorySnapshot = {
    title: "",
    turns: [],
    before: null,
    loading: true,
    loadingOlder: false,
    query: "",
    hits: [],
    searchBefore: null,
    searchComplete: true,
    searching: false,
    hasNewer: false,
  };
  private readonly listeners = new Set<() => void>();
  private completeThrough?: number;
  private searchThrough?: number;
  private generation = 0;
  private pageGeneration = 0;
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
      this.set({ loading: false, error: userMessage({ code: "unreachable" }) });
      return;
    }
    const generation = ++this.generation;
    const pageGeneration = ++this.pageGeneration;
    this.set({ loading: true, loadingOlder: false, error: undefined });
    try {
      let before: number | undefined;
      let through: number | undefined;
      let page: TranscriptPage | undefined;
      // A page can be empty when a large folded record occupies the whole slice. Walk
      // those cursors without making the reader parse the transcript prefix.
      for (let attempt = 0; attempt < 128; attempt += 1) {
        page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, {
          key: this.key,
          ...(before === undefined ? {} : { before, completeThrough: through }),
        });
        through = page.completeThrough ?? through;
        if (page.turns.length > 0 || page.rawRanges?.length || page.before === null || page.before === undefined) break;
        before = page.before;
      }
      if (!page) return;
      if (generation !== this.generation || pageGeneration !== this.pageGeneration) return;
      this.completeThrough = through;
      this.set({
        title: page.title || "",
        turns: withPageEnd(page),
        before: page.before,
        loading: false,
        hasNewer: false,
      });
    } catch (error) {
      if (generation === this.generation && pageGeneration === this.pageGeneration)
        this.set({ loading: false, error: userMessage(error) });
    }
  }

  async loadOlder(): Promise<void> {
    if (!this.provider || this.snapshot.before === null || this.snapshot.loadingOlder) return;
    const before = this.snapshot.before;
    const pageGeneration = this.pageGeneration;
    this.set({ loadingOlder: true });
    try {
      let cursor: number | null = before;
      let page: TranscriptPage | undefined;
      const olderTurns: TranscriptTurn[] = [];
      let through = this.completeThrough;
      for (let attempt = 0; attempt < 128 && cursor !== null; attempt += 1) {
        page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, {
          key: this.key,
          before: cursor,
          completeThrough: through,
        });
        through = page.completeThrough ?? through;
        olderTurns.push(...withPageEnd(page));
        cursor = page.before;
        if (olderTurns.length) break;
      }
      if (!page) return;
      if (this.pageGeneration !== pageGeneration || this.snapshot.before !== before) return;
      this.completeThrough = through;
      const merged = [...olderTurns, ...this.snapshot.turns];
      const turns = merged.slice(0, TerminalHistoryStore.MAX_VISIBLE_TURNS);
      this.set({
        turns,
        before: cursor,
        loadingOlder: false,
        // A result jump can leave a newer page behind the current cursor. Keep that
        // affordance while walking farther toward day one, even when the visible cap
        // does not evict any rows on this request.
        hasNewer: this.snapshot.hasNewer || merged.length > turns.length,
      });
    } catch (error) {
      if (this.pageGeneration === pageGeneration && this.snapshot.before === before)
        this.set({ loadingOlder: false, error: userMessage(error) });
    }
  }

  async find(query: string): Promise<void> {
    this.findAbort?.abort();
    const controller = new AbortController();
    this.findAbort = controller;
    const generation = ++this.findGeneration;
    this.searchThrough = undefined;
    this.set({ query, hits: [], searchBefore: null, searchComplete: true, searching: false });
    if (!this.provider || !query.trim()) return;
    await this.findPages(query, undefined, generation, controller.signal);
  }

  async continueFind(): Promise<void> {
    const { query, searchBefore, searching } = this.snapshot;
    if (searchBefore === null || searching || !this.findAbort) return;
    await this.findPages(query, searchBefore, this.findGeneration, this.findAbort.signal);
  }

  private async findPages(
    query: string,
    before: number | undefined,
    generation: number,
    signal: AbortSignal,
  ): Promise<void> {
    if (!this.provider) return;
    this.set({ searching: true });
    const hits: TranscriptHit[] = [];
    try {
      for (;;) {
        const result: TranscriptFindResult = await this.provider.call<TranscriptFindResult>(
          TERMINAL_HISTORY_FIND,
          { key: this.key, query, before, completeThrough: this.searchThrough },
          { signal },
        );
        if (generation !== this.findGeneration || signal.aborted) return;
        this.searchThrough = result.completeThrough ?? this.searchThrough;
        hits.push(...result.hits);
        const next = result.before ?? null;
        const done = next === null || next === before;
        if (result.hits.length || done)
          this.set({ hits: hits.slice(), searchBefore: done ? null : next, searchComplete: done });
        // Keep a whole RPC batch. Continuing replaces this bounded group with the next one.
        if (done || hits.length >= 128) return;
        before = next;
      }
    } catch (error) {
      if (generation === this.findGeneration && !signal.aborted) this.set({ error: userMessage(error) });
    } finally {
      if (generation === this.findGeneration) this.set({ searching: false });
    }
  }

  async readRaw(section: RawSection, offset: number): Promise<RawChunk> {
    if (!this.provider) throw new Error();
    return this.provider.call<RawChunk>(TERMINAL_HISTORY_PAGE, {
      key: this.key,
      before: section.pageEnd,
      completeThrough: section.completeThrough,
      rawStart: section.start,
      rawEnd: section.end,
      rawOffset: offset,
    });
  }

  async jumpToHit(hit: TranscriptHit): Promise<{ pageEnd: number; turn: number } | undefined> {
    if (!this.provider) return;
    const turnNumber = hitTurn(hit);
    const through = hit.role === "raw" ? (hit.completeThrough ?? this.searchThrough) : this.searchThrough;
    const current = this.snapshot.turns.find((turn) => turn.pageEnd === hit.pageEnd && turn.turnIndex === turnNumber);
    if (current) return { pageEnd: hit.pageEnd, turn: turnNumber };
    const pageGeneration = ++this.pageGeneration;
    this.set({ loading: false, loadingOlder: false });
    try {
      const page = await this.provider.call<TranscriptPage>(TERMINAL_HISTORY_PAGE, {
        key: this.key,
        before: hit.pageEnd,
        completeThrough: through,
      });
      if (pageGeneration !== this.pageGeneration) return undefined;
      this.completeThrough = page.completeThrough ?? through;
      this.set({ turns: withPageEnd(page), before: page.before, hasNewer: true });
      return { pageEnd: hit.pageEnd, turn: turnNumber };
    } catch (error) {
      if (pageGeneration === this.pageGeneration) this.set({ error: userMessage(error) });
      return undefined;
    }
  }

  async returnToLatest(): Promise<void> {
    await this.load();
  }

  async loadMore(turn: TranscriptTurn, role: "user" | "assistant"): Promise<void> {
    const offset = role === "user" ? turn?.promptMore : turn?.answerMore;
    if (!this.provider || turn?.pageEnd === undefined || turn.turnIndex === undefined || offset === undefined) return;
    try {
      const pageEnd = turn.pageEnd;
      const rpcTurn = turn.turnIndex;
      const result = await this.provider.call<{ text: string; nextOffset: number | null }>(TERMINAL_HISTORY_PAGE, {
        key: this.key,
        before: pageEnd,
        completeThrough: this.completeThrough,
        turn: rpcTurn,
        role,
        offset,
      });
      const rowIndex = this.snapshot.turns.findIndex((item) => item.pageEnd === pageEnd && item.turnIndex === rpcTurn);
      const latest = rowIndex < 0 ? undefined : this.snapshot.turns[rowIndex];
      const currentOffset = role === "user" ? latest?.promptMore : latest?.answerMore;
      if (!latest || currentOffset !== offset) return;
      const turns = [...this.snapshot.turns];
      const next = { ...latest };
      if (role === "user") {
        next.prompt += result.text;
        next.promptMore = result.nextOffset ?? undefined;
      } else {
        next.answer += result.text;
        next.answerMore = result.nextOffset ?? undefined;
      }
      turns[rowIndex] = next;
      this.set({ turns });
    } catch (error) {
      this.set({ error: userMessage(error) });
    }
  }
}

function withPageEnd(page: TranscriptPage): TranscriptTurn[] {
  const turns = page.turns.map((turn, turnIndex) =>
    page.pageEnd === undefined ? { ...turn, turnIndex } : { ...turn, pageEnd: page.pageEnd, turnIndex },
  );
  if (page.pageEnd === undefined || !page.rawRanges?.length) return turns;
  const raw = page.rawRanges.map((range) => ({
    prompt: "",
    answer: "",
    tools: [],
    pageEnd: page.pageEnd!,
    turnIndex: -1 - range.start,
    raw: { ...range, pageEnd: page.pageEnd!, completeThrough: page.completeThrough },
  }));
  return [
    ...raw.filter((row) => row.raw.position === "before"),
    ...turns,
    ...raw.filter((row) => row.raw.position === "after"),
  ];
}
