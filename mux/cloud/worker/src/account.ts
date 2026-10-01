import type {
  ConversationSummary,
  ID,
  LinkDownFrame,
  LinkEvent,
  LinkMethod,
  LinkMethods,
  LinkUpFrame,
  MachineInfo,
  Viewer,
} from "@mux/protocol";
import { DurableObject } from "cloudflare:workers";
import { mux, type Env } from "./env.ts";
import { ensureVm } from "./freestyle.ts";

/** Header the Worker sets on link WebSocket upgrades after checking the token. */
export const LINK_HEADER = "x-mux-link";

const CALL_TIMEOUT_MS = 30_000;

export interface Machine extends MachineInfo {
  online: boolean;
  lastSeen: string;
}

/** Who asked for an agent, so its events go back to that mux and conversation. */
export interface AgentOrigin {
  muxId: ID;
  conversationId: ID;
}

interface PendingCall {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

/** One per human: profile, conversation list, default mux, and their machines' links. */
export class AccountDO extends DurableObject<Env> {
  private sql = this.ctx.storage.sql;
  private nextCallId = 1;
  private calls = new Map<number, PendingCall>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, preview TEXT NOT NULL, last_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS link_tokens (hash TEXT PRIMARY KEY, created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS machines (id TEXT PRIMARY KEY, json TEXT NOT NULL, last_seen TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS agents (session_id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, json TEXT NOT NULL);
    `);
  }

  /** Records the viewer and returns the id of their default mux. */
  async signIn(viewer: Viewer): Promise<ID> {
    this.sql.exec(
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('viewer', ?)",
      JSON.stringify(viewer),
    );
    return `mux-${viewer.id}`;
  }

  async listConversations(): Promise<ConversationSummary[]> {
    return this.sql
      .exec<{ id: string; title: string; preview: string; last_at: string }>(
        "SELECT id, title, preview, last_at FROM conversations ORDER BY last_at DESC",
      )
      .toArray()
      .map((row) => ({ id: row.id, title: row.title, preview: row.preview, lastAt: row.last_at }));
  }

  async upsertConversation(summary: ConversationSummary): Promise<void> {
    this.sql.exec(
      "INSERT OR REPLACE INTO conversations (id, title, preview, last_at) VALUES (?, ?, ?, ?)",
      summary.id,
      summary.title,
      summary.preview,
      summary.lastAt,
    );
  }

  /** The account's memory VM (Freestyle), created on first use. Undefined without a Freestyle key. */
  async memoryVm(): Promise<string | undefined> {
    const apiKey = this.env.FREESTYLE_API_KEY;
    if (!apiKey) return undefined;
    // v2: VMs from the mux-memory-base snapshot (1 vCPU, 128 MiB). Memory moves
    // over on its own: the Durable Object caches push their lines to the new VM.
    const row = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'memory_vm_v2'")
      .toArray()[0];
    if (row) return row.value;
    const viewer = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'viewer'")
      .toArray()[0];
    const owner = viewer ? (JSON.parse(viewer.value) as Viewer).id : this.ctx.id.toString();
    const vmId = await ensureVm(
      apiKey,
      `mux-memory-${(await sha256(owner)).slice(0, 20)}`,
      "mux memory",
      this.env.MUX_MEMORY_SNAPSHOT,
    );
    this.sql.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('memory_vm_v2', ?)", vmId);
    return vmId;
  }

  // Links

  /** A new secret for a link; only its hash is stored. */
  async mintLinkSecret(): Promise<string> {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const secret = btoa(String.fromCharCode(...bytes)).replace(
      /[+/=]/g,
      (c) => ({ "+": "-", "/": "_", "=": "" })[c]!,
    );
    this.sql.exec(
      "INSERT INTO link_tokens (hash, created_at) VALUES (?, ?)",
      await sha256(secret),
      new Date().toISOString(),
    );
    return secret;
  }

  async verifyLinkSecret(secret: string): Promise<boolean> {
    return (
      this.sql.exec("SELECT 1 FROM link_tokens WHERE hash = ?", await sha256(secret)).toArray()
        .length > 0
    );
  }

  async listMachines(): Promise<Machine[]> {
    const online = new Set(this.ctx.getWebSockets("link").map((ws) => this.machineOf(ws)?.id));
    return this.sql
      .exec<{ json: string; last_seen: string }>(
        "SELECT json, last_seen FROM machines ORDER BY last_seen DESC",
      )
      .toArray()
      .map((row) => {
        const info = JSON.parse(row.json) as MachineInfo;
        return { ...info, online: online.has(info.id), lastSeen: row.last_seen };
      });
  }

  /** Calls a method on a machine's link. With no machine id, uses the only online machine. */
  async linkCall<M extends LinkMethod>(
    machineId: ID | undefined,
    method: M,
    params: LinkMethods[M]["params"],
    origin?: AgentOrigin,
  ): Promise<LinkMethods[M]["result"]> {
    const socket = this.linkSocket(machineId);
    const id = this.nextCallId++;
    console.log(JSON.stringify({ at: "link.call", id, method }));
    const result = await new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.calls.delete(id);
        reject(new Error(`${method} timed out after ${CALL_TIMEOUT_MS / 1000}s`));
      }, CALL_TIMEOUT_MS);
      this.calls.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ type: "call", id, method, params } satisfies LinkDownFrame));
    });
    if ((method === "agents.spawn" || method === "agents.prompt") && origin) {
      const { sessionId } = result as { sessionId: string };
      this.sql.exec(
        "INSERT OR REPLACE INTO agents (session_id, machine_id, json) VALUES (?, ?, ?)",
        sessionId,
        this.machineOf(socket)?.id ?? "",
        JSON.stringify(origin),
      );
    }
    return result as LinkMethods[M]["result"];
  }

  override async fetch(request: Request): Promise<Response> {
    if (
      request.headers.get(LINK_HEADER) !== "1" ||
      request.headers.get("upgrade") !== "websocket"
    ) {
      return new Response("expected link websocket", { status: 426 });
    }
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, ["link"]);
    const viewer = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'viewer'")
      .toArray()[0];
    const accountId = viewer ? (JSON.parse(viewer.value) as Viewer).id : "";
    server.send(JSON.stringify({ type: "welcome", accountId } satisfies LinkDownFrame));
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    let frame: LinkUpFrame;
    try {
      frame = JSON.parse(
        typeof data === "string" ? data : new TextDecoder().decode(data),
      ) as LinkUpFrame;
    } catch {
      return;
    }
    switch (frame.type) {
      case "hello": {
        // Only one live socket per machine: a reconnect replaces the old one.
        for (const other of this.ctx.getWebSockets("link")) {
          if (other !== ws && this.machineOf(other)?.id === frame.machine.id)
            other.close(4000, "replaced");
        }
        ws.serializeAttachment(frame.machine);
        this.sql.exec(
          "INSERT OR REPLACE INTO machines (id, json, last_seen) VALUES (?, ?, ?)",
          frame.machine.id,
          JSON.stringify(frame.machine),
          new Date().toISOString(),
        );
        return;
      }
      case "result": {
        const call = this.calls.get(frame.id);
        if (!call) return;
        this.calls.delete(frame.id);
        clearTimeout(call.timer);
        if (frame.ok) call.resolve(frame.value);
        else call.reject(new Error(frame.error));
        return;
      }
      case "event":
        await this.routeEvent(frame.event);
        return;
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    const machine = this.machineOf(ws);
    if (machine) {
      this.sql.exec(
        "UPDATE machines SET last_seen = ? WHERE id = ?",
        new Date().toISOString(),
        machine.id,
      );
    }
  }

  private async routeEvent(event: LinkEvent): Promise<void> {
    const row = this.sql
      .exec<{ json: string }>("SELECT json FROM agents WHERE session_id = ?", event.sessionId)
      .toArray()[0];
    console.log(
      JSON.stringify({
        at: "link.event",
        kind: event.kind,
        sessionId: event.sessionId,
        routed: !!row,
      }),
    );
    if (!row) return;
    const origin = JSON.parse(row.json) as AgentOrigin;
    await mux(this.env, origin.muxId).receiveEvent(origin.conversationId, event);
  }

  private linkSocket(machineId: ID | undefined): WebSocket {
    const sockets = this.ctx.getWebSockets("link").filter((ws) => this.machineOf(ws));
    const matches = machineId
      ? sockets.filter((ws) => this.machineOf(ws)?.id === machineId)
      : sockets;
    if (matches.length === 1) return matches[0];
    if (matches.length === 0) {
      throw new Error(
        machineId
          ? `machine ${machineId} is not connected`
          : "no machine is connected; run mux-link",
      );
    }
    throw new Error(
      `several machines are connected; pass one of: ${sockets.map((ws) => this.machineOf(ws)?.id).join(", ")}`,
    );
  }

  private machineOf(ws: WebSocket): MachineInfo | undefined {
    return (ws.deserializeAttachment() as MachineInfo | null) ?? undefined;
  }
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
