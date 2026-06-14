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
  checkDeviceOwner,
  checkPresenceCaps,
  expireInstances,
  HEARTBEAT_INTERVAL_MS,
  MAX_DEVICES_PER_TEAM,
  MAX_INSTANCES_PER_DEVICE,
  nextAlarmTime,
  OFFLINE_TIMEOUT_MS,
  resolveSubscribeDeadline,
  shouldPrune,
  type HeartbeatInput,
  type PresenceEvent,
  type PresenceInstance,
} from "./core";
import { parseHello, type SyncServerFrame } from "./sync";
import { gcTombstones, nextTombstoneGcTime, resolveHelloFrames, type SyncStorage } from "./syncStorage";
import {
  DEVICES_COLLECTION,
  groupInstancesByDevice,
  ownersFromList,
  reconcileDeviceRecords,
  reconcileSingleDevice,
  type DeviceRecord,
} from "./syncDevices";

const INSTANCE_PREFIX = "inst:";
/** `owner:<deviceId>` -> Stack user id pinned on first heartbeat. Durable:
 * never pruned with the presence tail (see checkDeviceOwner in core.ts), so
 * an idle device cannot be re-claimed by a co-member. Bounded by
 * MAX_DEVICES_PER_TEAM (owner pins are the DO's device records). */
const OWNER_PREFIX = "owner:";
const TEAM_ID_KEY = "meta:teamId";
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
  /** Sync collections this socket subscribed to via `sync.hello`. Absent/empty
   * for legacy presence-only clients, which must NEVER receive sync frames (the
   * presence decoder throws on unknown message types). Persisted on the socket
   * attachment so it survives DO hibernation. */
  syncCollections?: string[];
}

/** Whether a socket has subscribed to a given sync collection. A legacy
 * presence-only socket (no `sync.hello`) returns false, so sync frames are never
 * broadcast to a client that cannot parse them. */
function wsSyncCollections(ws: WebSocket): string[] {
  try {
    const attachment = ws.deserializeAttachment() as WsAttachment | null;
    return Array.isArray(attachment?.syncCollections) ? attachment.syncCollections : [];
  } catch {
    return [];
  }
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

export interface HeartbeatError {
  error: string;
  status: number;
}

function instanceKey(deviceId: string, tag: string): string {
  // deviceId is a validated fixed-format UUID, so the composite key is
  // unambiguous even though tags may contain ":".
  return `${INSTANCE_PREFIX}${deviceId}:${tag}`;
}

function ownerKey(deviceId: string): string {
  return `${OWNER_PREFIX}${deviceId}`;
}

export class TeamPresence extends DurableObject {
  /** Live SSE subscribers; in-memory only. An evicted DO drops the streams and
   * clients reconnect, which re-delivers a fresh snapshot. */
  private sseSubscribers = new Set<SseSubscriber>();
  private encoder = new TextEncoder();

  // ---- RPC surface (called by the worker) ----

  async heartbeat(
    teamId: string,
    userId: string,
    beat: HeartbeatInput,
  ): Promise<HeartbeatResponse | HeartbeatError> {
    await this.rememberTeamId(teamId);
    const now = Date.now();

    // Ownership guard, mirroring the registry route: the first authenticated
    // user to announce a device owns it; a co-member cannot forge it online
    // or goodbye it offline (see checkDeviceOwner in core.ts).
    const owner = checkDeviceOwner(await this.ctx.storage.get<string>(ownerKey(beat.deviceId)), userId);
    if (!owner.ok) return { error: owner.error, status: 403 };

    const key = instanceKey(beat.deviceId, beat.tag);
    const existing = await this.ctx.storage.get<PresenceInstance>(key);

    if (!existing && beat.stopping) {
      // A goodbye from an instance we never saw: nothing to record or
      // announce (and nothing to pin an owner for).
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

    // Registry-mirrored caps (see checkPresenceCaps in core.ts): 200 devices
    // per team, 25 instances (tags) per device. Counts are fetched lazily and
    // listed with a limit one past the cap, so the checks stay cheap.
    const caps = checkPresenceCaps({
      isNewDevice: owner.pin,
      teamDeviceCount: owner.pin
        ? (await this.ctx.storage.list({ prefix: OWNER_PREFIX, limit: MAX_DEVICES_PER_TEAM + 1 })).size
        : 0,
      isNewInstance: !existing,
      deviceInstanceCount: existing
        ? 0
        : (await this.ctx.storage.list({
            prefix: `${INSTANCE_PREFIX}${beat.deviceId}:`,
            limit: MAX_INSTANCES_PER_DEVICE + 1,
          })).size,
    });
    if (!caps.ok) return { error: caps.error, status: 429 };

    if (owner.pin) {
      await this.ctx.storage.put(ownerKey(beat.deviceId), userId);
    }
    const { instance, events } = applyHeartbeat(existing, beat, now);
    await this.ctx.storage.put(key, instance);
    this.broadcast(events);
    // Project ONLY this device's presence change onto the synced device-list
    // collection (DESIGN.md §5.2). A heartbeat changes exactly one device, so we
    // reconcile just that device — reading its own `inst:<deviceId>:` instances
    // and owner pin — instead of scanning the whole team every ~15s beat. The
    // upsert mints a sync rev only on a list-shape change, so a steady-state
    // `seen` tick stays quiet. Additive: never touches presence keys; old DO
    // instances without this code simply skip it.
    await this.syncOneDevice(beat.deviceId, now);
    await this.ensureAlarmFor(instance);
    return this.heartbeatOk(teamId, instance);
  }

  /** Reconcile a single device's sync record from its current instances + owner.
   * The heartbeat hot path: O(instances on this device), not O(team). */
  private async syncOneDevice(deviceId: string, nowMs: number): Promise<void> {
    const instances = [...(await this.ctx.storage.list<PresenceInstance>({
      prefix: `${INSTANCE_PREFIX}${deviceId}:`,
    })).values()];
    const owner = await this.ctx.storage.get<string>(ownerKey(deviceId));
    const delta = await reconcileSingleDevice(this.syncStorage(), deviceId, instances, owner, nowMs);
    if (delta !== null) this.broadcastSync(delta);
  }

  /** Reconcile the WHOLE `devices` collection against the full presence state.
   * Used by the alarm path only, where timeouts/prunes can change multiple
   * devices at once (and a pruned device's last instance must be tombstoned).
   * O(team), acceptable on the periodic alarm, not on every heartbeat. */
  private async syncDeviceRecords(nowMs: number): Promise<void> {
    const instances = await this.allInstances();
    const owners = await this.ctx.storage.list<string>({ prefix: OWNER_PREFIX });
    const deltas = await reconcileDeviceRecords(
      this.syncStorage(),
      groupInstancesByDevice(instances),
      ownersFromList(owners),
      nowMs,
    );
    for (const delta of deltas) this.broadcastSync(delta);
  }

  /** The DO's storage narrowed to the `SyncStorage` subset the sync layer uses.
   * `DurableObjectStorage` is a structural superset (its get/put/delete/list
   * cover the four methods `SyncStorage` declares), so this is a safe widening
   * to the narrower interface; the single cast is here, not scattered. */
  private syncStorage(): SyncStorage {
    return this.ctx.storage as unknown as SyncStorage;
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
    // at MAX_SUBSCRIBE_AGE_MS); never client-supplied. A missing or already
    // past deadline rejects rather than minting a fresh window: a token that
    // expired between worker verification and DO handling must not buy
    // another 15 minutes of stream (see resolveSubscribeDeadline in core.ts).
    const expiresAt = resolveSubscribeDeadline(
      request.headers.get("x-presence-expires-at"),
      now,
      MAX_SUBSCRIBE_AGE_MS,
    );
    if (expiresAt === null) {
      return new Response(
        JSON.stringify({ error: "subscription_expired" }),
        { status: 401, headers: { "content-type": "application/json" } },
      );
    }

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

  // The presence subscribe stream is push-only, but sync rides the same socket:
  // a client sends `sync.hello` after connect to subscribe to collections with
  // the cursors it already holds, and the DO replies with a snapshot or catch-up
  // delta per collection (DESIGN.md §3.2). Any other inbound message (including
  // from an old client that never sends sync) is ignored, so this stays
  // backward-compatible with the one-way presence transport.
  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (wsExpiresAt(ws) <= Date.now()) return;
    let body: unknown;
    try {
      body = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch {
      return; // not JSON; ignore
    }
    const hello = parseHello(body);
    if (hello === null) return; // not a sync.hello; ignore
    await this.handleSyncHello(ws, hello.collections);
  }

  /** Answer a `sync.hello`: for each subscribed collection decide snapshot vs
   * delta from the GC floor and send the frames over this socket. Phase 1 only
   * serves the `devices` collection; an unknown collection name yields an empty
   * delta (the client simply gets nothing for it). */
  private async handleSyncHello(
    ws: WebSocket,
    collections: { name: string; cursor: number }[],
  ): Promise<void> {
    const subscribed: string[] = [];
    for (const { name, cursor } of collections) {
      if (name !== DEVICES_COLLECTION) continue; // phase 1 serves only `devices`
      subscribed.push(name);
      const resolved = await resolveHelloFrames<DeviceRecord>(
        this.syncStorage(),
        name,
        cursor,
      );
      if (resolved.mode === "snapshot") {
        for (const page of resolved.pages) this.sendSync(ws, page);
      } else if (resolved.delta !== null) {
        this.sendSync(ws, resolved.delta);
      }
    }
    // Mark this socket as sync-subscribed so future delta broadcasts reach it.
    // A legacy presence-only client never sends a hello, so its attachment keeps
    // `syncCollections` absent and it never receives a sync frame (its presence
    // decoder would throw on the unknown type). Preserve the deadline.
    if (subscribed.length > 0) {
      const expiresAt = wsExpiresAt(ws);
      const existing = wsSyncCollections(ws);
      const merged = [...new Set([...existing, ...subscribed])];
      try {
        ws.serializeAttachment({ expiresAt, syncCollections: merged } satisfies WsAttachment);
      } catch {
        // attachment write failed; the socket is likely gone
      }
    }
  }

  /** Send one sync frame to one socket, deadline-checked like presence. */
  private sendSync(ws: WebSocket, frame: SyncServerFrame): void {
    if (wsExpiresAt(ws) <= Date.now()) return;
    try {
      ws.send(JSON.stringify(frame));
    } catch {
      // Socket already gone; hibernation cleans it up.
    }
  }

  /** Broadcast a sync frame ONLY to sockets that subscribed to its collection
   * via `sync.hello`. A legacy presence-only socket has no `syncCollections` on
   * its attachment and is skipped, so a list-shape heartbeat never breaks an old
   * client whose presence decoder throws on unknown message types. WS only; SSE
   * is presence-only for now. */
  private broadcastSync(frame: SyncServerFrame): void {
    const collection = frame.collection;
    const now = Date.now();
    const json = JSON.stringify(frame);
    for (const ws of this.ctx.getWebSockets()) {
      if (wsExpiresAt(ws) <= now) continue;
      if (!wsSyncCollections(ws).includes(collection)) continue; // not subscribed
      try {
        ws.send(json);
      } catch {
        // Socket already gone; hibernation cleans it up.
      }
    }
  }

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
    // Project the (possibly mutated) presence state onto the synced device-list
    // collection: a prune that removed a device's last instance tombstones it
    // here, leaving the list (DESIGN.md §5.2). Then GC expired tombstones and
    // raise the resync floor (DESIGN.md §3.5).
    await this.syncDeviceRecords(now);
    await gcTombstones(this.syncStorage(), DEVICES_COLLECTION, now);
    this.closeExpiredSubscribers(now);
    // Include the next tombstone-GC deadline so a fully-offline team (no
    // instances left to schedule a heartbeat-driven alarm) still wakes to GC its
    // tombstones and advance the GC floor (DESIGN.md §3.5).
    const tombGc = await nextTombstoneGcTime(this.syncStorage(), DEVICES_COLLECTION);
    const candidates = [nextAlarmTime([...all.values()]), this.nextSubscriberDeadline(), tombGc]
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

  /** Make sure the alarm fires no later than this instance's next deadline
   * (expiry check for online, prune pass for offline — delegated to
   * `nextAlarmTime` so the rule lives in one place). The alarm handler itself
   * reschedules from the full map, so per-heartbeat scheduling only needs the
   * cheap min() against the currently set alarm. */
  private async ensureAlarmFor(instance: PresenceInstance): Promise<void> {
    const due = nextAlarmTime([instance]);
    if (due !== null) await this.ensureAlarmAt(due);
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
