// AccountRelay — the dor/1 data-plane Durable Object.
//
// ONE instance per Stack account user, named `dor:user:<userId>` by the
// worker AFTER Stack auth, so unauthenticated callers can never materialize
// (or even address) an object. ALL of the account's Mac↔phone traffic flows
// through this single object: each Mac parks one standing "host" leg (keyed
// by its device id), each phone opens a "phone" leg bound to exactly one Mac.
// Binary frames route on a fixed 14-byte header; payloads are opaque
// (E2E-encrypted by the apps).
//
// Reliability: every directed stream (mac→phone, and phone→mac per phone) is
// sender-sequenced. The relay keeps a bounded in-memory replay ring per
// stream, prunes it on receiver acks, and on a leg redial replays the gap iff
// it can PROVE coverage (ReplayRing.coversGap). When a leg detaches with
// un-acked frames the ring spills to storage so the proof survives DO
// restarts/hibernation; the both-connected steady state performs zero storage
// writes per frame.
//
// Auth: the worker forwards a verified deadline (token exp capped at 15 min).
// Legs extend it in-band with `auth.refresh` (re-verified against Stack from
// here, pinned to the same user) so a healthy connection never tears down for
// token rotation.

import { DurableObject } from "cloudflare:workers";

import { verifyRequest, cacheDeadline, tokenExpiryMs, type AuthEnv } from "./auth";
import {
  AUTH_GRACE_MS,
  CLOSE_CAPACITY,
  CLOSE_PROTOCOL_ERROR,
  CLOSE_SUPERSEDED,
  CLOSE_UNAUTHORIZED,
  DOR_MAX_SUBSCRIBE_AGE_MS,
  DOR_PROTOCOL,
  HELLO_TIMEOUT_MS,
  MAX_CONTROL_BYTES,
  MAX_HOST_LEGS,
  MAX_PHONE_LEGS,
  ReplayRing,
  decodeControl,
  decodeDataHeader,
  encodeControl,
  hostKey,
  mintResumeKey,
  phoneKey,
  rewriteLegId,
  sha256Base64,
  spillKey,
  spillPrefix,
  streamId,
  type ControlFrame,
} from "./dorProtocol";

/** Detached-leg state (meta + spilled ring) is kept this long for resume. */
export const RESUME_TTL_MS = 10 * 60 * 1000;
/** DO storage values cap at 128 KiB; larger frames cannot spill. Clients keep
 * chunks ≤ 96 KiB so this limit is never hit in practice. */
const MAX_SPILL_FRAME_BYTES = 120 * 1024;

type Role = "host" | "phone";

interface WsAttachment {
  role: Role;
  userId: string;
  device: string;
  /** The Mac this leg belongs to: the host's own device id, or the phone
   * leg's bound target. */
  mac: string;
  expiresAt: number;
  acceptedAt: number;
  legId?: number;
}

interface LegMeta {
  role: Role;
  device: string;
  mac: string;
  resumeKeyHash: string;
  /** Persisted on detach: last enqueued seq per source endpoint key. Its
   * presence is what makes a resume provable across a DO restart. */
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

function legStorageKey(legId: number): string {
  return `leg:${legId}`;
}

/** Endpoint key this leg RECEIVES on (its download streams' dst). */
function destKeyFor(att: { role: Role; mac: string; legId: number }): string {
  return att.role === "host" ? hostKey(att.mac) : phoneKey(att.legId);
}

export class AccountRelay extends DurableObject<RelayEnv> {
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
    const role = request.headers.get("x-dor-role") as Role | null;
    const userId = request.headers.get("x-dor-user-id")?.trim();
    const device = request.headers.get("x-dor-device")?.trim();
    const mac = request.headers.get("x-dor-mac")?.trim();
    if ((role !== "host" && role !== "phone") || !userId || !device || !mac) {
      return new Response(JSON.stringify({ error: "bad_gateway_headers" }), { status: 500 });
    }
    const now = Date.now();
    const expiresAt = resolveDeadline(request.headers.get("x-dor-expires-at"), now);
    if (expiresAt === null) {
      return new Response(JSON.stringify({ error: "subscription_expired" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }
    const cap = role === "phone" ? MAX_PHONE_LEGS : MAX_HOST_LEGS;
    if (this.liveLegs(role).length >= cap) {
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
      mac,
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
    this.handleData(ws, att, message);
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    await this.detachLeg(ws, "closed");
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.detachLeg(ws, "error");
  }

  // ---- control frames ----

  private async handleControl(ws: WebSocket, att: WsAttachment, text: string): Promise<void> {
    if (text.length > MAX_CONTROL_BYTES) {
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
    if (frame.proto !== DOR_PROTOCOL) {
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

    let legId: number | null = null;
    let replayed = 0;
    if (frame.resume) {
      const resumed = await this.tryResume(ws, att, frame);
      if (resumed === "failed") return; // tryResume already replied/closed
      if (resumed !== null) {
        legId = resumed.legId;
        replayed = resumed.replayed;
      }
    }

    if (legId === null) {
      // Fresh session: supersede any live leg for the same logical endpoint —
      // (host, mac) has exactly one leg; (phone, device, mac) likewise — and
      // drop the superseded leg's resumable state (the caller started over).
      for (const other of this.liveLegs(att.role)) {
        if (other === ws) continue;
        const otherAtt = attachment(other);
        if (!otherAtt || otherAtt.mac !== att.mac) continue;
        const sameEndpoint = att.role === "host" || otherAtt.device === att.device;
        if (!sameEndpoint) continue;
        await this.dropLegState(otherAtt.legId, otherAtt);
        other.close(CLOSE_SUPERSEDED, "superseded by a new session");
      }
      if (att.role === "host") {
        // A fresh host process cannot decrypt frames phones buffered for the
        // previous one: clear every stream destined to this Mac so stale
        // ciphertext never replays into the new session.
        const dst = hostKey(att.mac);
        for (const id of [...this.rings.keys()]) {
          if (id.startsWith(`${dst}<`)) this.rings.delete(id);
        }
        const staleSpill = await this.ctx.storage.list({ prefix: `spill:${dst}:` });
        if (staleSpill.size > 0) await this.ctx.storage.delete([...staleSpill.keys()]);
      }
      legId = await this.nextLegId();
    }

    const resumeKey = mintResumeKey();
    const meta: LegMeta = {
      role: att.role,
      device: att.device,
      mac: att.mac,
      resumeKeyHash: await sha256Base64(resumeKey),
    };
    await this.ctx.storage.put(legStorageKey(legId), meta);

    const updated: WsAttachment = { ...att, legId };
    ws.serializeAttachment(updated);
    this.socketsByLeg.set(legId, ws);

    this.send(ws, {
      t: "hello.ack",
      legId,
      resumeKey,
      epoch: await this.epoch(),
      peerOnline:
        att.role === "host"
          ? this.phoneLegsBound(att.mac).length > 0
          : this.hostSocket(att.mac) !== null,
      replayed,
    });

    // Presence notifications to the other side (scoped to this Mac).
    if (att.role === "host") {
      for (const phone of this.phoneLegsBound(att.mac)) {
        this.send(phone, { t: "peer.online" });
        const phoneAtt = attachment(phone);
        if (phoneAtt?.legId !== undefined) {
          this.send(ws, { t: "peer.online", legId: phoneAtt.legId, device: phoneAtt.device });
        }
      }
    } else {
      const host = this.hostSocket(att.mac);
      if (host) this.send(host, { t: "peer.online", legId, device: att.device });
    }
    await this.ensureAlarmAt(att.expiresAt + AUTH_GRACE_MS);
  }

  /** Attempt a resume. Returns null to fall through to a fresh session (no
   * matching prior state), "failed" when the caller must re-handshake
   * (already replied), or the rebound leg. */
  private async tryResume(
    ws: WebSocket,
    att: WsAttachment,
    frame: Extract<ControlFrame, { t: "hello" }>,
  ): Promise<{ legId: number; replayed: number } | "failed" | null> {
    const hash = await sha256Base64(frame.resume!);
    const metas = await this.ctx.storage.list<LegMeta>({ prefix: "leg:" });
    let legId: number | null = null;
    let meta: LegMeta | null = null;
    for (const [key, value] of metas) {
      if (
        value.role === att.role &&
        value.device === att.device &&
        value.mac === att.mac &&
        value.resumeKeyHash === hash
      ) {
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
      await this.dropLegState(legId, { role: att.role, mac: att.mac });
      this.send(ws, { t: "resume.failed", reason: "buffer overflow" });
      ws.close(CLOSE_PROTOCOL_ERROR, "resume failed");
      return "failed";
    }

    // Close a lingering socket still bound to this leg (network-limbo redial).
    const lingering = this.socketFor(legId);
    if (lingering && lingering !== ws) {
      lingering.close(CLOSE_SUPERSEDED, "superseded by resume");
      this.socketsByLeg.delete(legId);
    }

    // Prove and replay every download stream this leg consumes.
    const dst = destKeyFor({ role: att.role, mac: att.mac, legId });
    const claimed: Array<{ src: string; ack: number }> =
      att.role === "phone"
        ? [{ src: hostKey(att.mac), ack: frame.ack ?? 0 }]
        : Object.entries(frame.acks ?? {}).map(([leg, ack]) => ({
            src: phoneKey(Number(leg)),
            ack,
          }));
    // A Mac resume must also prove every phone stream it did NOT list (live
    // ring or spilled state): un-acked frames from an unlisted source would
    // be a silent gap otherwise.
    if (att.role === "host") {
      const listed = new Set(claimed.map((entry) => entry.src));
      for (const [id, ring] of this.rings) {
        const [ringDst, src] = id.split("<");
        if (ringDst === dst && src && !listed.has(src) && ring.lastEnqueued > 0) {
          claimed.push({ src, ack: 0 });
          listed.add(src);
        }
      }
      for (const src of Object.keys(meta.lastEnqueuedBySrc ?? {})) {
        if (!listed.has(src)) {
          claimed.push({ src, ack: 0 });
          listed.add(src);
        }
      }
    }
    let replayed = 0;
    for (const { src, ack } of claimed) {
      const proof = await this.provableReplay(dst, src, ack, meta);
      if (proof === null) {
        await this.dropLegState(legId, { role: att.role, mac: att.mac });
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

    // Re-attach: clear detach markers (stops the GC clock) and drop consumed
    // spill rows — the rebuilt in-memory rings own replay from here.
    delete meta.detachedAt;
    delete meta.lastEnqueuedBySrc;
    await this.ctx.storage.put(legStorageKey(legId), meta);
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
    const ring = this.rings.get(streamId(dst, src));
    if (ring) {
      if (!ring.coversGap(ack)) return null;
      return ring.replayAfter(ack);
    }
    // No in-memory ring (DO restarted or stream never carried data). Provable
    // only when detach persisted lastEnqueued and the spill covers the gap.
    const persisted = meta.lastEnqueuedBySrc?.[src];
    if (persisted === undefined) {
      return ack === 0 ? [] : null;
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
    const user = await verifyRequest(
      new Request("https://relay.internal/", { headers: { authorization: `Bearer ${token}` } }),
      this.env,
    );
    if (!user || user.id !== att.userId) {
      ws.close(CLOSE_UNAUTHORIZED, "auth refresh rejected");
      return;
    }
    const deadline = cacheDeadline(Date.now(), tokenExpiryMs(token), DOR_MAX_SUBSCRIBE_AGE_MS);
    const updated: WsAttachment = { ...att, expiresAt: deadline };
    ws.serializeAttachment(updated);
    this.send(ws, { t: "auth.ok", deadline });
    await this.ensureAlarmAt(deadline + AUTH_GRACE_MS);
  }

  private handleAck(att: WsAttachment, seq: number, leg?: number): void {
    if (att.legId === undefined) return;
    if (att.role === "host" && leg === undefined) return;
    const dst = destKeyFor({ role: att.role, mac: att.mac, legId: att.legId });
    const src = att.role === "phone" ? hostKey(att.mac) : phoneKey(leg!);
    this.rings.get(streamId(dst, src))?.ackTo(seq);
  }

  // ---- data frames ----

  private handleData(ws: WebSocket, att: WsAttachment, frame: ArrayBuffer): void {
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
      // Uploads go to the bound Mac; stamp the source leg id first. The ring
      // keys on the MAC ("h:<mac>"), so uploads while it is briefly away
      // buffer for its resume instead of dropping.
      rewriteLegId(frame, att.legId);
      const ring = this.ring(hostKey(att.mac), phoneKey(att.legId));
      ring.push(header.seq, frame);
      const host = this.hostSocket(att.mac);
      if (host) this.forward(host, frame);
      this.send(ws, { t: "ackup", seq: ring.lastEnqueued });
      return;
    }
    // Host upload: header.legId names the destination phone leg, which must
    // be bound to THIS Mac (an account's Macs must not inject into each
    // other's phone streams).
    const dest = this.socketFor(header.legId);
    const destAtt = dest ? attachment(dest) : null;
    if (destAtt && (destAtt.role !== "phone" || destAtt.mac !== att.mac)) {
      ws.close(CLOSE_PROTOCOL_ERROR, "destination not bound to this mac");
      return;
    }
    const ring = this.ring(phoneKey(header.legId), hostKey(att.mac));
    ring.push(header.seq, frame);
    if (dest && destAtt) this.forward(dest, frame);
    this.send(ws, { t: "ackup", seq: ring.lastEnqueued, leg: header.legId });
  }

  private forward(ws: WebSocket, frame: ArrayBuffer): void {
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
    // A resume superseded this socket: the leg lives on a newer socket, so
    // detach bookkeeping (spill, GC clock, peer.offline) must not run.
    const survivor = this.socketFor(legId);
    if (survivor !== null && survivor !== ws) return;

    const meta = await this.ctx.storage.get<LegMeta>(legStorageKey(legId));
    if (meta) {
      // Persist per-source lastEnqueued + spill un-acked frames so a resume
      // stays provable across DO restarts. Oversized frames mark the leg
      // broken instead (resume fails closed).
      const dst = destKeyFor({ role: att.role, mac: att.mac, legId });
      const lastEnqueuedBySrc: Record<string, number> = {};
      let broken = false;
      const spillWrites: Record<string, ArrayBuffer> = {};
      for (const [id, ring] of this.rings) {
        const [ringDst, src] = id.split("<");
        if (ringDst !== dst || !src) continue;
        lastEnqueuedBySrc[src] = ring.lastEnqueued;
        if (ring.broken) broken = true;
        for (const entry of ring.pendingEntries()) {
          if (entry.frame.byteLength > MAX_SPILL_FRAME_BYTES) {
            broken = true;
            continue;
          }
          spillWrites[spillKey(dst, src, entry.seq)] = entry.frame;
        }
      }
      meta.lastEnqueuedBySrc = lastEnqueuedBySrc;
      meta.broken = broken || meta.broken;
      meta.detachedAt = Date.now();
      await this.ctx.storage.put(legStorageKey(legId), meta);
      if (Object.keys(spillWrites).length > 0) {
        await this.ctx.storage.put(spillWrites);
      }
      await this.ensureAlarmAt(meta.detachedAt + RESUME_TTL_MS);
    }

    // Presence notification for the surviving side (scoped to this Mac).
    if (att.role === "host") {
      for (const phone of this.phoneLegsBound(att.mac)) {
        this.send(phone, { t: "peer.offline", reason });
      }
    } else {
      const host = this.hostSocket(att.mac);
      if (host) this.send(host, { t: "peer.offline", legId, reason });
    }
  }

  private async dropLegState(
    legId: number | undefined,
    hint?: { role: Role; mac: string },
  ): Promise<void> {
    if (legId === undefined) return;
    this.socketsByLeg.delete(legId);
    const meta = hint ? null : await this.ctx.storage.get<LegMeta>(legStorageKey(legId));
    const role: Role = hint?.role ?? meta?.role ?? "phone";
    const mac = hint?.mac ?? meta?.mac ?? "";
    const dst = destKeyFor({ role, mac, legId });
    for (const id of [...this.rings.keys()]) {
      const [ringDst, src] = id.split("<");
      // Drop the leg's download streams; for a phone leg also drop its upload
      // stream into the Mac's ring (a fresh session restarts seq at 1 — stale
      // frames from the dead session must not replay into a Mac resume).
      if (ringDst === dst || (role === "phone" && ringDst === hostKey(mac) && src === phoneKey(legId))) {
        this.rings.delete(id);
      }
    }
    await this.ctx.storage.delete(legStorageKey(legId));
    const prefixes =
      role === "phone"
        ? [`spill:${dst}:`, `spill:${hostKey(mac)}:${phoneKey(legId)}:`]
        : [`spill:${dst}:`];
    for (const prefix of prefixes) {
      const spilled = await this.ctx.storage.list({ prefix });
      if (spilled.size > 0) await this.ctx.storage.delete([...spilled.keys()]);
    }
  }

  // ---- alarm: hello timeouts, auth deadlines, resume-state GC ----

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
          await this.dropLegState(legId, { role: meta.role, mac: meta.mac });
          continue;
        }
        consider(gcAt);
      } else if (this.socketFor(legId) === null) {
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
    const id = streamId(dst, src);
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

  /** Live phone legs bound to one Mac (post-hello only). */
  private phoneLegsBound(mac: string): WebSocket[] {
    return this.liveLegs("phone").filter((ws) => {
      const att = attachment(ws);
      return att?.mac === mac && att.legId !== undefined;
    });
  }

  /** The live host socket for one Mac, or null. */
  private hostSocket(mac: string): WebSocket | null {
    for (const ws of this.liveLegs("host")) {
      const att = attachment(ws);
      if (att?.mac === mac && att.legId !== undefined) return ws;
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

/** Verified deadline forwarded by the worker; null when already expired. */
function resolveDeadline(header: string | null, now: number): number | null {
  const parsed = Number(header);
  if (!Number.isFinite(parsed)) return null;
  const capped = Math.min(parsed, now + DOR_MAX_SUBSCRIBE_AGE_MS);
  return capped > now ? capped : null;
}
