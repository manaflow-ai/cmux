// Push: host attention events → APNs alerts and Live Activities, and
// notification responses → the host (through its signaling Durable Object).
import {
  type ActivityState,
  type ApnsKey,
  type ApnsResult,
  type AttentionEvent,
  activityDetail,
  buildAlertPayload,
  buildLiveActivityStartPayload,
  buildLiveActivityUpdatePayload,
  displayAgent,
  isDeadToken,
  parseAttentionEvent,
  sendApns,
  threadId,
} from "./apns";
import { DurableObject } from "cloudflare:workers";
import { type Env, HttpError, db, json, readJson, requireHost, requireUser, str } from "./index";

/// A device row (PlanetScale `devices`) merged with its push switches.
interface DeviceRow {
  id: string;
  apns_token: string;
  environment: "production" | "sandbox";
  bundle_id: string | null;
  push_to_start_token: string | null;
  live_activities: boolean;
  notifications: boolean;
}

export interface DevicePrefs {
  pushToStartToken: string | null;
  liveActivities: boolean;
  notifications: boolean;
}

export interface ActivityRow {
  activityId: string | null;
  pushToken: string | null;
  state: string;
  /// Unix ms.
  startedAt: number;
  updatedAt: number;
  endedAt: number | null;
}

const EVENT_TTL_MS = 7 * 24 * 3600 * 1000;

/// Per-user push state (one Durable Object per user id): each device's Live
/// Activity push-to-start token and switches, the Live Activities the Worker
/// started, and the attention events hosts posted (so a notification
/// response can be checked against the event it answers). Device tokens
/// themselves stay in PlanetScale `devices`.
export class UserPush extends DurableObject<Env> {
  async setDevice(deviceId: string, update: { pushToStartToken?: string | null; liveActivities?: boolean; notifications?: boolean }): Promise<DevicePrefs> {
    const key = `dev:${deviceId}`;
    const prev = (await this.ctx.storage.get<DevicePrefs>(key)) ?? { pushToStartToken: null, liveActivities: true, notifications: true };
    const next: DevicePrefs = {
      pushToStartToken: update.pushToStartToken !== undefined ? update.pushToStartToken : prev.pushToStartToken,
      liveActivities: update.liveActivities ?? prev.liveActivities,
      notifications: update.notifications ?? prev.notifications,
    };
    await this.ctx.storage.put(key, next);
    return next;
  }

  async devices(ids: string[]): Promise<Record<string, DevicePrefs>> {
    const got = await this.ctx.storage.get<DevicePrefs>(ids.map((id) => `dev:${id}`));
    const out: Record<string, DevicePrefs> = {};
    for (const id of ids) out[id] = got.get(`dev:${id}`) ?? { pushToStartToken: null, liveActivities: true, notifications: true };
    return out;
  }

  /// True when the event is new.
  async recordEvent(hostId: string, eventId: string, surface: number | null, kind: string): Promise<boolean> {
    const key = `ev:${hostId}:${eventId}`;
    if (await this.ctx.storage.get(key)) return false;
    const now = Date.now();
    await this.ctx.storage.put(key, { surface, kind, at: now });
    if (Math.random() < 0.05) {
      const old = await this.ctx.storage.list<{ at: number }>({ prefix: "ev:" });
      const stale = [...old].filter(([, v]) => now - v.at > EVENT_TTL_MS).map(([k]) => k);
      for (let i = 0; i < stale.length; i += 128) await this.ctx.storage.delete(stale.slice(i, i + 128));
    }
    return true;
  }

  async event(hostId: string, eventId: string): Promise<{ surface: number | null; kind: string } | null> {
    return (await this.ctx.storage.get<{ surface: number | null; kind: string }>(`ev:${hostId}:${eventId}`)) ?? null;
  }

  async activity(deviceId: string, hostId: string, surface: number): Promise<ActivityRow | null> {
    return (await this.ctx.storage.get<ActivityRow>(`la:${deviceId}:${hostId}:${surface}`)) ?? null;
  }

  async putActivity(deviceId: string, hostId: string, surface: number, row: ActivityRow): Promise<void> {
    await this.ctx.storage.put(`la:${deviceId}:${hostId}:${surface}`, row);
  }
}

export function userPush(env: Env, userId: string) {
  return env.USER_PUSH.get(env.USER_PUSH.idFromName(userId));
}

async function loadDevices(env: Env, userId: string): Promise<DeviceRow[]> {
  const rows = (await db(env).execute("SELECT id, apns_token, environment, bundle_id FROM devices WHERE user_id = ?", [userId]))
    .rows as { id: string; apns_token: string; environment: "production" | "sandbox"; bundle_id: string | null }[];
  if (!rows.length) return [];
  const prefs = await userPush(env, userId).devices(rows.map((r) => r.id));
  return rows.map((r) => ({
    ...r,
    push_to_start_token: prefs[r.id]?.pushToStartToken ?? null,
    live_activities: prefs[r.id]?.liveActivities ?? true,
    notifications: prefs[r.id]?.notifications ?? true,
  }));
}

const DEFAULT_BUNDLE = "dev.cmux.next.native";
const START_PENDING_MS = 10 * 60 * 1000;

export function apnsKey(env: Env): ApnsKey | null {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  return { p8: env.APNS_KEY_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID };
}

export async function pushStatus(env: Env, req: Request): Promise<Response> {
  await requireUser(env, req);
  const key = apnsKey(env);
  return json({ configured: key !== null, key_id: key?.keyId ?? null, team_id: env.APNS_TEAM_ID ?? null });
}

/// Sends one APNs request, or logs what it would send when no key is set.
async function deliver(
  env: Env,
  device: DeviceRow,
  token: string,
  pushType: "alert" | "liveactivity",
  payload: Record<string, unknown>,
  extra: { collapseId?: string; priority?: 5 | 10 } = {},
): Promise<ApnsResult | null> {
  const key = apnsKey(env);
  const bundle = device.bundle_id || DEFAULT_BUNDLE;
  const topic = pushType === "liveactivity" ? `${bundle}.push-type.liveactivity` : bundle;
  if (!key) {
    console.log(`apns not configured (set APNS_KEY_P8, APNS_KEY_ID): skipped ${pushType} to device ${device.id} topic ${topic}`);
    return null;
  }
  try {
    const result = await sendApns(key, {
      token,
      environment: device.environment,
      topic,
      pushType,
      payload,
      priority: extra.priority ?? 10,
      collapseId: extra.collapseId,
    });
    if (!result.ok) console.log(`apns ${pushType} ${device.id}: ${result.status} ${result.reason ?? ""}`);
    return result;
  } catch (e) {
    console.error(`apns ${pushType} ${device.id} failed`, e instanceof Error ? e.message : String(e));
    return { ok: false, status: 0, reason: "fetch_failed" };
  }
}

// ---------- host events ----------

/// `POST /v1/hosts/:id/events` (host secret). Body is an attention event
/// (`kind` question|permission|done|error|notice) or a Live Activity update
/// (`kind: "activity"`, `state` working|needs_input|done).
export async function handleHostEvent(env: Env, req: Request, hostId: string): Promise<Response> {
  const host = await requireHost(env, req);
  if (host.id !== hostId) throw new HttpError(403, "forbidden", "host secret does not match host id");
  const body = await readJson(req);
  if (!host.user_id) return json({ ok: true, skipped: "unpaired" }, 202);
  const conn = db(env);
  const store = userPush(env, host.user_id);
  const devices = await loadDevices(env, host.user_id);
  const configured = apnsKey(env) !== null;

  if (body.kind === "activity") {
    const state = body.state;
    if (state !== "working" && state !== "needs_input" && state !== "done") throw new HttpError(400, "bad_field", "state");
    const surface = body.surface;
    if (typeof surface !== "number" || !Number.isInteger(surface)) throw new HttpError(400, "bad_field", "surface");
    const n = await driveActivities(env, host.id, host.user_id, devices, {
      surface,
      state,
      agent: displayAgent(typeof body.agent === "string" ? body.agent : null),
      workspace: typeof body.workspace === "string" ? body.workspace.slice(0, 120) : "",
      startedAt: typeof body.started_at === "number" ? Math.floor(body.started_at / 1000) : Math.floor(Date.now() / 1000),
      detail: typeof body.detail === "string" ? body.detail : null,
    });
    return json({ ok: true, live_activities: n, apns: configured ? "configured" : "unconfigured" });
  }

  let event: AttentionEvent;
  try {
    event = parseAttentionEvent(body);
  } catch (e) {
    throw new HttpError(400, "bad_field", e instanceof Error ? e.message : "event");
  }
  if (!(await store.recordEvent(host.id, event.id, event.surface, event.kind))) return json({ ok: true, duplicate: true });

  const payload = buildAlertPayload({ hostId: host.id, hostName: host.name, event });
  let sent = 0;
  await Promise.all(
    devices
      .filter((d) => d.notifications)
      .map(async (d) => {
        const r = await deliver(env, d, d.apns_token, "alert", payload, { collapseId: `${threadId(host.id, event.surface)}-${event.kind}` });
        if (r?.ok) sent++;
        if (r && isDeadToken(r)) await conn.execute("DELETE FROM devices WHERE id = ?", [d.id]);
      }),
  );
  return json({ ok: true, sent, devices: devices.length, apns: configured ? "configured" : "unconfigured" });
}

interface ActivityUpdate {
  surface: number;
  state: ActivityState;
  agent: string;
  workspace: string;
  /// Unix seconds; null keeps the stored start.
  startedAt: number | null;
  detail: string | null;
  startIfMissing?: boolean;
}

/// Starts (push-to-start), updates or ends the Live Activity for one agent
/// surface on each of the user's devices. Returns how many it touched.
async function driveActivities(env: Env, hostId: string, userId: string, devices: DeviceRow[], u: ActivityUpdate): Promise<number> {
  const store = userPush(env, userId);
  const now = Date.now();
  const nowS = Math.floor(now / 1000);
  let touched = 0;
  for (const d of devices) {
    if (!d.live_activities) continue;
    const row = await store.activity(d.id, hostId, u.surface);
    const live = row !== null && row.endedAt === null;
    const startedAt = u.startedAt ?? (live ? Math.floor(row!.startedAt / 1000) : nowS);
    const content = { state: u.state, startedAt, detail: activityDetail(u.state, u.detail) };

    if (live && row!.pushToken) {
      const end = u.state === "done";
      const r = await deliver(env, d, row!.pushToken, "liveactivity", buildLiveActivityUpdatePayload(content, nowS, {
        end,
        alert: u.state === "needs_input" ? { title: `${u.agent} needs your input`, body: u.workspace || "On your Mac" } : undefined,
      }));
      if (r && (r.ok || isDeadToken(r))) {
        await store.putActivity(d.id, hostId, u.surface, { ...row!, state: u.state, updatedAt: now, endedAt: end || isDeadToken(r) ? now : null });
      }
      if (r?.ok) touched++;
      continue;
    }
    if (live && !row!.pushToken && now - row!.updatedAt < START_PENDING_MS) {
      // Started; the app has not reported the activity's update token yet.
      await store.putActivity(d.id, hostId, u.surface, { ...row!, state: u.state, updatedAt: row!.updatedAt });
      continue;
    }
    if (u.state !== "working" || u.startIfMissing === false || !d.push_to_start_token) continue;
    const attributes = { hostID: hostId, surface: u.surface, agent: u.agent, workspace: u.workspace };
    const r = await deliver(env, d, d.push_to_start_token, "liveactivity", buildLiveActivityStartPayload(attributes, content, nowS));
    if (r && isDeadToken(r)) {
      await store.setDevice(d.id, { pushToStartToken: null });
      continue;
    }
    if (r && !r.ok) continue;
    // Recorded even without a key, so a configured deploy behaves the same.
    await store.putActivity(d.id, hostId, u.surface, {
      activityId: null, pushToken: null, state: u.state, startedAt: startedAt * 1000, updatedAt: now, endedAt: null,
    });
    if (r?.ok) touched++;
  }
  return touched;
}

// ---------- app → Worker ----------

async function requireOwnedHost(env: Env, userId: string, hostId: string): Promise<void> {
  const owned = await db(env).execute("SELECT id FROM hosts WHERE id = ? AND user_id = ?", [hostId, userId]);
  if (owned.rows.length !== 1) throw new HttpError(403, "forbidden", "host is not paired with this user");
}

/// `POST /v1/push/live-activity` (session): the app reports an activity's
/// update token (or that it ended). `{device_token, host_id, surface,
/// activity_id, push_token?, ended?}`.
export async function liveActivityRegister(env: Env, req: Request): Promise<Response> {
  const user = await requireUser(env, req);
  const body = await readJson(req);
  const deviceToken = str(body, "device_token", 255)!.toLowerCase();
  const hostId = str(body, "host_id", 32)!;
  const activityId = str(body, "activity_id", 64)!;
  const pushToken = str(body, "push_token", 255, false)?.toLowerCase() ?? null;
  if (pushToken && !/^[0-9a-f]{32,255}$/.test(pushToken)) throw new HttpError(400, "bad_field", "push_token must be hex");
  const surface = body.surface;
  if (typeof surface !== "number" || !Number.isInteger(surface)) throw new HttpError(400, "bad_field", "surface");
  const device = (await db(env).execute("SELECT id FROM devices WHERE apns_token = ? AND user_id = ?", [deviceToken, user.id]))
    .rows[0] as { id: string } | undefined;
  if (!device) throw new HttpError(404, "device_not_found", "register the device first");
  await requireOwnedHost(env, user.id, hostId);
  const store = userPush(env, user.id);
  const now = Date.now();
  const row = await store.activity(device.id, hostId, surface);
  if (body.ended === true) {
    if (row && (row.activityId === null || row.activityId === activityId)) {
      await store.putActivity(device.id, hostId, surface, { ...row, endedAt: now, updatedAt: now });
    }
    return json({ ok: true });
  }
  const startedAt = typeof body.started_at === "number" ? body.started_at : row?.startedAt ?? now;
  await store.putActivity(device.id, hostId, surface, {
    activityId, pushToken, state: row?.state ?? "working", startedAt, updatedAt: now, endedAt: null,
  });
  return json({ ok: true });
}

const ACTIONS = new Set(["reply", "option", "allow", "deny"]);

/// `POST /v1/push/action` (session): a notification response. Forwards
/// `{event_id, surface, type, text?, key?}` to the host over its signaling
/// socket; the host checks the event is one it raised for that surface.
export async function pushAction(env: Env, req: Request): Promise<Response> {
  const user = await requireUser(env, req);
  const body = await readJson(req);
  const hostId = str(body, "host_id", 32)!;
  const eventId = str(body, "event_id", 128)!;
  const type = str(body, "action", 16)!;
  if (!ACTIONS.has(type)) throw new HttpError(400, "bad_field", "action must be reply, option, allow or deny");
  const text = str(body, "text", 4000, type === "reply") ?? null;
  const key = str(body, "key", 8, type === "option") ?? null;
  await requireOwnedHost(env, user.id, hostId);
  const ev = await userPush(env, user.id).event(hostId, eventId);
  if (!ev || ev.surface === null) throw new HttpError(404, "event_not_found");
  const stub = env.HOST_SIGNAL.get(env.HOST_SIGNAL.idFromName(hostId));
  const r = await stub.fetch("https://signal/action", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ user_id: user.id, action: { event_id: eventId, surface: ev.surface, type, text, key } }),
  });
  if (r.status === 409) throw new HttpError(409, "host_offline", "your Mac is offline");
  if (!r.ok) throw new HttpError(502, "forward_failed");
  return json({ ok: true, delivered: true }, 202);
}
