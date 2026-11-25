// l10n-allow-file: public-safe fixtures for the browser dev loop.
// An in-memory forum for the browser dev loop (`/forum/?mock`) and tests. It is not the backend:
// the daemon's forum owner (cmux-tui-core server/forum_routed.rs) reads the hosted forum. The mock
// answers the same four ops from the gallery's sample snapshot.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import { sampleSnapshot } from "./fixtures";
import { ForumOps } from "./store";
import type { ForumComment, ForumSnapshot, ForumThread, ForumThreadKind } from "./types";

export class MockForumProvider implements PageClient {
  readonly calls: Array<{ op: string; params: unknown }> = [];
  readonly page = new MockPageStreams();
  private nextComment = 1000;

  constructor(private readonly data: ForumSnapshot = sampleSnapshot()) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    const args = (params ?? {}) as {
      number?: number;
      body?: string;
      space?: string;
      title?: string;
      kind?: ForumThreadKind;
    };
    switch (op) {
      case ForumOps.snapshot:
        return { ...structuredClone(this.data), comments: {} } as R;
      case ForumOps.thread: {
        const thread = this.data.threads.find((t) => t.number === args.number);
        if (!thread) throw pageError("cmux.operation.failed", "no such thread");
        return { thread, comments: this.data.comments[thread.number] ?? [] } as R;
      }
      case ForumOps.reply: {
        const thread = this.data.threads.find((t) => t.number === args.number);
        if (!thread) throw pageError("cmux.operation.failed", "no such thread");
        const comment: ForumComment = {
          id: this.nextComment++,
          thread: thread.number,
          body: args.body ?? "",
          author: { kind: "person", id: "u_me", name: "You" },
          created_at: Date.now(),
        };
        this.data.comments[thread.number] = [...(this.data.comments[thread.number] ?? []), comment];
        thread.comments += 1;
        thread.updated_at = comment.created_at;
        return { comment, thread } as R;
      }
      case ForumOps.post: {
        const number = Math.max(0, ...this.data.threads.map((t) => t.number)) + 1;
        const thread: ForumThread = {
          number,
          title: args.title ?? "",
          body: args.body ?? "",
          state: "open",
          kind: args.kind ?? "question",
          labels: [],
          author: { kind: "person", id: "u_me", name: "You" },
          space: args.space ?? "general",
          comments: 0,
          created_at: Date.now(),
          updated_at: Date.now(),
        };
        this.data.threads.unshift(thread);
        return { thread } as R;
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    throw pageError("cmux.protocol.unknown_op", stream);
  }

  /** The page serves no ops to its host; kept for the interface. */
  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }
}
