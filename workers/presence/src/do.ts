// TeamPresence Durable Object — one instance per team (idFromName(teamId)).
//
// Holds the team's ephemeral presence map in DO storage and fans transitions
// out to subscribers. Offline is an explicit event produced by the DO alarm
// when an instance misses heartbeats (see core.ts for the cadence rationale),
// never something clients infer from staleness.
//
// Subscribers come in two transports sharing one broadcast path:
//   - WebSocket (primary, hibernation API: idle teams cost nothing)
//   - SSE (curl-friendly; keeps the DO pinned while connected, acceptable for
//     the small per-team subscriber counts presence has)
//
// Authorization happens in the worker before anything reaches this object; the
// DO trusts its caller. Isolation is by construction: the worker derives the
// DO id from the verified team id, so one team's object can never be reached
// with another team's credentials.

import { DurableObject } from "cloudflare:workers";
import {
  applyHeartbeat,
  buildSnapshot,
  expireInstances,
  HEARTBEAT_INTERVAL_MS,
  nextAlarmTime,
  OFFLINE_TIMEOUT_MS,
  shouldPrune,
  type HeartbeatInput,
  type PresenceEvent,
  type PresenceInstance,
} from "./core";

const INSTANCE_PREFIX = "inst:";
const TEAM_ID_KEY = "meta:teamId";
/** Mirrors the registry caps (200 devices x 25 instances per device). */
const MAX_INSTANCES_PER_TEAM = 5000;
/** Combined WebSocket + SSE subscriber cap per team. */
const MAX_SUBSCRIBERS_PER_TEAM = 64;
/** Drop an SSE subscriber once this many frames sit unread in its stream
 * buffer (the client stopped consuming); prevents a stalled reader from
 * pinning unbounded memory on every 15s heartbeat tick. */
const SSE_MAX_BUFFERED_FRAMES = 256;

/** Subscriptions are bounded: the worker passes a deadline (token expiry
 * capped at this max age) and the DO refuses to deliver past it and closes
 * the stream, so a revoked token or removed team member cannot keep an old
 * stream alive indefinitely. Clients resubscribe with a fresh token; the
 * snapshot-first protocol makes reconnects cheap and consistent. */
export const MAX_SUBSCRIBE_AGE_MS = 15 * 60 * 1000;

interface SseSubscriber {
  controller: ReadableStreamDefaultController<Uint8Array>;
  expiresAt: number;
}

interface WsAttachment {
  expiresAt: number;
}

function wsExpiresAt(ws: WebSocket): number {
  try {
    const attachment = ws.deserializeAttachment() as WsAttachment | null;
    return typeof attachment?.expiresAt === "number" ? attachment.expiresAt : 0;
  } catch {
    return 0;
  }
}

export interface HeartbeatResponse {
  ok: true;
  teamId: string;
  heartbeatIntervalMs: number;
  offlineTimeoutMs: number;
  instance: PresenceInstance;
}

function instanceKey(deviceId: string, tag: string): string {
  // deviceId is a validated fixed-format UUID, so the composite key is
  // unambiguous even though tags may contain ":".
  return `${INSTANCE_PREFIX}${deviceId}:${tag}`;
}

export class TeamPresence extends DurableObject {
  /** Live SSE subscribers; in-memory only. An evicted DO drops the streams and
   * clients reconnect, which re-delivers a fresh snapshot. */
  private sseSubscribers = new Set<SseSubscriber>();
  private encoder = new TextEncoder();

  // ---- RPC surface (called by the worker) ----

  async heartbeat(teamId: string, beat: HeartbeatInput): Promise<HeartbeatResponse | { error: string }> {
    await this.rememberTeamId(teamId);
    const now = Date.now();
    const key = instanceKey(beat.deviceId, beat.tag);
    const existing = await this.ctx.storage.get<PresenceInstance>(key);

    if (!existing && beat.stopping) {
      // A goodbye from an instance we never saw: nothing to record or announce.
      return this.heartbeatOk(teamId, {
        deviceId: beat.deviceId,
        tag: beat.tag,
        platform: beat.platform,
        displayName: beat.displayName,
        capabilities: beat.capabilities ?? [],
        online: false,
        lastSeenAt: now,
        offlineAt: now,
      });
    }

    if (!existing) {
      const count = (await this.ctx.storage.list({ prefix: INSTANCE_PREFIX, limit: MAX_INSTANCES_PER_TEAM })).size;
      if (count >= MAX_INSTANCES_PER_TEAM) return { error: "too_many_instances" };
    }

    const { instance, events } = applyHeartbeat(existing, beat, now);
    await this.ctx.storage.put(key, instance);
    this.broadcast(events);
    await this.ensureAlarmFor(instance);
    return this.heartbeatOk(teamId, instance);
  }

  async snapshot(teamId: string): Promise<string> {
    await this.rememberTeamId(teamId);
    return JSON.stringify(buildSnapshot(teamId, await this.allInstances(), Date.now()));
  }

  // ---- Subscribe transports (worker forwards the original Request) ----

  override async fetch(request: Request): Promise<Response> {
    const teamId = request.headers.get("x-presence-team-id");
    if (!teamId) return new Response("missing team", { status: 500 });
    await this.rememberTeamId(teamId);

    const now = Date.now();
    // Deadline computed by the worker from the verified token (expiry capped
    // at MAX_SUBSCRIBE_AGE_MS); never client-supplied.
    const expiresHeader = Number(request.headers.get("x-presence-expires-at"));
    const expiresAt = Number.isFinite(expiresHeader) && expiresHeader > now
      ? expiresHeader
      : now + MAX_SUBSCRIBE_AGE_MS;

    if (this.subscriberCount() >= MAX_SUBSCRIBERS_PER_TEAM) {
      return new Response(JSON.stringify({ error: "too_many_subscribers" }), {
        status: 429,
        headers: { "content-type": "application/json" },
      });
    }

    if (request.headers.get("upgrade")?.toLowerCase() === "websocket") {
      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      // Hibernation API: the DO can be evicted while sockets stay connected.
      // The deadline rides the socket attachment so it survives hibernation.
      this.ctx.acceptWebSocket(server);
      server.serializeAttachment({ expiresAt } satisfies WsAttachment);
      server.send(await this.snapshot(teamId));
      await this.ensureAlarmAt(expiresAt);
      return new Response(null, { status: 101, webSocket: client });
    }

    // SSE fallback for clients without WebSockets (and curl transcripts).
    const snapshotJson = await this.snapshot(teamId);
    const subscribers = this.sseSubscribers;
    const encoder = this.encoder;
    let entry: SseSubscriber | null = null;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        entry = { controller, expiresAt };
        subscribers.add(entry);
        controller.enqueue(encoder.encode(`event: snapshot\ndata: ${snapshotJson}\n\n`));
      },
      cancel() {
        if (entry) subscribers.delete(entry);
      },
    });
    await this.ensureAlarmAt(expiresAt);
    return new Response(stream, {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-store",
        connection: "keep-alive",
      },
    });
  }

  // The subscribe stream is one-way; inbound WS messages are ignored.
  override async webSocketMessage(): Promise<void> {}

  override async webSocketClose(ws: WebSocket): Promise<void> {
    try {
      ws.close();
    } catch {
      // already closed
    }
  }

  // ---- Alarm: timeout-offline transitions and pruning ----

  override async alarm(): Promise<void> {
    const now = Date.now();
    const all = await this.allEntries();
    const { expired, events } = expireInstances([...all.values()], now);
    for (const instance of expired) {
      await this.ctx.storage.put(instanceKey(instance.deviceId, instance.tag), instance);
      all.set(instanceKey(instance.deviceId, instance.tag), instance);
    }
    for (const [key, instance] of all) {
      if (shouldPrune(instance, now)) {
        await this.ctx.storage.delete(key);
        all.delete(key);
      }
    }
    this.broadcast(events);
    this.closeExpiredSubscribers(now);
    const candidates = [nextAlarmTime([...all.values()]), this.nextSubscriberDeadline()]
      .filter((value): value is number => value !== null);
    if (candidates.length > 0) {
      await this.ctx.storage.setAlarm(Math.max(Math.min(...candidates), now + 1000));
    }
  }

  // ---- Internals ----

  private heartbeatOk(teamId: string, instance: PresenceInstance): HeartbeatResponse {
    return {
      ok: true,
      teamId,
      heartbeatIntervalMs: HEARTBEAT_INTERVAL_MS,
      offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
      instance,
    };
  }

  /** Persist the team id on first contact so alarm-driven broadcasts can build
   * snapshots without a live request context. */
  private async rememberTeamId(teamId: string): Promise<void> {
    const known = await this.ctx.storage.get<string>(TEAM_ID_KEY);
    if (known !== teamId) await this.ctx.storage.put(TEAM_ID_KEY, teamId);
  }

  private async allEntries(): Promise<Map<string, PresenceInstance>> {
    return await this.ctx.storage.list<PresenceInstance>({ prefix: INSTANCE_PREFIX });
  }

  private async allInstances(): Promise<PresenceInstance[]> {
    return [...(await this.allEntries()).values()];
  }

  /** Make sure the alarm fires no later than this instance's next deadline.
   * The alarm handler itself reschedules from the full map, so per-heartbeat
   * scheduling only needs the cheap min() against the currently set alarm. */
  private async ensureAlarmFor(instance: PresenceInstance): Promise<void> {
    const due = instance.online
      ? instance.lastSeenAt + OFFLINE_TIMEOUT_MS
      : (instance.offlineAt ?? instance.lastSeenAt) + OFFLINE_TIMEOUT_MS;
    await this.ensureAlarmAt(due);
  }

  /** Pull the alarm earlier if `due` precedes the currently scheduled one
   * (also used for subscriber-deadline closes). */
  private async ensureAlarmAt(due: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > due) {
      await this.ctx.storage.setAlarm(due);
    }
  }

  private subscriberCount(): number {
    return this.ctx.getWebSockets().length + this.sseSubscribers.size;
  }

  private nextSubscriberDeadline(): number | null {
    let next: number | null = null;
    for (const ws of this.ctx.getWebSockets()) {
      const due = wsExpiresAt(ws);
      if (due > 0 && (next === null || due < next)) next = due;
    }
    for (const subscriber of this.sseSubscribers) {
      if (next === null || subscriber.expiresAt < next) next = subscriber.expiresAt;
    }
    return next;
  }

  private closeExpiredSubscribers(nowMs: number): void {
    for (const ws of this.ctx.getWebSockets()) {
      if (wsExpiresAt(ws) <= nowMs) {
        try {
          ws.close(1000, "subscription expired; reconnect with a fresh token");
        } catch {
          // already closed
        }
      }
    }
    for (const subscriber of [...this.sseSubscribers]) {
      if (subscriber.expiresAt <= nowMs) {
        this.dropSseSubscriber(subscriber);
      }
    }
  }

  private dropSseSubscriber(subscriber: SseSubscriber): void {
    this.sseSubscribers.delete(subscriber);
    try {
      subscriber.controller.close();
    } catch {
      // already errored or cancelled
    }
  }

  private broadcast(events: readonly PresenceEvent[]): void {
    if (events.length === 0) return;
    const now = Date.now();
    for (const event of events) {
      const json = JSON.stringify(event);
      for (const ws of this.ctx.getWebSockets()) {
        // Deadline enforced at delivery too, so an expired subscriber never
        // receives data even if the closing alarm has not fired yet.
        if (wsExpiresAt(ws) <= now) {
          try {
            ws.close(1000, "subscription expired; reconnect with a fresh token");
          } catch {
            // already closed
          }
          continue;
        }
        try {
          ws.send(json);
        } catch {
          // Socket already gone; hibernation API cleans it up.
        }
      }
      const frame = this.encoder.encode(`event: ${event.type}\ndata: ${json}\n\n`);
      for (const subscriber of [...this.sseSubscribers]) {
        if (subscriber.expiresAt <= now) {
          this.dropSseSubscriber(subscriber);
          continue;
        }
        const desired = subscriber.controller.desiredSize;
        if (desired !== null && desired < -SSE_MAX_BUFFERED_FRAMES) {
          // The client stopped reading; cut it loose instead of buffering.
          this.dropSseSubscriber(subscriber);
          continue;
        }
        try {
          subscriber.controller.enqueue(frame);
        } catch {
          this.sseSubscribers.delete(subscriber);
        }
      }
    }
  }
}
