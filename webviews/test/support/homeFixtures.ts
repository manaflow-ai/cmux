// A stand-in local conversation owner for the Home delta-read detectors and
// bench/page-delta-reads.bench.ts: 1,000 local conversations, answered as the daemon does
// (`conversation-list`, `home-inbox`, and `home-inbox` with `only` when it names
// `home-inbox-only-v1`), and `conversation-changed` events for a new message. It counts each
// command's calls and reply bytes (the JSON the socket would carry).
import type { DaemonSocket } from "../../src/pages/shared/daemonSocket";

type Json = Record<string, unknown>;

export interface CommandCount {
  calls: number;
  bytes: number;
}

const ME = { id: "user_local", kind: "human", name: "You" };

export class HomeDaemon {
  readonly counts = new Map<string, CommandCount>();
  private readonly listeners = new Set<(event: Json) => void>();
  private readonly seqs: number[];

  constructor(
    readonly size = 1000,
    private readonly capabilities = ["home-inbox-v1", "home-inbox-only-v1"],
  ) {
    this.seqs = Array.from({ length: size }, () => 1);
  }

  id(index: number): string {
    return `conv_${String(index).padStart(6, "0")}`;
  }

  private summary(index: number): Json {
    const seq = this.seqs[index];
    return {
      id: this.id(index),
      owner: "local",
      title: `Conversation ${index} about the build of the week`,
      participants: [ME, { id: `user_peer${index}`, kind: "human", name: `Peer ${index}` }],
      last_seq: seq,
      rev: seq,
      updated_at: new Date(1_790_000_000_000 - index * 60_000 + seq).toISOString(),
      created_at: new Date(1_780_000_000_000).toISOString(),
      read_cursors: { user_local: 1 },
      last_message: this.message(index, seq),
    };
  }

  private message(index: number, seq: number): Json {
    return {
      id: `msg_${index}_${seq}`,
      conversation: this.id(index),
      seq,
      author: `user_peer${index}`,
      created_at: new Date(1_790_000_000_000 + seq).toISOString(),
      parts: [{ type: "text", text: `message ${seq}: the preview is ready to open, all checks passed` }],
    };
  }

  private row(index: number): Json {
    return {
      id: this.id(index),
      owner: "local",
      kind: "direct",
      name: `Peer ${index}`,
      unread: this.seqs[index] - 1,
      preview: `message ${this.seqs[index]}`,
    };
  }

  count(cmd: string): CommandCount {
    let count = this.counts.get(cmd);
    if (!count) {
      count = { calls: 0, bytes: 0 };
      this.counts.set(cmd, count);
    }
    return count;
  }

  /** Calls and bytes of the reads that list conversations (whole or `only`). */
  listReads(): { whole: number; only: number; bytes: number; rows: number } {
    const whole = this.count("conversation-list");
    const only = this.count("home-inbox only");
    return {
      whole: whole.calls,
      only: only.calls,
      bytes: whole.bytes + this.count("home-inbox").bytes + only.bytes,
      rows: this.rowsSent,
    };
  }

  private rowsSent = 0;

  reset(): void {
    this.counts.clear();
    this.rowsSent = 0;
  }

  private answer(cmd: string, params: Json | undefined): unknown {
    switch (cmd) {
      case "identify":
        return { capabilities: this.capabilities };
      case "conversation-list":
        this.rowsSent += this.size;
        return { conversations: this.seqs.map((_, index) => this.summary(index)) };
      case "home-inbox": {
        const only = params?.only as string[] | undefined;
        if (only && this.capabilities.includes("home-inbox-only-v1")) {
          const indices = only.map((id) => Number(id.slice(5))).filter((index) => index < this.size);
          this.rowsSent += indices.length;
          return {
            me: "user_local",
            rows: indices.map((index) => this.row(index)),
            conversations: indices.map((index) => this.summary(index)),
            cloud: "not_asked",
          };
        }
        this.rowsSent += this.size;
        return { me: "user_local", rows: this.seqs.map((_, index) => this.row(index)), cloud: "not_asked" };
      }
      case "conversation-snapshot": {
        const index = Number(String(params?.conversation).slice(5));
        return { conversation: this.summary(index), messages: [this.message(index, this.seqs[index])], threads: [] };
      }
      default:
        return {};
    }
  }

  readonly socket = {
    request: async (cmd: string, params?: Json): Promise<unknown> => {
      const text = JSON.stringify(this.answer(cmd, params) ?? null);
      const name = cmd === "home-inbox" && params?.only ? "home-inbox only" : cmd;
      const count = this.count(name);
      count.calls += 1;
      count.bytes += text.length;
      return JSON.parse(text);
    },
    onEvent: (listener: (event: Json) => void) => {
      this.listeners.add(listener);
      return () => this.listeners.delete(listener);
    },
    onClose: () => () => {},
  } as unknown as DaemonSocket;

  /** A new message in conversation `index`: its summary and row change, and the owner says so. */
  post(index: number): void {
    this.seqs[index] += 1;
    const seq = this.seqs[index];
    const event = {
      event: "conversation-changed",
      conversation: this.id(index),
      rev: seq,
      change: { kind: "message", message: this.message(index, seq) },
    };
    for (const listener of this.listeners) listener(event);
  }
}
