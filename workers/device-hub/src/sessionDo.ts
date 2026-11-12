import { DurableObject } from "cloudflare:workers";
import { checkDeviceSignature, readDeviceHeaders } from "./deviceAuth";
import type { Env } from "./env";
import { ApiError, errorResponse, json } from "./errors";
import { internalCall, why } from "./internalCall";
import { type Role, readTicket } from "./tickets";

interface Meta {
  sid: string;
  userId: string;
  scope: string;
  viewer: { id: string; key: string };
  host: { id: string; key: string };
  started?: boolean;
}

const RELAYED = new Set(["offer", "answer", "candidate", "bye"]);
const MAX_MESSAGE = 64 * 1024;
const MAX_QUEUE = 256;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jti(jti TEXT PRIMARY KEY, exp INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS queue(seq INTEGER PRIMARY KEY AUTOINCREMENT, to_role TEXT NOT NULL, msg TEXT NOT NULL);
`;

// A closed session keeps a "closed" marker this long, so an init that arrives
// after its close (the User DO sends both without waiting) is refused.
const CLOSED_TTL_MS = 10 * 60 * 1000;

const other = (role: Role): Role => (role === "viewer" ? "host" : "viewer");

/**
 * One per session (idFromName(sessionId)). Admits exactly one socket per role
 * with a single-use ticket plus the device's signature, relays signaling
 * verbatim, reports start and end to the user's User DO, and deletes its
 * storage when the session ends, keeping only a "closed" marker for a while.
 * Created by the User DO at approval.
 */
export class SessionDO extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
  }

  /** Null once the session ended (storage deleted) or before init. */
  private meta(): Meta | null {
    const exists = this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").toArray().length > 0;
    if (!exists) return null;
    const row = this.sql.exec("SELECT v FROM meta WHERE k = 'session'").toArray()[0];
    return row ? (JSON.parse(row.v as string) as Meta) : null;
  }

  /** True after a close, until the marker's alarm clears it. */
  private closed(): boolean {
    const exists = this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").toArray().length > 0;
    return exists && this.sql.exec("SELECT 1 FROM meta WHERE k = 'closed'").toArray().length > 0;
  }

  private saveMeta(m: Meta) {
    this.sql.exec("INSERT INTO meta(k, v) VALUES ('session', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", JSON.stringify(m));
  }

  private userStub(m: Meta) {
    return this.env.USER_DO.get(this.env.USER_DO.idFromName(m.userId));
  }

  async fetch(request: Request): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/internal/init" && request.method === "POST") {
        const body = (await request.json()) as Meta;
        if (this.meta() || this.closed()) return json({ ok: false }, 409);
        this.sql.exec(SCHEMA);
        this.saveMeta({ sid: body.sid, userId: body.userId, scope: body.scope, viewer: body.viewer, host: body.host });
        return json({ ok: true });
      }
      if (url.pathname === "/internal/close" && request.method === "POST") {
        const { reason } = (await request.json()) as { reason?: string };
        await this.shutdown(4002, reason ?? "revoked");
        return json({ ok: true });
      }
      return await this.admit(request, url);
    } catch (err) {
      return errorResponse(err);
    }
  }

  private async admit(request: Request, url: URL): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new ApiError(426, "bad_request", "expected a WebSocket upgrade");
    const m = this.meta();
    if (!m) throw new ApiError(404, "session_not_active", "session is not active");
    const now = Date.now();
    const ticket = await readTicket(this.env, url.searchParams.get("ticket") ?? "");
    if (!ticket || ticket.sid !== m.sid) throw new ApiError(401, "ticket_invalid", "ticket does not verify");
    if (ticket.exp * 1000 <= now) throw new ApiError(401, "ticket_invalid", "ticket expired");
    const h = readDeviceHeaders(request.headers, now);
    const expected = ticket.role === "viewer" ? m.viewer : m.host;
    if (ticket.dev !== h.id || expected.id !== h.id) throw new ApiError(403, "ticket_invalid", "ticket is for another device");
    await checkDeviceSignature(expected.key, request.method, url, new Uint8Array(), h);
    if (this.sql.exec("SELECT 1 FROM jti WHERE jti = ?", ticket.jti).toArray().length > 0) throw new ApiError(401, "replay", "ticket was already used");
    if (this.ctx.getWebSockets(ticket.role).length > 0) throw new ApiError(409, "role_taken", `the ${ticket.role} is already connected`);
    this.sql.exec("INSERT INTO jti(jti, exp) VALUES (?, ?)", ticket.jti, ticket.exp);

    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [ticket.role, h.id]);
    // This side is back: a peer-left about it still waiting for the other side is stale.
    this.sql.exec("DELETE FROM queue WHERE to_role = ? AND msg LIKE ?", other(ticket.role), `{"type":"peer-left","role":"${ticket.role}"%`);
    // Deliver what the peer sent before this side connected.
    const queued = this.sql.exec("SELECT seq, msg FROM queue WHERE to_role = ? ORDER BY seq", ticket.role).toArray();
    for (const q of queued) pair[1].send(q.msg as string);
    this.sql.exec("DELETE FROM queue WHERE to_role = ?", ticket.role);

    if (!m.started && this.ctx.getWebSockets(other(ticket.role)).length > 0) {
      this.saveMeta({ ...m, started: true });
      // The socket is admitted either way: signaling must not wait on a stalled User DO.
      try {
        await internalCall(this.userStub(m), "https://user.do/internal/session-started", { sid: m.sid }, `session ${m.sid} started report`);
      } catch (err) {
        console.error(`device-hub: ${why(err)}`);
      }
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const m = this.meta();
    if (!m) {
      ws.close(4002, "ended");
      return;
    }
    if (typeof message !== "string" || message.length > MAX_MESSAGE) return;
    let type: unknown;
    try {
      type = (JSON.parse(message) as { type?: unknown }).type;
    } catch {
      return;
    }
    const role = this.ctx.getTags(ws)[0] as Role;
    if (type === "path") {
      // Not relayed: the device reports which path the media took.
      const path = (JSON.parse(message) as { path?: unknown }).path;
      if (path === "direct" || path === "relay") {
        try {
          await internalCall(this.userStub(m), "https://user.do/internal/session-path", { sid: m.sid, path }, `session ${m.sid} path report`);
        } catch (err) {
          console.error(`device-hub: ${why(err)}`);
        }
      }
      return;
    }
    if (typeof type !== "string" || !RELAYED.has(type)) return;
    const peers = this.ctx.getWebSockets(other(role));
    if (peers.length > 0) {
      for (const p of peers) p.send(message);
    } else if (type !== "bye") {
      const count = this.sql.exec("SELECT COUNT(*) AS n FROM queue").one().n as number;
      if (count < MAX_QUEUE) this.sql.exec("INSERT INTO queue(to_role, msg) VALUES (?, ?)", other(role), message);
    }
    if (type === "bye") await this.end("bye");
  }

  /**
   * A closed signaling socket ends signaling for that side, not the session:
   * the peer connection may still be up. The session ends on bye, /end,
   * revocation or the User DO's offline grace, which close this DO. The other
   * side hears `peer-left` with why, so a half-open setup can give up at once.
   */
  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      // already closed
    }
    this.peerLeft(ws, reason ? `closed ${code}: ${reason}` : `closed ${code}`);
  }

  /** A failed socket (reset, transport error) is a close the client never sent: same handling, with the error as the reason. */
  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    const reason = `error: ${why(error)}`;
    console.warn(`device-hub: signaling socket ${this.ctx.getTags(ws).join("/")} failed (${reason})`);
    // Told before the close, which marks the socket so its close event does not tell again.
    this.peerLeft(ws, reason);
    try {
      ws.close(1011, reason.slice(0, 120));
    } catch {
      // already closed
    }
  }

  /** Tells the other role that this side's signaling socket is gone, once per socket. Nothing after the session ended. */
  private peerLeft(ws: WebSocket, reason: string) {
    if (!this.meta()) return;
    if ((ws.deserializeAttachment() as { left?: boolean } | null)?.left) return;
    try {
      ws.serializeAttachment({ left: true });
    } catch {
      // a socket that cannot take an attachment any more still gets its peer told
    }
    const role = this.ctx.getTags(ws)[0] as Role;
    const msg = JSON.stringify({ type: "peer-left", role, reason: reason.slice(0, 120) });
    const peers = this.ctx.getWebSockets(other(role));
    if (peers.length === 0) {
      // The other side has not joined yet: it hears this when it does (admit delivers the queue).
      const count = this.sql.exec("SELECT COUNT(*) AS n FROM queue").one().n as number;
      if (count < MAX_QUEUE) this.sql.exec("INSERT INTO queue(to_role, msg) VALUES (?, ?)", other(role), msg);
      return;
    }
    for (const p of peers) {
      try {
        p.send(msg);
      } catch {
        // closing socket
      }
    }
  }

  /** Reports the end to the User DO, then closes both sockets and deletes storage. */
  private async end(reason: string) {
    const m = this.meta();
    if (!m) return;
    // Both sides asked to end: close their sockets even if the User DO does not answer.
    try {
      await internalCall(this.userStub(m), "https://user.do/internal/session-ended", { sid: m.sid, reason }, `session ${m.sid} end report (${reason})`);
    } catch (err) {
      console.error(`device-hub: ${why(err)}`);
    }
    await this.shutdown(1000, reason);
  }

  private async shutdown(code: number, reason: string) {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(code, reason.slice(0, 120));
      } catch {
        // already closed
      }
    }
    await this.ctx.storage.deleteAll();
    this.sql.exec(SCHEMA);
    this.sql.exec("INSERT INTO meta(k, v) VALUES ('closed', '1')");
    await this.ctx.storage.setAlarm(Date.now() + CLOSED_TTL_MS);
  }

  /** Clears the closed marker. */
  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
