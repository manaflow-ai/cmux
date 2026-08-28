// MacRelay — the dot/1 data-plane Durable Object.
//
// One instance per (account user, Mac device), named
// `relay:user:<userId>:mac:<macDeviceId>` by the worker AFTER Stack auth, so
// unauthenticated callers can never materialize an object. The Mac keeps one
// standing "host" leg; phones open "phone" legs. Binary frames are routed on a
// fixed 14-byte header; payloads are opaque (E2E-encrypted by the apps).
//
// Reliability: every directed stream (host→phone, and phone→host per phone)
// is sender-sequenced. The relay keeps a bounded in-memory replay ring per
// stream, prunes it on receiver acks, and on a leg redial replays the gap iff
// it can PROVE coverage (see ReplayRing.coversGap). When a leg detaches with
// un-acked frames, the ring is spilled to storage so the proof survives DO
// restarts/hibernation; the normal both-connected path performs zero storage
// writes per frame.
//
// Auth: the worker forwards a verified deadline (token exp capped at 15 min).
// Legs extend it in-band with `auth.refresh` (re-verified against Stack from
// here, pinned to the same user) so a healthy connection never tears down for
// token rotation — same auth strength as the presence streams without the
// 15-minute reconnect.

import { DurableObject } from "cloudflare:workers";

import { verifyAccessToken, cacheDeadline, tokenExpiryMs, type AuthEnv } from "./auth";
import { resolveSubscribeDeadline } from "./core";
import {
  AUTH_GRACE_MS,
  CLOSE_CAPACITY,
  CLOSE_PROTOCOL_ERROR,
  CLOSE_SUPERSEDED,
  CLOSE_UNAUTHORIZED,
  DOT_PROTOCOL,
  HELLO_TIMEOUT_MS,
  MAX_CONTROL_BYTES,
  MAX_PHONE_LEGS,
  RELAY_MAX_SUBSCRIBE_AGE_MS,
  ReplayRing,
  decodeControl,
  decodeDataHeader,
  encodeControl,
  mintResumeKey,
  rewriteLegId,
  sha256Base64,
  type ControlFrame,
} from "./relayProtocol";

/** Detached-leg state (meta + spilled ring) is kept this long for resume. */
export const RESUME_TTL_MS = 10 * 60 * 1000;
/** Storage values are capped at 128 KiB; larger frames cannot spill. */
const MAX_SPILL_FRAME_BYTES = 120 * 1024;

type Role = "host" | "phone";

interface WsAttachment {
  role: Role;
  userId: string;
  device: string;
  expiresAt: number;
  acceptedAt: number;
  legId?: number;
}

interface LegMeta {
  role: Role;
  device: string;
  resumeKeyHash: string;
  /** Persisted on detach: last enqueued seq per source leg id ("h" for host
   * on phone legs). Presence of this map is what makes a resume provable
   * across a DO restart. */
  lastEnqueuedBySrc?: Record<string, number>;
  /** Set when a frame could not be spilled (oversize) — resume must fail. */
  broken?: boolean;
  detachedAt?: number;
}

type RelayEnv = AuthEnv;

function attachment(ws: WebSocket): WsAttachment | null {
  try {
    return (ws.deserializeAttachment() as WsAttachment) ?? null;
  } catch {
    return null;
  }
}

function legKey(legId: number): string {
  return `leg:${legId}`;
}

/** Ring/spill destination key: host-destined streams are keyed by ROLE ("h"),
 * not by the host's leg id, so phone uploads buffered while the Mac is away
 * survive into the host's resume; phone-destined streams key on the phone's
 * stable leg id. */
function destKey(role: Role, legId: number): string {
  return role === "host" ? "h" : String(legId);
}

function spillPrefix(dst: string, src: string): string {
  return `spill:${dst}:${src}:`;
}

function spillKey(dst: string, src: string, seq: number): string {
  return `${spillPrefix(dst, src)}${String(seq).padStart(16, "0")}`;
}

/** Ring id for the directed stream src→dst. Host is "h" on both axes so
 * streams survive host leg-id churn across host resumes. */
function ringId(dst: string, src: string): string {
  return `${dst}<${src}`;
}

export class MacRelay extends DurableObject<RelayEnv> {
  /** In-memory replay rings per directed stream; rebuilt from spill on demand. */
  private rings = new Map<string, ReplayRing>();
  /** legId → live socket, rebuilt lazily after hibernation. */
  private socketsByLeg = new Map<number, WebSocket>();

  // ---- accept path (worker forwards the original upgrade request) ----

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response(JSON.stringify({ error: "websocket_required" }), {
        status: 426,
        headers: { "content-type": "application/json" },
      });
    }
    const role = request.headers.get("x-relay-role") as Role | null;
    const userId = request.headers.get("x-relay-user-id")?.trim();
    const device = request.headers.get("x-relay-device")?.trim();
    if ((role !== "host" && role !== "phone") || !userId || !device) {
      return new Response(JSON.stringify({ error: "bad_gateway_headers" }), { status: 500 });
    }
    const now = Date.now();
    const expiresAt = resolveSubscribeDeadline(
      request.headers.get("x-relay-expires-at"),
      now,
      RELAY_MAX_SUBSCRIBE_AGE_MS,
    );
    if (expiresAt === null) {
      return new Response(JSON.stringify({ error: "subscription_expired" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }
    if (role === "phone" && this.liveLegs("phone").length >= MAX_PHONE_LEGS) {
      return new Response(JSON.stringify({ error: "too_many_legs" }), {
        status: 429,
        headers: { "content-type": "application/json" },
      });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({
      role,
      userId,
      device,
      expiresAt,
      acceptedAt: now,
    } satisfies WsAttachment);
    await this.ensureAlarmAt(Math.min(now + HELLO_TIMEOUT_MS, expiresAt + AUTH_GRACE_MS));
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---- socket events (hibernation API) ----

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = attachment(ws);
    if (!att) {
      ws.close(CLOSE_PROTOCOL_ERROR, "no attachment");
      return;
    }
    if (typeof message === "string") {
      await this.handleControl(ws, att, message);
      return;
    }
    await this.handleData(ws, att, message);
  }

  override async webSocketClose(ws: WebSocket, _code: number, _reason: string): Promise<void> {
    await this.detachLeg(ws, "closed");
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.detachLeg(ws, "error");
  }

  // ---- control frames ----

  private async handleControl(ws: WebSocket, att: WsAttachment, text: string): Promise<void> {
    if (new TextEncoder().encode(text).byteLength > MAX_CONTROL_BYTES) {
      ws.close(CLOSE_PROTOCOL_ERROR, "control too large");
      return;
    }
    const frame = decodeControl(text);
    if (!frame) {
      ws.close(CLOSE_PROTOCOL_ERROR, "bad control frame");
      return;
    }
    switch (frame.t) {
      case "hello":
        await this.handleHello(ws, att, frame);
        return;
      case "ping":
        this.send(ws, { t: "pong", ts: frame.ts });
        return;
      case "ack":
        this.handleAck(att, frame.seq, frame.leg);
        return;
      case "auth.refresh":
        await this.handleAuthRefresh(ws, att, frame.token);
        return;
      default:
        ws.close(CLOSE_PROTOCOL_ERROR, "unexpected control frame");
    }
  }

  private async handleHello(
    ws: WebSocket,
    att: WsAttachment,
    frame: Extract<ControlFrame, { t: "hello" }>,
  ): Promise<void> {
    if (frame.proto !== DOT_PROTOCOL) {
      ws.close(CLOSE_PROTOCOL_ERROR, "unsupported protocol");
      return;
    }
    if (att.legId !== undefined) {
      ws.close(CLOSE_PROTOCOL_ERROR, "duplicate hello");
      return;
    }
    if (frame.device !== att.device) {
      ws.close(CLOSE_PROTOCOL_ERROR, "device mismatch");
      return;
    }

    // Resume: rebind the caller to its previous leg id iff the resume key
    // matches and every needed replay gap is provable.
    let legId: number | null = null;
    let replayed = 0;
    if (frame.resume) {
      const resumed = await this.tryResume(ws, att, frame);
      if (resumed === "failed") return; // tryResume already closed/replied
      if (resumed !== null) {
        legId = resumed.legId;
        replayed = resumed.replayed;
      }
    }
    const freshLeg = legId === null;

    if (legId === null) {
      // Fresh session: supersede any live leg for the same (role, device) and
      // drop its resumable state — the caller explicitly started over.
      for (const other of this.liveLegs(att.role)) {
        const otherAtt = attachment(other);
        if (other !== ws && otherAtt?.device === att.device) {
          await this.dropLegState(otherAtt.legId, att.role);
          other.close(CLOSE_SUPERSEDED, "superseded by a new session");
        }
      }
      if (att.role === "host") {
        // A Mac has exactly one host leg regardless of device string drift.
        for (const other of this.liveLegs("host")) {
          if (other === ws) continue;
          const otherAtt = attachment(other);
          await this.dropLegState(otherAtt?.legId, "host");
          other.close(CLOSE_SUPERSEDED, "superseded by a new host");
        }
        // A fresh host session cannot decrypt frames phones buffered for the
        // previous host process; clear every host-destined stream so stale
        // ciphertext never replays into this session.
        for (const id of [...this.rings.keys()]) {
          if (id.startsWith("h<")) this.rings.delete(id);
        }
        const staleSpill = await this.ctx.storage.list({ prefix: "spill:h:" });
        if (staleSpill.size > 0) await this.ctx.storage.delete([...staleSpill.keys()]);
      }
      legId = await this.nextLegId();
    }

    const resumeKey = mintResumeKey();
    const meta: LegMeta = {
      role: att.role,
      device: att.device,
      resumeKeyHash: await sha256Base64(resumeKey),
    };
    await this.ctx.storage.put(legKey(legId), meta);

    const updated: WsAttachment = { ...att, legId };
    ws.serializeAttachment(updated);
    this.socketsByLeg.set(legId, ws);

    this.send(ws, {
      t: "hello.ack",
      legId,
      resumeKey,
      epoch: await this.epoch(),
      peerOnline: att.role === "host" ? this.liveLegs("phone").length > 0 : this.hostSocket() !== null,
      replayed,
    });
    // Tell the client when this authenticated leg must refresh. The refresh
    // is in-band, so a healthy WebSocket never has to reconnect merely because
    // a short-lived Stack access token rotated.
    this.send(ws, { t: "auth.ok", deadline: att.expiresAt });

    // Presence notifications to the other side.
    if (att.role === "host" && freshLeg) {
      for (const phone of this.liveLegs("phone")) {
        this.send(phone, { t: "peer.online", legId });
        const phoneAtt = attachment(phone);
        if (phoneAtt?.legId !== undefined) {
          this.send(ws, { t: "peer.online", legId: phoneAtt.legId, device: phoneAtt.device });
        }
      }
    } else if (att.role === "phone" && freshLeg) {
      const host = this.hostSocket();
      if (host) {
        this.send(host, { t: "peer.online", legId, device: att.device });
        const hostAtt = attachment(host);
        this.send(ws, {
          t: "peer.online",
          ...(hostAtt?.legId !== undefined ? { legId: hostAtt.legId } : {}),
          ...(hostAtt?.device ? { device: hostAtt.device } : {}),
        });
      }
    }
    await this.ensureAlarmAt(att.expiresAt + AUTH_GRACE_MS);
  }

  /** Attempt a resume. Returns null to fall through to a fresh session (no
   * prior state), "failed" when the caller must re-handshake (already
   * replied), or the rebound leg. */
  private async tryResume(
    ws: WebSocket,
    att: WsAttachment,
    frame: Extract<ControlFrame, { t: "hello" }>,
  ): Promise<{ legId: number; replayed: number } | "failed" | null> {
    const hash = await sha256Base64(frame.resume!);
    // Find the leg meta for this (role, device) with a matching resume hash.
    const metas = await this.ctx.storage.list<LegMeta>({ prefix: "leg:" });
    let legId: number | null = null;
    let meta: LegMeta | null = null;
    for (const [key, value] of metas) {
      if (value.role === att.role && value.device === att.device && value.resumeKeyHash === hash) {
        legId = Number(key.slice("leg:".length));
        meta = value;
        break;
      }
    }
    if (legId === null || meta === null) {
      this.send(ws, { t: "resume.failed", reason: "unknown session" });
      ws.close(CLOSE_PROTOCOL_ERROR, "resume failed");
      return "failed";
    }
    if (meta.broken) {
      await this.dropLegState(legId);
      this.send(ws, { t: "resume.failed", reason: "buffer overflow" });
      ws.close(CLOSE_PROTOCOL_ERROR, "resume failed");
      return "failed";
    }

    // Close a lingering socket still bound to this leg (network limbo redial).
    const lingering = this.socketFor(legId);
    if (lingering && lingering !== ws) {
      lingering.close(CLOSE_SUPERSEDED, "superseded by resume");
      this.socketsByLeg.delete(legId);
    }

    // Prove and replay every download stream this leg consumes.
    const dst = destKey(att.role, legId);
    const acks: Array<{ src: string; ack: number }> =
      att.role === "phone"
        ? [{ src: "h", ack: frame.ack ?? 0 }]
        : Object.entries(frame.acks ?? {}).map(([src, ack]) => ({ src, ack }));
    let replayed = 0;
    for (const { src, ack } of acks) {
      const proof = await this.provableReplay(dst, src, ack, meta);
      if (proof === null) {
        await this.dropLegState(legId);
        this.send(ws, { t: "resume.failed", reason: "gap not provable" });
        ws.close(CLOSE_PROTOCOL_ERROR, "resume failed");
        return "failed";
      }
      for (const data of proof) {
        try {
          ws.send(data);
          replayed += 1;
        } catch {
          return "failed";
        }
      }
    }
    // A host resume must prove every phone stream it did not list too: any
    // un-acked frames from an unlisted source (live ring or spilled state)
    // are a silent gap otherwise.
    if (att.role === "host") {
      const listed = new Set(acks.map((entry) => entry.src));
      const unlisted = new Set<string>();
      for (const [id, ring] of this.rings) {
        const [ringDst, src] = id.split("<");
        if (ringDst === dst && !listed.has(src!) && ring.lastEnqueued > 0) unlisted.add(src!);
      }
      for (const src of Object.keys(meta.lastEnqueuedBySrc ?? {})) {
        if (!listed.has(src)) unlisted.add(src);
      }
      for (const src of unlisted) {
        const proof = await this.provableReplay(dst, src, 0, meta);
        if (proof === null) {
          await this.dropLegState(legId);
          this.send(ws, { t: "resume.failed", reason: "gap not provable" });
          ws.close(CLOSE_PROTOCOL_ERROR, "resume failed");
          return "failed";
        }
        for (const data of proof) {
          try {
            ws.send(data);
            replayed += 1;
          } catch {
            return "failed";
          }
        }
      }
    }

    // Re-attach: clear detach markers so the alarm stops the GC clock, and
    // drop consumed spill rows (the rebuilt in-memory rings own replay now).
    delete meta.detachedAt;
    delete meta.lastEnqueuedBySrc;
    await this.ctx.storage.put(legKey(legId), meta);
    const spilled = await this.ctx.storage.list({ prefix: `spill:${dst}:` });
    if (spilled.size > 0) await this.ctx.storage.delete([...spilled.keys()]);
    return { legId, replayed };
  }

  /** Frames covering (ack, lastEnqueued] for the stream src→dst, from the
   * in-memory ring plus any spill. Null when coverage cannot be proven. */
  private async provableReplay(
    dst: string,
    src: string,
    ack: number,
    meta: LegMeta,
  ): Promise<ArrayBuffer[] | null> {
    const ring = this.rings.get(ringId(dst, src));
    if (ring) {
      if (!ring.coversGap(ack)) return null;
      return ring.replayAfter(ack);
    }
    // No in-memory ring (DO restarted or never created). Provable only when
    // the detach persisted lastEnqueued and the spill covers the gap.
    const persisted = meta.lastEnqueuedBySrc?.[src];
    if (persisted === undefined) {
      // A detached leg always persists this map, including an empty map. An
      // absent map means the DO restarted while the leg was live and its
      // in-memory ring may have been lost, so even ack=0 is not provable.
      return meta.lastEnqueuedBySrc !== undefined && ack === 0 ? [] : null;
    }
    if (ack > persisted) return null;
    if (ack === persisted) return [];
    const spilled = await this.ctx.storage.list<ArrayBuffer>({ prefix: spillPrefix(dst, src) });
    const frames: ArrayBuffer[] = [];
    let expected = ack + 1;
    for (const [key, value] of spilled) {
      const seq = Number(key.slice(spillPrefix(dst, src).length));
      if (seq <= ack) continue;
      if (seq !== expected) return null;
      frames.push(value);
      expected += 1;
    }
    if (expected !== persisted + 1) return null;
    // Rebuild the ring so post-resume acks prune correctly.
    const rebuilt = this.ring(dst, src);
    let seq = ack + 1;
    for (const data of frames) {
      rebuilt.push(seq, data);
      seq += 1;
    }
    return frames;
  }

  private async handleAuthRefresh(ws: WebSocket, att: WsAttachment, token: string): Promise<void> {
    const user = await verifyAccessToken(token, this.env);
    if (!user || user.id !== att.userId) {
      ws.close(CLOSE_UNAUTHORIZED, "auth refresh rejected");
      return;
    }
    const deadline = cacheDeadline(Date.now(), tokenExpiryMs(token), RELAY_MAX_SUBSCRIBE_AGE_MS);
    const updated: WsAttachment = { ...att, expiresAt: deadline };
    ws.serializeAttachment(updated);
    this.send(ws, { t: "auth.ok", deadline });
    await this.ensureAlarmAt(deadline + AUTH_GRACE_MS);
  }

  private handleAck(att: WsAttachment, seq: number, leg?: number): void {
    if (att.legId === undefined) return;
    if (att.role === "host" && leg === undefined) return;
    const src = att.role === "phone" ? "h" : String(leg);
    this.rings.get(ringId(destKey(att.role, att.legId), src))?.ackTo(seq);
  }

  // ---- data frames ----

  private async handleData(ws: WebSocket, att: WsAttachment, frame: ArrayBuffer): Promise<void> {
    if (att.legId === undefined) {
      ws.close(CLOSE_PROTOCOL_ERROR, "data before hello");
      return;
    }
    const header = decodeDataHeader(frame);
    if (!header) {
      ws.close(CLOSE_PROTOCOL_ERROR, "bad data frame");
      return;
    }
    if (att.role === "phone") {
      // Uploads go to the host; stamp the source leg id before forwarding.
      // The ring is keyed by ROLE ("h"), so uploads while the Mac is briefly
      // away buffer for its resume instead of dropping.
      rewriteLegId(frame, att.legId);
      const ring = this.ring("h", String(att.legId));
      ring.push(header.seq, frame);
      if (ring.broken) {
        ws.close(CLOSE_CAPACITY, "upload replay capacity exceeded");
        return;
      }
      const host = this.hostSocket();
      if (host) this.forward(host, frame, ring);
      this.send(ws, { t: "ackup", seq: ring.lastEnqueued });
      return;
    }
    // Host upload: header.legId names the destination phone leg.
    if (header.legId === 0) {
      ws.close(CLOSE_PROTOCOL_ERROR, "missing destination leg");
      return;
    }
    const dest = this.socketFor(header.legId);
    const destinationAttachment = dest ? attachment(dest) : await this.ctx.storage.get<LegMeta>(legKey(header.legId));
    if (!destinationAttachment || destinationAttachment.role !== "phone") {
      ws.close(CLOSE_PROTOCOL_ERROR, "unknown destination leg");
      return;
    }
    const ring = this.ring(String(header.legId), "h");
    ring.push(header.seq, frame);
    if (ring.broken) {
      ws.close(CLOSE_CAPACITY, "upload replay capacity exceeded");
      return;
    }
    if (dest) this.forward(dest, frame, ring);
    this.send(ws, { t: "ackup", seq: ring.lastEnqueued, leg: header.legId });
  }

  private forward(ws: WebSocket, frame: ArrayBuffer, ring: ReplayRing): void {
    try {
      ws.send(frame);
    } catch {
      // Socket is dead; the frame stays in the ring for the resume replay.
    }
  }

  // ---- detach / cleanup ----

  private async detachLeg(ws: WebSocket, reason: string): Promise<void> {
    const att = attachment(ws);
    if (!att || att.legId === undefined) return;
    const legId = att.legId;
    if (this.socketsByLeg.get(legId) === ws) this.socketsByLeg.delete(legId);
    // A resume superseded this socket: the leg is alive on a newer socket, so
    // detach bookkeeping (spill, GC clock, peer.offline) must not run.
    const survivor = this.socketFor(legId);
    if (survivor !== null && survivor !== ws) return;

    const meta = await this.ctx.storage.get<LegMeta>(legKey(legId));
    if (meta) {
      // Persist per-source lastEnqueued + spill un-acked frames so a resume
      // stays provable across DO restarts. Oversized frames mark the leg
      // broken instead (resume will fail closed).
      const dstId = destKey(att.role, legId);
      const lastEnqueuedBySrc: Record<string, number> = {};
      let broken = false;
      const spillWrites: Record<string, ArrayBuffer> = {};
      for (const [id, ring] of this.rings) {
        const [dst, src] = id.split("<");
        if (dst !== dstId) continue;
        lastEnqueuedBySrc[src!] = ring.lastEnqueued;
        if (ring.broken) broken = true;
        for (const entry of ring.pendingEntries()) {
          if (entry.frame.byteLength > MAX_SPILL_FRAME_BYTES) {
            broken = true;
            continue;
          }
          spillWrites[spillKey(dstId, src!, entry.seq)] = entry.frame;
        }
      }
      meta.lastEnqueuedBySrc = lastEnqueuedBySrc;
      meta.broken = broken || meta.broken;
      meta.detachedAt = Date.now();
      await this.ctx.storage.put(legKey(legId), meta);
      if (Object.keys(spillWrites).length > 0) {
        await this.ctx.storage.put(spillWrites);
      }
      await this.ensureAlarmAt(meta.detachedAt + RESUME_TTL_MS);
    }

    // Do not emit peer.offline here. A dropped WebSocket is normally a
    // resumable leg blip, and announcing it would make the application close
    // an otherwise continuous E2E session before the resume grace expires.
    // A genuinely fresh leg is announced by handleHello with its new leg id;
    // consumers use that generation change to retire the old session.
  }

  private async dropLegState(legId: number | undefined, role?: Role): Promise<void> {
    if (legId === undefined) return;
    this.socketsByLeg.delete(legId);
    const meta = role === undefined ? await this.ctx.storage.get<LegMeta>(legKey(legId)) : null;
    const resolvedRole: Role = role ?? meta?.role ?? "phone";
    const dst = destKey(resolvedRole, legId);
    for (const id of [...this.rings.keys()]) {
      const [ringDst, src] = id.split("<");
      // Drop the leg's download streams; for a phone leg also drop its upload
      // stream into the host ring (a fresh session restarts seq at 1 — stale
      // frames from the dead session must not replay into a host resume).
      if (ringDst === dst || (resolvedRole === "phone" && ringDst === "h" && src === String(legId))) {
        this.rings.delete(id);
      }
    }
    await this.ctx.storage.delete(legKey(legId));
    const prefixes = resolvedRole === "phone"
      ? [`spill:${dst}:`, `spill:h:${legId}:`]
      : [`spill:${dst}:`];
    for (const prefix of prefixes) {
      const spilled = await this.ctx.storage.list({ prefix });
      if (spilled.size > 0) await this.ctx.storage.delete([...spilled.keys()]);
    }
  }

  // ---- alarm: auth deadlines, hello timeouts, resume-state GC ----

  override async alarm(): Promise<void> {
    const now = Date.now();
    let next: number | null = null;
    const consider = (at: number) => {
      if (at > now && (next === null || at < next)) next = at;
    };

    for (const ws of this.ctx.getWebSockets()) {
      const att = attachment(ws);
      if (!att) continue;
      if (att.legId === undefined) {
        const helloDeadline = att.acceptedAt + HELLO_TIMEOUT_MS;
        if (helloDeadline <= now) {
          ws.close(CLOSE_PROTOCOL_ERROR, "hello timeout");
          continue;
        }
        consider(helloDeadline);
      }
      const authDeadline = att.expiresAt + AUTH_GRACE_MS;
      if (authDeadline <= now) {
        ws.close(CLOSE_UNAUTHORIZED, "auth expired");
        continue;
      }
      consider(authDeadline);
    }

    // GC resume state for legs that never came back.
    const metas = await this.ctx.storage.list<LegMeta>({ prefix: "leg:" });
    for (const [key, meta] of metas) {
      const legId = Number(key.slice("leg:".length));
      if (meta.detachedAt !== undefined) {
        const gcAt = meta.detachedAt + RESUME_TTL_MS;
        if (gcAt <= now && this.socketFor(legId) === null) {
          await this.dropLegState(legId);
          continue;
        }
        consider(gcAt);
      } else if (this.socketFor(legId) === null && this.ctx.getWebSockets().length === 0) {
        // Meta without a socket or detach marker: the DO restarted while the
        // leg was live. Start the GC clock now.
        meta.detachedAt = now;
        await this.ctx.storage.put(key, meta);
        consider(now + RESUME_TTL_MS);
      }
    }

    if (next !== null) await this.ctx.storage.setAlarm(next);
  }

  private async ensureAlarmAt(at: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > at) {
      await this.ctx.storage.setAlarm(at);
    }
  }

  // ---- helpers ----

  private ring(dst: string, src: string): ReplayRing {
    const id = ringId(dst, src);
    let ring = this.rings.get(id);
    if (!ring) {
      ring = new ReplayRing();
      this.rings.set(id, ring);
    }
    return ring;
  }

  private liveLegs(role: Role): WebSocket[] {
    return this.ctx.getWebSockets(role);
  }

  private hostSocket(): WebSocket | null {
    for (const ws of this.liveLegs("host")) {
      if (attachment(ws)?.legId !== undefined) return ws;
    }
    return null;
  }

  private socketFor(legId: number): WebSocket | null {
    const cached = this.socketsByLeg.get(legId);
    if (cached) return cached;
    for (const ws of this.ctx.getWebSockets()) {
      const att = attachment(ws);
      if (att?.legId === legId) {
        this.socketsByLeg.set(legId, ws);
        return ws;
      }
    }
    return null;
  }

  private async nextLegId(): Promise<number> {
    const current = (await this.ctx.storage.get<number>("nextLegId")) ?? 0;
    const next = current + 1;
    await this.ctx.storage.put("nextLegId", next);
    return next;
  }

  private async epoch(): Promise<string> {
    let epoch = await this.ctx.storage.get<string>("epoch");
    if (!epoch) {
      epoch = crypto.randomUUID();
      await this.ctx.storage.put("epoch", epoch);
    }
    return epoch;
  }

  private send(ws: WebSocket, frame: ControlFrame): void {
    try {
      ws.send(encodeControl(frame));
    } catch {
      // Dead socket; close/error handlers own the cleanup.
    }
  }
}
