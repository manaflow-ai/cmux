// The Forum page's state on the page side: the daemon's `forum.snapshot` (spaces and threads) and
// `forum.thread.get` (a thread with its comments), and the intents that post and reply
// (`forum.thread.post`, `forum.thread.reply`, the person's gesture). The daemon does the work
// (cmux-tui-core server/forum_routed.rs over cmux-forum-hosted); this keeps no optimistic copy: a
// post or reply re-reads after the daemon answers.
import type { PageClient } from "../shared/pageClient";
import { userMessage } from "../shared/userMessage";
import type { ForumComment, ForumSnapshot, ForumThread, ForumThreadKind } from "./types";

export const ForumOps = {
  snapshot: "cmux.forum.snapshot",
  thread: "cmux.forum.thread.get",
  post: "cmux.forum.thread.post",
  reply: "cmux.forum.thread.reply",
} as const;

export type ForumStoreState = {
  snapshot: ForumSnapshot;
  /** The last failed call's message, until the next good read. */
  error?: string;
};

const empty = (status: ForumSnapshot["status"]): ForumSnapshot => ({
  status,
  team: "",
  feed: "live",
  spaces: [],
  threads: [],
  comments: {},
});

export class ForumStore {
  private state: ForumStoreState;
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private readonly newKey: () => string;

  constructor(
    private readonly client: PageClient | null,
    options: { newKey?: () => string } = {},
  ) {
    this.newKey = options.newKey ?? (() => crypto.randomUUID());
    this.state = { snapshot: empty(client ? "loading" : "off") };
  }

  getState = (): ForumStoreState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.reload();
    return () => {
      this.listeners.delete(listener);
    };
  };

  private set(next: Partial<ForumStoreState>): void {
    this.state = { ...this.state, ...next };
    for (const listener of this.listeners) listener();
  }

  /** Reads the spaces and threads; keeps the comments already read. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const read = await this.client.call<ForumSnapshot>(ForumOps.snapshot, {});
      if (generation !== this.generation) return;
      const comments = read.status === "ready" ? this.state.snapshot.comments : {};
      this.set({ snapshot: { ...read, comments: { ...comments, ...read.comments } }, error: undefined });
    } catch (error) {
      if (generation !== this.generation) return;
      const shown = this.state.snapshot.status === "loading" ? empty("ready") : this.state.snapshot;
      this.set({ snapshot: { ...shown, feed: "offline" }, error: userMessage(error) });
    }
  }

  /** Reads one thread and its comments into the snapshot. */
  async openThread(number: number): Promise<void> {
    if (!this.client) return;
    try {
      const read = await this.client.call<{ thread: ForumThread; comments: ForumComment[] }>(ForumOps.thread, {
        number,
      });
      this.merge(read.thread, read.comments);
    } catch (error) {
      this.set({ error: userMessage(error) });
    }
  }

  async reply(number: number, body: string): Promise<void> {
    if (!this.client || !body.trim()) return;
    try {
      await this.client.call(ForumOps.reply, { number, body, idempotency_key: this.newKey() });
      await this.openThread(number);
    } catch (error) {
      this.set({ error: userMessage(error) });
    }
  }

  async post(draft: { space: string; kind: ForumThreadKind; title: string; body: string }): Promise<number | null> {
    if (!this.client) return null;
    try {
      const reply = await this.client.call<{ thread: ForumThread }>(ForumOps.post, {
        ...draft,
        idempotency_key: this.newKey(),
      });
      this.merge(reply.thread, []);
      await this.reload();
      return reply.thread.number;
    } catch (error) {
      this.set({ error: userMessage(error) });
      return null;
    }
  }

  private merge(thread: ForumThread, comments: ForumComment[]): void {
    const snapshot = this.state.snapshot;
    const others = snapshot.threads.filter((t) => t.number !== thread.number);
    this.set({
      snapshot: {
        ...snapshot,
        threads: [thread, ...others],
        comments: { ...snapshot.comments, [thread.number]: comments },
      },
    });
  }
}
