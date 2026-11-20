import type { PageClient } from "../shared/pageClient";
import { MARKDOWN_REVEAL_SOURCE_USE_OP, MARKDOWN_SOURCE_USES_OP } from "./host";

export interface SourceUse {
  seq: number;
  at: number;
  turnId: string;
  replyId: string;
  toolCallId: string;
  kind: string;
  uri: string;
  revision?: string;
  title?: string;
}

export interface SourceUsesPage {
  sessionId: string;
  uri: string;
  uses: SourceUse[];
  nextCursor: string | null;
}

export type SourceUsesClient = Pick<PageClient, "call">;
export const MAX_SOURCE_USES = 1000;
export interface SourceUsesState {
  loaded: boolean;
  loading: boolean;
  uses: readonly SourceUse[];
  nextCursor: string | null;
  error: boolean;
  revealing: boolean;
  revealError: boolean;
  capped: boolean;
}

const initial = (): SourceUsesState => ({
  loaded: false,
  loading: false,
  uses: [],
  nextCursor: null,
  error: false,
  revealing: false,
  revealError: false,
  capped: false,
});

/** Presentation state only. The native host owns the chat, query and reveal authorization. */
export class SourceUses {
  private state = initial();
  private generation = 0;
  private pending?: AbortController;
  private revealing?: AbortController;
  private listeners = new Set<() => void>();
  constructor(
    private readonly client: SourceUsesClient,
    private path: string | undefined,
  ) {}

  getState = (): SourceUsesState => this.state;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  private set(change: Partial<SourceUsesState>) {
    this.state = { ...this.state, ...change };
    for (const listener of this.listeners) listener();
  }

  setDocument(path: string | undefined) {
    this.generation += 1;
    this.pending?.abort();
    this.revealing?.abort();
    this.path = path;
    this.set(initial());
  }

  dispose() {
    this.setDocument(undefined);
    this.listeners.clear();
  }

  /** A click opens the first page, retries a failed page or advances its opaque cursor. */
  async load(): Promise<void> {
    const path = this.path;
    if (!path || this.state.loading || (this.state.loaded && this.state.nextCursor === null)) return;
    const generation = this.generation;
    const cursor = this.state.loaded ? this.state.nextCursor : undefined;
    const pending = new AbortController();
    this.pending = pending;
    this.set({ loading: true, error: false });
    try {
      const page = await this.client.call<SourceUsesPage>(
        MARKDOWN_SOURCE_USES_OP,
        { path, ...(cursor && { cursor }) },
        { signal: pending.signal },
      );
      if (generation !== this.generation) return;
      if (
        !Array.isArray(page.uses) ||
        (page.nextCursor !== null && (typeof page.nextCursor !== "string" || !page.nextCursor))
      ) {
        throw new Error("Invalid source-use page");
      }
      const known = new Set(this.state.uses.map((use) => `${use.seq}:${use.replyId}:${use.toolCallId}`));
      const uses = [...this.state.uses];
      let consumed = 0;
      for (const use of page.uses.slice(0, MAX_SOURCE_USES)) {
        if (uses.length === MAX_SOURCE_USES) break;
        consumed += 1;
        const key = `${use.seq}:${use.replyId}:${use.toolCallId}`;
        if (!known.has(key)) {
          known.add(key);
          uses.push(use);
        }
      }
      const capped = consumed < page.uses.length || (uses.length === MAX_SOURCE_USES && page.nextCursor !== null);
      this.set({
        uses,
        loaded: true,
        loading: false,
        capped,
        nextCursor: uses.length === MAX_SOURCE_USES || capped ? null : page.nextCursor,
      });
    } catch {
      if (generation === this.generation) this.set({ loading: false, error: true });
    }
  }

  async reveal(use: SourceUse): Promise<void> {
    const path = this.path;
    if (!path || this.state.revealing || !this.state.uses.includes(use)) return;
    const generation = this.generation;
    const pending = new AbortController();
    this.revealing = pending;
    this.set({ revealing: true, revealError: false });
    try {
      // The originating session is captured by the host, never selected from a document or response.
      await this.client.call(
        MARKDOWN_REVEAL_SOURCE_USE_OP,
        { path, replyId: use.replyId, turnId: use.turnId },
        { signal: pending.signal },
      );
      if (generation === this.generation) this.set({ revealing: false });
    } catch {
      if (generation === this.generation) this.set({ revealing: false, revealError: true });
    }
  }
}
