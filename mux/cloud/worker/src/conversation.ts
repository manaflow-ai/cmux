import {
  parseClientFrame,
  type Conversation,
  type ID,
  type Message,
  type Part,
  type Participant,
  type ServerFrame,
} from "@mux/protocol";
import { DurableObject } from "cloudflare:workers";
import { account, mux, type Env } from "./env.ts";

/** Header the Worker sets on WebSocket upgrades after authenticating. */
export const VIEWER_HEADER = "x-mux-viewer";

/** One per conversation: participants, messages, live sockets, fan-out to muxes. */
export class ConversationDO extends DurableObject<Env> {
  private sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS participants (id TEXT PRIMARY KEY, json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS messages (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, json TEXT NOT NULL);
    `);
  }

  async init(id: ID, title: string, participants: Participant[]): Promise<Conversation> {
    this.sql.exec(
      "INSERT OR IGNORE INTO meta (key, value) VALUES ('id', ?), ('title', ?)",
      id,
      title,
    );
    for (const p of participants) {
      this.sql.exec(
        "INSERT OR IGNORE INTO participants (id, json) VALUES (?, ?)",
        p.id,
        JSON.stringify(p),
      );
    }
    const snapshot = this.snapshotSync();
    await this.publishSummary(snapshot);
    return snapshot;
  }

  async snapshot(): Promise<Conversation> {
    return this.snapshotSync();
  }

  async isMember(id: ID): Promise<boolean> {
    return this.sql.exec("SELECT 1 FROM participants WHERE id = ?", id).toArray().length > 0;
  }

  /** Appends a message from a participant, broadcasts it and wakes every other mux. */
  async post(senderId: ID, parts: Part[], clientId?: string): Promise<Message> {
    if (!(await this.isMember(senderId)))
      throw new Error(`${senderId} is not in this conversation`);
    const message: Message = {
      id: crypto.randomUUID(),
      senderId,
      sentAt: new Date().toISOString(),
      parts,
      reactions: [],
    };
    this.sql.exec(
      "INSERT INTO messages (id, json) VALUES (?, ?)",
      message.id,
      JSON.stringify(message),
    );
    this.broadcast({ type: "message", message, clientId });
    const snapshot = this.snapshotSync();
    this.ctx.waitUntil(this.publishSummary(snapshot));
    for (const p of snapshot.participants) {
      if (p.kind === "mux" && p.id !== senderId) {
        this.ctx.waitUntil(mux(this.env, p.id).receive(snapshot.id, message));
      }
    }
    return message;
  }

  async setTyping(participantId: ID, on: boolean): Promise<void> {
    this.broadcast({ type: "typing", participantId, on });
  }

  override async fetch(request: Request): Promise<Response> {
    const viewerId = request.headers.get(VIEWER_HEADER);
    if (request.headers.get("upgrade") !== "websocket" || !viewerId) {
      return new Response("expected websocket", { status: 426 });
    }
    if (!(await this.isMember(viewerId))) return new Response("not a participant", { status: 403 });
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [viewerId]);
    server.send(
      JSON.stringify({ type: "snapshot", conversation: this.snapshotSync() } satisfies ServerFrame),
    );
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const [viewerId] = this.ctx.getTags(ws);
    const frame = parseClientFrame(data);
    if (!viewerId || !frame) {
      ws.send(JSON.stringify({ type: "error", message: "bad frame" } satisfies ServerFrame));
      return;
    }
    if (frame.type === "send") await this.post(viewerId, frame.parts, frame.clientId);
    else await this.setTyping(viewerId, frame.on);
  }

  private broadcast(frame: ServerFrame): void {
    const text = JSON.stringify(frame);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(text);
      } catch {
        // Closed sockets drop out of getWebSockets on their own.
      }
    }
  }

  private snapshotSync(): Conversation {
    const meta = new Map(
      this.sql
        .exec<{ key: string; value: string }>("SELECT key, value FROM meta")
        .toArray()
        .map((r) => [r.key, r.value]),
    );
    return {
      id: meta.get("id") ?? "",
      title: meta.get("title") ?? "",
      participants: this.sql
        .exec<{ json: string }>("SELECT json FROM participants")
        .toArray()
        .map((r) => JSON.parse(r.json) as Participant),
      messages: this.sql
        .exec<{ json: string }>("SELECT json FROM messages ORDER BY seq")
        .toArray()
        .map((r) => JSON.parse(r.json) as Message),
    };
  }

  private async publishSummary(snapshot: Conversation): Promise<void> {
    const last = snapshot.messages.at(-1);
    const part = last?.parts[0];
    const summary = {
      id: snapshot.id,
      title: snapshot.title,
      preview: part?.type === "text" ? part.text : "",
      lastAt: last?.sentAt ?? new Date().toISOString(),
    };
    await Promise.all(
      snapshot.participants
        .filter((p) => p.kind === "human")
        .map((p) => account(this.env, p.id).upsertConversation(summary)),
    );
  }
}
