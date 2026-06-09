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
  private sseSubscribers = new Set<{ controller: ReadableStreamDefaultController<Uint8Array> }>();
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

    if (request.headers.get("upgrade")?.toLowerCase() === "websocket") {
      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      // Hibernation API: the DO can be evicted while sockets stay connected.
      this.ctx.acceptWebSocket(server);
      server.send(await this.snapshot(teamId));
      return new Response(null, { status: 101, webSocket: client });
    }

    // SSE fallback for clients without WebSockets (and curl transcripts).
    const snapshotJson = await this.snapshot(teamId);
    const subscribers = this.sseSubscribers;
    const encoder = this.encoder;
    let entry: { controller: ReadableStreamDefaultController<Uint8Array> } | null = null;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        entry = { controller };
        subscribers.add(entry);
        controller.enqueue(encoder.encode(`event: snapshot\ndata: ${snapshotJson}\n\n`));
      },
      cancel() {
        if (entry) subscribers.delete(entry);
      },
    });
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
    const next = nextAlarmTime([...all.values()]);
    if (next !== null) {
      await this.ctx.storage.setAlarm(Math.max(next, now + 1000));
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
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > due) {
      await this.ctx.storage.setAlarm(due);
    }
  }

  private broadcast(events: readonly PresenceEvent[]): void {
    if (events.length === 0) return;
    for (const event of events) {
      const json = JSON.stringify(event);
      for (const ws of this.ctx.getWebSockets()) {
        try {
          ws.send(json);
        } catch {
          // Socket already gone; hibernation API cleans it up.
        }
      }
      const frame = this.encoder.encode(`event: ${event.type}\ndata: ${json}\n\n`);
      for (const subscriber of [...this.sseSubscribers]) {
        try {
          subscriber.controller.enqueue(frame);
        } catch {
          this.sseSubscribers.delete(subscriber);
        }
      }
    }
  }
}
