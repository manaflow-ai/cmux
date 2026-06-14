// Device registry — register a Mac/host (and its running cmux app instance) and
// list the team's registered devices so a phone can auto-pair on reload.
//
// Auth: Stack Bearer + X-Stack-Refresh-Token from the native client (same as
// /api/device-tokens). Team scope: the caller picks a team via `X-Cmux-Team-Id`
// (or `?teamId=`); the route rejects a team the caller is not a member of and
// otherwise defaults to the caller's selected/billing team.
//
// The registry is a best-effort rendezvous layer. It is NOT authoritative on
// pairing — a phone keeps its own local paired-Mac store and falls back to it
// when the registry is unreachable, so pairing survives the cloud being down.

import { and, desc, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { deviceAppInstances, devices } from "../../../db/schema";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../services/vms/auth";
import { requestedVmTeamIdFromRequest } from "../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_REQUEST_BYTES = 16 * 1024;
const MAX_DEVICES_PER_TEAM = 200;
// A device's app instances are keyed by `(deviceId, tag)`, and `tag` is
// client-supplied, so cap instances per device to keep one device from creating
// unbounded rows (and an unbounded GET response) by varying the tag.
const MAX_INSTANCES_PER_DEVICE = 25;
const MAX_ROUTES = 16;
const MAX_TAG_LENGTH = 64;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const ALLOWED_PLATFORMS = new Set(["mac", "ios", "linux", "windows"]);

type TeamResolution =
  | { ok: true; teamId: string }
  | { ok: false; response: Response };

/**
 * Resolve the team this request operates on and reject teams the caller is not a
 * member of. A requested team (`X-Cmux-Team-Id` / `?teamId=`) must appear in the
 * caller's verified team list; with no request team we default to the caller's
 * selected team, then the billing team (which is the user id for a solo account
 * with no team), so single-team callers need no header.
 */
function resolveTeam(request: Request, user: AuthedUser): TeamResolution {
  const requested = requestedVmTeamIdFromRequest(request);
  if (requested) {
    const isMember = user.teamIds.includes(requested) || requested === user.id;
    if (!isMember) {
      return {
        ok: false,
        response: jsonResponse({ error: "team_not_found" }, 403),
      };
    }
    return { ok: true, teamId: requested };
  }
  return { ok: true, teamId: user.selectedTeamId ?? user.billingTeamId };
}

async function readBoundedJson(
  request: Request,
): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; status: number }> {
  const lengthHeader = request.headers.get("content-length");
  if (lengthHeader && Number(lengthHeader) > MAX_REQUEST_BYTES) {
    return { ok: false, status: 413 };
  }
  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return { ok: false, status: 400 };
  }
  if (raw.length > MAX_REQUEST_BYTES) return { ok: false, status: 413 };
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, status: 400 };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, status: 400 };
  }
  return { ok: true, value: parsed as Record<string, unknown> };
}

function trimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function recordOrEmpty(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/**
 * Keep only structurally valid route entries (a plain object), bounded by
 * `MAX_ROUTES`. Semantic validation of the `CmxAttachRoute` wire schema is left
 * to the typed Mac/iOS clients, so the server stays forward-compatible with new
 * route kinds; this only guarantees the stored jsonb is a bounded array of
 * objects (never a string, number, or array element that would corrupt the
 * column or bloat the row).
 */
function routesArray(value: unknown): unknown[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((entry) => entry !== null && typeof entry === "object" && !Array.isArray(entry))
    .slice(0, MAX_ROUTES);
}

/**
 * Whether `host` names the local machine. The server mirror of the native
 * `CmxLoopbackHost` classifier (Swift): a loopback route is forbidden in
 * anything that arrives from outside the Mac (a QR/deep-link, and now a manual
 * CLI-added remote), because a phone that dials `127.0.0.1`/`localhost` dials
 * itself. Classification is value-based, not a string-prefix check, so legacy
 * IPv4 spellings (`127.1`, `0x7f.0.0.1`, `2130706433`) and every IPv6 form of
 * `::1`/`::`/IPv4-mapped loopback classify the same way they would dial.
 *
 * Covers `127.0.0.0/8`, the unspecified `0.0.0.0/8` (a connect to it lands on
 * loopback), IPv6 `::1` and `::`, IPv4-mapped/compatible IPv6 embedding those
 * ranges, and `localhost` / `*.localhost` with or without a trailing root dot.
 */
export function hostIsLoopback(rawHost: string): boolean {
  let host = rawHost.trim().toLowerCase();
  if (host.startsWith("[") && host.endsWith("]") && host.length > 2) {
    host = host.slice(1, -1);
  }
  // Strip an IPv6 zone index (`%lo0`): the zone scopes the interface, not the
  // address.
  const zone = host.indexOf("%");
  if (zone >= 0) host = host.slice(0, zone);
  // A single trailing root dot is the fully-qualified spelling of the same
  // name (`localhost.`) and must classify identically.
  if (host.endsWith(".") && host.length > 1) host = host.slice(0, -1);
  if (host.length === 0) return false;
  if (host === "localhost" || host.endsWith(".localhost")) return true;

  const ipv4FirstOctet = parseIPv4FirstOctet(host);
  if (ipv4FirstOctet !== null) return ipv4FirstOctet === 127 || ipv4FirstOctet === 0;

  const ipv6 = parseIPv6Bytes(host);
  if (ipv6) return ipv6IsSelfDialing(ipv6);

  return false;
}

/**
 * The first octet of `host` parsed with `inet_aton` semantics (dotted quad,
 * fewer-than-four parts, octal, hex, single 32-bit decimal), or `null` when it
 * is not an IPv4 literal in any of those forms. Mirrors `inet_aton` so a
 * name-looking numeric host classifies exactly as it dials.
 */
function parseIPv4FirstOctet(host: string): number | null {
  const parts = host.split(".");
  if (parts.length === 0 || parts.length > 4) return null;
  const values: number[] = [];
  for (const part of parts) {
    if (part.length === 0) return null;
    let value: number;
    if (/^0[xX][0-9a-fA-F]+$/.test(part)) {
      value = parseInt(part, 16);
    } else if (/^0[0-7]+$/.test(part)) {
      value = parseInt(part, 8);
    } else if (/^[0-9]+$/.test(part)) {
      value = parseInt(part, 10);
    } else {
      return null;
    }
    if (!Number.isFinite(value)) return null;
    values.push(value);
  }
  // The final part is a big-endian remainder filling the low bytes; all
  // leading parts must be single octets. The first octet is `values[0]` when
  // there is more than one part, else the high byte of the 32-bit value.
  if (values.length === 1) {
    const n = values[0];
    if (n < 0 || n > 0xffffffff) return null;
    return (n >>> 24) & 0xff;
  }
  for (let i = 0; i < values.length - 1; i++) {
    if (values[i] < 0 || values[i] > 0xff) return null;
  }
  const last = values[values.length - 1];
  const maxLast = Math.pow(256, 4 - (values.length - 1)) - 1;
  if (last < 0 || last > maxLast) return null;
  return values[0] & 0xff;
}

/**
 * The 16 address bytes of `host` parsed as an IPv6 literal, or `null` when it
 * is not one. Supports `::` compression and a trailing embedded IPv4 quad.
 */
function parseIPv6Bytes(host: string): number[] | null {
  if (!host.includes(":")) return null;
  let work = host;
  const tailBytes: number[] = [];
  // A trailing embedded IPv4 quad (`::ffff:1.2.3.4`). Strip it and carry its 4
  // bytes as the fixed tail; the remaining hex groups parse as usual.
  const lastColon = work.lastIndexOf(":");
  const tail = work.slice(lastColon + 1);
  if (tail.includes(".")) {
    const quad = tail.split(".");
    if (quad.length !== 4) return null;
    for (const q of quad) {
      if (!/^[0-9]+$/.test(q)) return null;
      const v = parseInt(q, 10);
      if (v < 0 || v > 255) return null;
      tailBytes.push(v);
    }
    // Drop the dotted quad including its leading colon, leaving e.g. `::ffff`.
    work = work.slice(0, lastColon);
  }

  const doubleColon = work.indexOf("::");
  let headGroups: string[];
  let tailGroups: string[];
  if (doubleColon >= 0) {
    if (work.indexOf("::", doubleColon + 1) >= 0) return null;
    const head = work.slice(0, doubleColon);
    const rest = work.slice(doubleColon + 2);
    headGroups = head.length ? head.split(":") : [];
    tailGroups = rest.length ? rest.split(":") : [];
  } else {
    headGroups = work.split(":");
    tailGroups = [];
  }

  const groupToBytes = (g: string): number[] | null => {
    if (!/^[0-9a-fA-F]{1,4}$/.test(g)) return null;
    const v = parseInt(g, 16);
    return [(v >> 8) & 0xff, v & 0xff];
  };

  const headBytes: number[] = [];
  for (const g of headGroups) {
    const b = groupToBytes(g);
    if (!b) return null;
    headBytes.push(...b);
  }
  const tailGroupBytes: number[] = [];
  for (const g of tailGroups) {
    const b = groupToBytes(g);
    if (!b) return null;
    tailGroupBytes.push(...b);
  }

  const fixedTail = [...tailGroupBytes, ...tailBytes];
  const total = headBytes.length + fixedTail.length;
  if (doubleColon < 0) {
    return total === 16 ? headBytes : null;
  }
  if (total > 16) return null;
  const zeros = new Array(16 - total).fill(0);
  return [...headBytes, ...zeros, ...fixedTail];
}

/** Whether 16 IPv6 bytes name the local machine (`::1`, `::`, or mapped). */
function ipv6IsSelfDialing(bytes: number[]): boolean {
  if (bytes.length !== 16) return false;
  if (bytes.slice(0, 15).every((b) => b === 0) && bytes[15] <= 1) return true;
  const prefixZero = bytes.slice(0, 10).every((b) => b === 0);
  const isMapped = prefixZero && bytes[10] === 0xff && bytes[11] === 0xff;
  const isCompatible = prefixZero && bytes[10] === 0 && bytes[11] === 0;
  if (isMapped || isCompatible) {
    const first = bytes[12];
    return first === 127 || first === 0;
  }
  return false;
}

/**
 * Extract the host string from a route's endpoint, tolerating both the
 * `{type:"host_port",host,port}` shape and the older `{host,port}` shape that
 * appears in stored rows. Returns null for non-host endpoints (peer/url).
 */
function routeEndpointHost(route: Record<string, unknown>): string | null {
  const endpoint = route.endpoint;
  if (!endpoint || typeof endpoint !== "object" || Array.isArray(endpoint)) {
    return null;
  }
  const host = (endpoint as Record<string, unknown>).host;
  return typeof host === "string" ? host : null;
}

/**
 * Whether any route is a loopback route: declared `debug_loopback` kind or a
 * host:port endpoint whose host parses as loopback. Used to reject manual
 * CLI-added remotes that a phone could never reach.
 */
function routesContainLoopback(routes: unknown[]): boolean {
  for (const route of routes) {
    if (!route || typeof route !== "object" || Array.isArray(route)) continue;
    const record = route as Record<string, unknown>;
    if (record.kind === "debug_loopback") return true;
    const host = routeEndpointHost(record);
    if (host !== null && hostIsLoopback(host)) return true;
  }
  return false;
}

/**
 * Register (or refresh) a device and its running cmux app instance. Idempotent
 * per `(deviceId)` for the machine row and per `(deviceId, tag)` for the
 * instance row, so a relaunch updates routes in place rather than duplicating.
 */
export async function POST(request: Request): Promise<Response> {
  const user = await verifyRequest(request, {
    requestedTeamId: requestedVmTeamIdFromRequest(request),
    allowCookie: false,
  });
  if (!user) return unauthorized();

  const team = resolveTeam(request, user);
  if (!team.ok) return team.response;

  const body = await readBoundedJson(request);
  if (!body.ok) return jsonResponse({ error: "invalid_request" }, body.status);

  const deviceUuid = trimmedString(body.value.deviceId).toLowerCase();
  const platform = trimmedString(body.value.platform).toLowerCase();
  const displayName = trimmedString(body.value.displayName) || null;
  const labels = recordOrEmpty(body.value.labels);
  const tag = trimmedString(body.value.tag) || "default";
  const routes = routesArray(body.value.routes);
  const instanceLabels = recordOrEmpty(body.value.instanceLabels);
  // `manual: true` marks a user-initiated remote added through the cmux CLI
  // (`cmux remotes add`) rather than a Mac self-registering its own live
  // routes. The Mac self-registration legitimately advertises a `debug_loopback`
  // route in DEBUG builds (for iOS Simulator dev pairing), so loopback
  // rejection must be scoped to the manual path: a phone can never dial a
  // manually-entered `127.0.0.1`/`localhost` host, so reject it here as the
  // server-side trust boundary, mirroring the QR/deep-link loopback refusal.
  const manual = body.value.manual === true;

  if (!UUID_RE.test(deviceUuid)) {
    return jsonResponse({ error: "invalid_device_id" }, 400);
  }
  if (!ALLOWED_PLATFORMS.has(platform)) {
    return jsonResponse({ error: "invalid_platform" }, 400);
  }
  if (tag.length > MAX_TAG_LENGTH) {
    return jsonResponse({ error: "invalid_tag" }, 400);
  }
  if (manual && routesContainLoopback(routes)) {
    return jsonResponse({ error: "loopback_route_rejected" }, 400);
  }

  const db = cloudDb();
  const now = new Date();

  const registered = await db.transaction(async (tx) => {
    // Serialize concurrent registrations for the same team so the per-team cap
    // is enforced without a race (mirrors the device-tokens advisory lock).
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${team.teamId}, 7))`);

    // Device identity is per team: a row keyed by (teamId, deviceUuid). The
    // same cmux device UUID registering under a different team is a separate,
    // legitimate row (a Mac in two teams), so there is no cross-team conflict to
    // guard against. Team B creating its own row cannot read or mutate team A's.
    const [existingDevice] = await tx
      .select({ id: devices.id, userId: devices.userId })
      .from(devices)
      .where(and(eq(devices.teamId, team.teamId), eq(devices.deviceUuid, deviceUuid)))
      .limit(1);

    // Only the user who registered a device row may update it. GET exposes
    // device UUIDs to every team member, so without this a co-member could POST
    // another member's device UUID and overwrite its attach routes (redirecting
    // that user's phone reconnect at their own host). This keeps route
    // population owned by the registering user, matching the pre-registry trust
    // boundary where only the user's own pairing populated their phone's routes.
    // Cryptographic proof-of-possession (so even the same user must prove they
    // hold the device) is the deferred key-pinning phase.
    if (existingDevice && existingDevice.userId !== user.id) {
      return { error: "device_not_owned" as const };
    }

    if (!existingDevice) {
      const [{ total }] = await tx
        .select({ total: sql<number>`count(*)::int` })
        .from(devices)
        .where(eq(devices.teamId, team.teamId));
      if (Number(total) >= MAX_DEVICES_PER_TEAM) {
        return { error: "too_many_devices" as const };
      }
    }

    const [deviceRow] = await tx
      .insert(devices)
      .values({
        teamId: team.teamId,
        deviceUuid,
        userId: user.id,
        platform,
        displayName,
        labels,
        lastSeenAt: now,
        updatedAt: now,
      })
      .onConflictDoUpdate({
        target: [devices.teamId, devices.deviceUuid],
        set: {
          userId: user.id,
          platform,
          displayName,
          labels,
          lastSeenAt: now,
          updatedAt: now,
        },
      })
      .returning({ id: devices.id });
    const deviceRowId = deviceRow.id;

    // Cap instances per device row. `tag` is client-supplied and the instance
    // key is `(deviceId, tag)`, so without this a single device could create
    // unbounded rows by varying the tag. Re-registering an existing tag is an
    // update (the onConflict below), so only a genuinely new tag counts.
    const [existingInstance] = await tx
      .select({ id: deviceAppInstances.id })
      .from(deviceAppInstances)
      .where(and(eq(deviceAppInstances.deviceId, deviceRowId), eq(deviceAppInstances.tag, tag)))
      .limit(1);
    if (!existingInstance) {
      const [{ total }] = await tx
        .select({ total: sql<number>`count(*)::int` })
        .from(deviceAppInstances)
        .where(eq(deviceAppInstances.deviceId, deviceRowId));
      if (Number(total) >= MAX_INSTANCES_PER_DEVICE) {
        return { error: "too_many_instances" as const };
      }
    }

    await tx
      .insert(deviceAppInstances)
      .values({
        deviceId: deviceRowId,
        teamId: team.teamId,
        tag,
        routes,
        labels: instanceLabels,
        lastSeenAt: now,
        updatedAt: now,
      })
      .onConflictDoUpdate({
        target: [deviceAppInstances.deviceId, deviceAppInstances.tag],
        set: {
          teamId: team.teamId,
          routes,
          labels: instanceLabels,
          lastSeenAt: now,
          updatedAt: now,
        },
      });

    return { error: null };
  });

  if (registered.error === "device_not_owned") {
    return jsonResponse({ error: "device_not_owned" }, 403);
  }
  if (registered.error === "too_many_devices") {
    return jsonResponse({ error: "too_many_devices" }, 429);
  }
  if (registered.error === "too_many_instances") {
    return jsonResponse({ error: "too_many_instances" }, 429);
  }

  return jsonResponse({ ok: true, deviceId: deviceUuid, teamId: team.teamId, tag });
}

type DeviceListRow = {
  id: string;
  deviceUuid: string;
  platform: string;
  displayName: string | null;
  labels: Record<string, unknown>;
  lastSeenAt: Date;
};

/**
 * List the team's registered devices and their app instances, so a phone can
 * find the Mac it last paired with and refresh routes on reload.
 */
export async function GET(request: Request): Promise<Response> {
  const user = await verifyRequest(request, {
    requestedTeamId: requestedVmTeamIdFromRequest(request),
    allowCookie: false,
  });
  if (!user) return unauthorized();

  const team = resolveTeam(request, user);
  if (!team.ok) return team.response;

  const db = cloudDb();

  const deviceRows = (await db
    .select({
      id: devices.id,
      deviceUuid: devices.deviceUuid,
      platform: devices.platform,
      displayName: devices.displayName,
      labels: devices.labels,
      lastSeenAt: devices.lastSeenAt,
    })
    .from(devices)
    .where(eq(devices.teamId, team.teamId))
    .orderBy(desc(devices.lastSeenAt))) as DeviceListRow[];

  const instanceRows = await db
    .select({
      deviceId: deviceAppInstances.deviceId,
      tag: deviceAppInstances.tag,
      routes: deviceAppInstances.routes,
      labels: deviceAppInstances.labels,
      lastSeenAt: deviceAppInstances.lastSeenAt,
    })
    .from(deviceAppInstances)
    .where(eq(deviceAppInstances.teamId, team.teamId))
    .orderBy(desc(deviceAppInstances.lastSeenAt));

  const instancesByDevice = new Map<string, typeof instanceRows>();
  for (const row of instanceRows) {
    const list = instancesByDevice.get(row.deviceId) ?? [];
    list.push(row);
    instancesByDevice.set(row.deviceId, list);
  }

  const devicesPayload = deviceRows.map((device) => ({
    // The phone matches its stored `macDeviceID` (the cmux device UUID) against
    // this, so expose `deviceUuid`, not the internal surrogate row id.
    deviceId: device.deviceUuid,
    platform: device.platform,
    displayName: device.displayName,
    labels: device.labels,
    lastSeenAt: device.lastSeenAt.toISOString(),
    instances: (instancesByDevice.get(device.id) ?? []).map((instance) => ({
      tag: instance.tag,
      routes: instance.routes,
      labels: instance.labels,
      lastSeenAt: instance.lastSeenAt.toISOString(),
    })),
  }));

  return jsonResponse({ teamId: team.teamId, devices: devicesPayload });
}

/**
 * Unregister a device (e.g. when the user forgets/decommissions a Mac). Removes
 * the machine row and cascades its app instances. Team-scoped so a caller can
 * only delete devices in a team they belong to.
 */
export async function DELETE(request: Request): Promise<Response> {
  const user = await verifyRequest(request, {
    requestedTeamId: requestedVmTeamIdFromRequest(request),
    allowCookie: false,
  });
  if (!user) return unauthorized();

  const team = resolveTeam(request, user);
  if (!team.ok) return team.response;

  const body = await readBoundedJson(request);
  if (!body.ok) return jsonResponse({ error: "invalid_request" }, body.status);

  const deviceUuid = trimmedString(body.value.deviceId).toLowerCase();
  if (!UUID_RE.test(deviceUuid)) {
    return jsonResponse({ error: "invalid_device_id" }, 400);
  }

  // Delete only the caller's own row for this device in this team. Scoping by
  // userId (not just team) mirrors the POST ownership guard, so a co-member who
  // sees the device UUID via GET cannot remove another member's registered Mac
  // and break their phone reconnect. Never touches another team's row for the
  // same physical Mac.
  const db = cloudDb();
  await db
    .delete(devices)
    .where(
      and(
        eq(devices.deviceUuid, deviceUuid),
        eq(devices.teamId, team.teamId),
        eq(devices.userId, user.id),
      ),
    );

  return jsonResponse({ ok: true });
}
