// HostSignal: one Durable Object per host_id. Uses the WebSocket hibernation API.
// The Worker authenticates every socket before forwarding the upgrade here and
// passes the role in trusted x-signal-* headers.
import { DurableObject } from "cloudflare:workers";
import { connect } from "@planetscale/database";
import type { Env } from "./index";

type Role = "host" | "phone";
interface Attachment {
  role: Role;
  user_id: string;
  sids: string[];
}

const MESSAGE_TYPES = new Set(["offer", "answer", "ice", "bye"]);
const MAX_MESSAGE_BYTES = 64 * 1024;
const MAX_SIDS_PER_SOCKET = 32;

export class HostSignal extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'));
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/presence") {
      const online = this.hostSockets().length > 0;
      const stored = (await this.ctx.storage.get<number>("last_seen")) ?? null;
      return Response.json({ online, last_seen: online ? Date.now() : stored });
    }
    if (url.pathname === "/kick" && req.method === "POST") {
      const userId = url.searchParams.get("user_id");
      for (const ws of this.ctx.getWebSockets("phone")) {
        if (this.att(ws)?.user_id === userId) safeClose(ws, 4003, "unpaired");
      }
      return Response.json({ ok: true });
    }
    if (url.pathname === "/action" && req.method === "POST") {
      // A notification response, already authorized by the Worker (the user
      // owns this host). The host validates the event and surface itself.
      const host = this.hostSockets()[0];
      if (!host) return Response.json({ error: "host_offline" }, { status: 409 });
      const body = (await req.json()) as { user_id: string; action: unknown };
      send(host, { t: "action", from: "phone", user_id: body.user_id, action: body.action });
      return Response.json({ ok: true });
    }
    if (url.pathname === "/connect") return this.acceptConnection(req);
    return new Response("not found", { status: 404 });
  }

  private acceptConnection(req: Request): Response {
    const role = req.headers.get("x-signal-role") as Role | null;
    const userId = req.headers.get("x-signal-user") ?? "";
    const hostId = req.headers.get("x-signal-host") ?? "";
    if (role !== "host" && role !== "phone") return new Response("bad role", { status: 400 });
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    if (role === "host") {
      // A newer host connection replaces any older one.
      for (const old of this.hostSockets()) safeClose(old, 4000, "replaced");
    }
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role, user_id: userId, sids: [] } satisfies Attachment);
    if (role === "host") {
      const now = Date.now();
      this.ctx.waitUntil(
        (async () => {
          await this.ctx.storage.put({ last_seen: now, host_id: hostId });
          await this.recordPresence(hostId, now, true);
        })(),
      );
      this.broadcastPhones({ t: "presence", online: true });
    } else {
      server.send(JSON.stringify({ t: "presence", online: this.hostSockets().length > 0 }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const a = this.att(ws);
    if (!a) return;
    if (typeof raw !== "string" || raw.length > MAX_MESSAGE_BYTES) {
      return send(ws, { t: "error", code: "bad_message", message: "text JSON up to 64 KiB" });
    }
    let msg: Record<string, unknown>;
    try {
      const v = JSON.parse(raw);
      if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error();
      msg = v;
    } catch {
      return send(ws, { t: "error", code: "bad_message", message: "invalid JSON" });
    }
    const t = msg.t;
    const sid = msg.sid;
    if (t === "ping") return send(ws, { t: "pong" });
    if (typeof t !== "string" || !MESSAGE_TYPES.has(t)) {
      return send(ws, { t: "error", code: "bad_type", sid: typeof sid === "string" ? sid : undefined });
    }
    if (typeof sid !== "string" || sid.length < 1 || sid.length > 64) {
      return send(ws, { t: "error", code: "bad_sid" });
    }

    if (a.role === "phone") {
      if (!a.sids.includes(sid)) {
        // A sid belongs to exactly one phone socket.
        for (const other of this.ctx.getWebSockets("phone")) {
          const oa = this.att(other);
          if (other !== ws && oa?.sids.includes(sid)) {
            return send(ws, { t: "error", code: "sid_in_use", sid });
          }
        }
        a.sids.push(sid);
        if (a.sids.length > MAX_SIDS_PER_SOCKET) a.sids.shift();
        ws.serializeAttachment(a);
      }
      const host = this.hostSockets()[0];
      if (!host) return send(ws, { t: "error", code: "host_offline", sid });
      send(host, { ...msg, from: "phone", user_id: a.user_id });
      if (t === "bye") {
        a.sids = a.sids.filter((s) => s !== sid);
        ws.serializeAttachment(a);
      }
      return;
    }

    // host -> phone
    const phone = this.phoneForSid(sid);
    if (!phone) return send(ws, { t: "error", code: "unknown_sid", sid });
    const { user_id: _drop, ...rest } = msg;
    send(phone, { ...rest, from: "host" });
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.onGone(ws);
    safeClose(ws, code === 1005 || code === 1006 ? 1000 : code, reason);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.onGone(ws);
  }

  private onGone(ws: WebSocket): void {
    const a = this.att(ws);
    if (!a) return;
    if (a.role === "phone") {
      const host = this.hostSockets().filter((h) => h !== ws)[0];
      if (host) for (const sid of a.sids) send(host, { t: "bye", sid, from: "phone", user_id: a.user_id, reason: "phone_disconnected" });
      return;
    }
    if (this.hostSockets().some((h) => h !== ws)) return; // replaced by a newer host socket
    const now = Date.now();
    this.ctx.waitUntil(
      (async () => {
        await this.ctx.storage.put("last_seen", now);
        const hostId = await this.ctx.storage.get<string>("host_id");
        if (hostId) await this.recordPresence(hostId, now, false);
      })(),
    );
    for (const phone of this.ctx.getWebSockets("phone")) {
      const pa = this.att(phone);
      for (const sid of pa?.sids ?? []) send(phone, { t: "bye", sid, from: "host", reason: "host_disconnected" });
      send(phone, { t: "presence", online: false });
    }
  }

  private async recordPresence(hostId: string, now: number, online: boolean): Promise<void> {
    try {
      const conn = connect({ host: this.env.DB_HOST, username: this.env.DB_USERNAME, password: this.env.DB_PASSWORD });
      await conn.execute("UPDATE hosts SET last_seen = ?, online = ? WHERE id = ?", [now, online ? 1 : 0, hostId]);
    } catch (e) {
      console.error("presence update failed", e instanceof Error ? e.message : String(e));
    }
  }

  private hostSockets(): WebSocket[] {
    return this.ctx.getWebSockets("host").filter((ws) => ws.readyState === WebSocket.OPEN);
  }

  private phoneForSid(sid: string): WebSocket | undefined {
    return this.ctx.getWebSockets("phone").find((ws) => this.att(ws)?.sids.includes(sid));
  }

  private broadcastPhones(msg: unknown): void {
    for (const ws of this.ctx.getWebSockets("phone")) send(ws, msg);
  }

  private att(ws: WebSocket): Attachment | null {
    return (ws.deserializeAttachment() as Attachment | null) ?? null;
  }
}

function send(ws: WebSocket, msg: unknown): void {
  try {
    ws.send(JSON.stringify(msg));
  } catch {}
}

function safeClose(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(code, reason);
  } catch {}
}
