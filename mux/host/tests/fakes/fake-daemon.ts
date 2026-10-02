import { createServer, type Server, type Socket } from "node:net";
import type { Message, Op, Participant, PartRef, Summary, TextRun } from "../../src/conversation-types.ts";

// A fake cmux daemon that speaks home.md section 2 over a Unix socket: the
// v2 line framing ({"id":N,"cmd":...} -> {"id":N,"ok":...}), identify with
// capabilities, subscribe {"tree_events":"deltas"} then {"event":...} lines,
// and an in-memory local conversation owner (seq, rev, op ledger, monotonic
// read cursors, typing broadcast). Tests read `requests` and `typing`.

export interface Request {
  id: number;
  cmd: string;
  [key: string]: unknown;
}

class Reject extends Error {}

interface Conversation {
  summary: Summary;
  messages: Message[];
  ledger: Map<string, { fingerprint: string; result: unknown }>;
}

export class FakeDaemon {
  readonly requests: Request[] = [];
  readonly typing: { conversation: string; actor: string; on: boolean }[] = [];
  capabilities = ["local-conversations-v1"];
  private server!: Server;
  private readonly clients = new Set<Socket>();
  private readonly subscribers = new Set<Socket>();
  private readonly conversations = new Map<string, Conversation>();
  private readonly createKeys = new Map<string, string>();
  private nextConv = 1;
  private nextMsg = 1;
  private listeners: (() => void)[] = [];

  constructor(readonly path: string) {}

  async start(): Promise<void> {
    this.server = createServer((socket) => this.accept(socket));
    await new Promise<void>((resolve) => this.server.listen(this.path, resolve));
  }

  async stop(): Promise<void> {
    this.dropClients();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  /** Ends every connection (a daemon restart, from the client's side). */
  dropClients(): void {
    for (const socket of this.clients) socket.destroy();
    this.clients.clear();
    this.subscribers.clear();
  }

  get subscriberCount(): number {
    return this.subscribers.size;
  }

  /** Resolves when `predicate` holds (checked after every request and op). */
  until(predicate: () => boolean): Promise<void> {
    if (predicate()) return Promise.resolve();
    return new Promise((resolve) => {
      const check = () => {
        if (!predicate()) return;
        this.listeners = this.listeners.filter((l) => l !== check);
        resolve();
      };
      this.listeners.push(check);
    });
  }

  conversation(id: string): Conversation {
    const c = this.conversations.get(id);
    if (!c) throw new Error(`no conversation ${id}`);
    return c;
  }

  get conversationIds(): string[] {
    return [...this.conversations.keys()];
  }

  /** A client (the app) creates a conversation directly. */
  createConversation(title: string, participants: Participant[]): string {
    return (this.handle({ id: 0, cmd: "conversation-create", idempotency_key: `t-${title}`, actor: participants[0].id, title, participants }) as { conversation: Summary }).conversation.id;
  }

  /** A client (the app) sends a text message as `actor`. */
  send(conversation: string, actor: string, text: string, extra: { runs?: TextRun[]; reply_to?: PartRef } = {}): Message {
    const key = `client-${this.nextMsg}-${Math.random().toString(36).slice(2)}`;
    const result = this.handle({
      id: 0,
      cmd: "conversation-op",
      conversation,
      idempotency_key: key,
      actor,
      op: {
        kind: "message.send",
        client_msg_id: key,
        parts: [{ type: "text", text, ...(extra.runs ? { runs: extra.runs } : {}) }],
        ...(extra.reply_to ? { reply_to: extra.reply_to } : {}),
      },
    }) as { change: { message: Message } };
    this.notify();
    return result.change.message;
  }

  messages(conversation: string): Message[] {
    return this.conversation(conversation).messages;
  }

  private accept(socket: Socket): void {
    this.clients.add(socket);
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      for (let nl = buffer.indexOf("\n"); nl >= 0; nl = buffer.indexOf("\n")) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (!line.trim()) continue;
        const request = JSON.parse(line) as Request;
        this.requests.push(request);
        let reply: unknown;
        try {
          const data = request.cmd === "subscribe" ? this.subscribe(socket, request) : this.handle(request);
          reply = { id: request.id, ok: true, data };
        } catch (error) {
          reply = {
            id: request.id,
            ok: false,
            error: (error as Error).message,
            error_code: error instanceof Reject ? "conversation_rejected" : "bad_request",
          };
        }
        if (!socket.destroyed) socket.write(`${JSON.stringify(reply)}\n`);
        this.notify();
      }
    });
    socket.on("close", () => {
      this.clients.delete(socket);
      this.subscribers.delete(socket);
    });
    socket.on("error", () => {});
  }

  private notify(): void {
    for (const listener of [...this.listeners]) listener();
  }

  private subscribe(socket: Socket, request: Request): unknown {
    if (request.tree_events !== "deltas") throw new Error("expected tree_events deltas");
    this.subscribers.add(socket);
    return {};
  }

  private publish(event: Record<string, unknown>): void {
    const line = `${JSON.stringify(event)}\n`;
    // After the reply line, like the real daemon (events follow the commit).
    queueMicrotask(() => {
      for (const socket of this.subscribers) if (!socket.destroyed) socket.write(line);
    });
  }

  private handle(request: Request): unknown {
    switch (request.cmd) {
      case "identify":
        return { app: "fake-daemon", version: "0.0.0", protocol: 2, capabilities: this.capabilities, session: "test", pid: process.pid };
      case "conversation-list":
        return {
          conversations: [...this.conversations.values()]
            .map((c) => c.summary)
            .sort((a, b) => b.updated_at.localeCompare(a.updated_at)),
        };
      case "conversation-create":
        return this.create(request);
      case "conversation-snapshot": {
        const c = this.get(request.conversation);
        const tail = Math.min(Math.max(Number(request.tail ?? 50), 1), 500);
        return { conversation: c.summary, messages: c.messages.slice(-tail) };
      }
      case "conversation-history": {
        const c = this.get(request.conversation);
        const before = Number(request.before_seq);
        const limit = Math.min(Math.max(Number(request.limit ?? 50), 1), 500);
        return { messages: c.messages.filter((m) => m.seq < before).slice(-limit) };
      }
      case "conversation-op":
        return this.op(request);
      case "conversation-typing": {
        const c = this.get(request.conversation);
        const actor = String(request.actor);
        if (!c.summary.participants.some((p) => p.id === actor)) throw new Reject("not_participant");
        this.typing.push({ conversation: c.summary.id, actor, on: request.on === true });
        this.publish({ event: "conversation-typing", conversation: c.summary.id, participant: actor, on: request.on === true });
        return {};
      }
      default:
        throw new Error(`unknown command ${request.cmd}`);
    }
  }

  private get(id: unknown): Conversation {
    const c = this.conversations.get(String(id));
    if (!c) throw new Reject("unknown_conversation");
    return c;
  }

  private create(request: Request): unknown {
    const key = String(request.idempotency_key);
    const existing = this.createKeys.get(key);
    if (existing) return { conversation: this.get(existing).summary, replayed: true };
    const now = new Date().toISOString();
    const id = `conv_${String(this.nextConv++).padStart(26, "0")}`;
    const summary: Summary = {
      id,
      owner: "local",
      title: String(request.title),
      participants: request.participants as Participant[],
      last_seq: 0,
      rev: 1,
      created_at: now,
      updated_at: now,
      read_cursors: {},
    };
    this.conversations.set(id, { summary, messages: [], ledger: new Map() });
    this.createKeys.set(key, id);
    return { conversation: summary, replayed: false };
  }

  private op(request: Request): unknown {
    const c = this.get(request.conversation);
    const actor = String(request.actor);
    const key = String(request.idempotency_key);
    const op = request.op as Op;
    const fingerprint = JSON.stringify({ actor, op });
    const stored = c.ledger.get(key);
    if (stored) {
      if (stored.fingerprint !== fingerprint) throw new Reject("idempotency_conflict");
      return { ...(stored.result as object), replayed: true };
    }
    if (!c.summary.participants.some((p) => p.id === actor)) throw new Reject("not_participant");
    const now = new Date().toISOString();
    let change: Record<string, unknown>;
    let seq: number | undefined;
    switch (op.kind) {
      case "message.send": {
        if (key !== op.client_msg_id) throw new Reject("invalid_parts: idempotency_key must equal client_msg_id");
        if (op.parts.length < 1 || op.parts.length > 16) throw new Reject("invalid_parts");
        seq = c.summary.last_seq + 1;
        const message: Message = {
          id: `msg_${this.nextMsg++}`,
          conversation: c.summary.id,
          seq,
          client_msg_id: op.client_msg_id,
          author: actor,
          parts: op.parts,
          ...(op.reply_to ? { reply_to: op.reply_to } : {}),
          created_at: now,
          reactions: [],
        };
        c.messages.push(message);
        c.summary.last_seq = seq;
        c.summary.last_message = message;
        change = { kind: "message", message };
        break;
      }
      case "message.edit": {
        const message = c.messages.find((m) => m.id === op.message_id);
        if (!message) throw new Reject("unknown_message");
        if (message.author !== actor) throw new Reject("not_author");
        message.parts = op.parts;
        message.edited_at = now;
        change = { kind: "message-updated", message };
        break;
      }
      case "read_cursor.set": {
        const current = c.summary.read_cursors[actor] ?? 0;
        if (op.seq < current || op.seq > c.summary.last_seq) throw new Reject("cursor_regression");
        c.summary.read_cursors[actor] = op.seq;
        change = { kind: "read-cursor", participant: actor, seq: op.seq };
        break;
      }
      case "participants.add": {
        c.summary.participants.push(op.participant);
        change = { kind: "conversation", conversation: c.summary };
        break;
      }
      default:
        throw new Reject(`unsupported op ${op.kind}`);
    }
    c.summary.rev += 1;
    c.summary.updated_at = now;
    const result = { rev: c.summary.rev, ...(seq ? { seq } : {}), change };
    c.ledger.set(key, { fingerprint, result });
    this.publish({ event: "conversation-changed", conversation: c.summary.id, rev: c.summary.rev, change: structuredClone(change) });
    return { ...result, replayed: false };
  }
}
