// cmux.com device dashboard — one shared data path for the dashboard page and
// the /api/devices/dashboard routes.
//
// The account device list IS the authorization surface (list-auth): the
// presence worker's account Durable Object owns lifecycle status, the revoked
// kill switch, version/track facts, and per-device ack watermarks. The web DB
// registry owns human-facing facts (display name, platform, dev tag, last
// seen). This module joins the two views by endpointId and hosts the
// mutations: revoke = DO flag + shared-store mirror (old endpoints' discovery
// drops the device too — one write, both stacks), un-revoke = DO only (the
// device's next registration recreates its registry row), retire = DO only
// (cleanup, un-retires on the device's next hello).

import { desc, eq } from "drizzle-orm";
import * as Effect from "effect/Effect";

import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { irohEndpointBindings } from "../../db/schema";
import { IrohRepository, IrohRepositoryLive } from "../iroh/repository";
import { buildConnectivityInvalidationRequest } from "../iroh/routeHandler";

const WORKER_TIMEOUT_MS = 10_000;
const INVALIDATION_TIMEOUT_MS = 3_000;
const MAX_REGISTRY_ROWS = 500;
const MAX_ENDPOINT_ID_CHARS = 128;

export type DeviceLifecycleStatus =
  | "active"
  | "seeded"
  | "stale"
  | "retired"
  | "suspended"
  | "pending"
  | "superseded";

export type DeviceReleaseTrack =
  | "nightly"
  | "stable"
  | "internal"
  | "beta"
  | "appstore"
  | "dev";

const DEVICE_STATUSES: ReadonlySet<string> = new Set([
  "active", "seeded", "stale", "retired", "suspended", "pending", "superseded",
]);
const RELEASE_TRACKS: ReadonlySet<string> = new Set([
  "nightly", "stable", "internal", "beta", "appstore", "dev",
]);

/** DO-owned listv2 facts for one device row (null on entries the control
 * plane has never seen). */
export interface DeviceListAuthFacts {
  readonly listed: boolean;
  readonly status: DeviceLifecycleStatus;
  readonly revoked: boolean;
  readonly appVersion: string | null;
  readonly releaseTrack: DeviceReleaseTrack | null;
  readonly capabilities: readonly string[];
  readonly lastConfirmedAt: string | null;
  readonly lastAckedRev: number | null;
  readonly connected: boolean;
}

export interface DeviceDashboardEntry {
  readonly endpointId: string;
  readonly displayName: string | null;
  /** Registry truth when the endpoint has a registry row; otherwise inferred
   * from the client namespace (platformInferred=true) or null. */
  readonly platform: "mac" | "ios" | null;
  readonly platformInferred: boolean;
  readonly tag: string | null;
  readonly clientNamespace: string | null;
  readonly deviceId: string | null;
  readonly lastSeenAt: string | null;
  /** Old-stack shared-store revocation stamp (set by the dashboard mirror or
   * a device self-revocation). */
  readonly registryRevokedAt: string | null;
  readonly listAuth: DeviceListAuthFacts | null;
}

export interface DeviceDashboardData {
  /** False when the presence worker is unconfigured or unreachable; entries
   * then carry registry facts only. */
  readonly controlPlaneAvailable: boolean;
  readonly rev: number | null;
  readonly ttlSeconds: number | null;
  readonly minimumSupportedVersion: { readonly mac?: string; readonly ios?: string } | null;
  readonly devices: readonly DeviceDashboardEntry[];
}

export function isValidEndpointIdInput(value: unknown): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.length <= MAX_ENDPOINT_ID_CHARS;
}

/** Dotted-numeric version comparison for the derived update-required flag
 * ("this device runs a build below the pushed platform floor"). Non-numeric
 * segments compare as 0; missing segments compare as 0. */
export function versionBelowFloor(version: string, floor: string): boolean {
  const parse = (value: string): number[] =>
    value.split(".").map((segment) => {
      const numeric = Number.parseInt(segment, 10);
      return Number.isSafeInteger(numeric) && numeric >= 0 ? numeric : 0;
    });
  const have = parse(version);
  const need = parse(floor);
  for (let index = 0; index < Math.max(have.length, need.length); index += 1) {
    const a = have[index] ?? 0;
    const b = need[index] ?? 0;
    if (a !== b) return a < b;
  }
  return false;
}

interface ControlPlaneDeviceRow {
  readonly endpointId: string;
  readonly listed: boolean;
  readonly deviceId: string | null;
  readonly clientNamespace: string | null;
  readonly instanceTag: string | null;
  readonly status: DeviceLifecycleStatus;
  readonly revoked: boolean;
  readonly appVersion: string | null;
  readonly releaseTrack: DeviceReleaseTrack | null;
  readonly capabilities: readonly string[];
  readonly lastConfirmedAt: string | null;
  readonly lastAckedRev: number | null;
  readonly connected: boolean;
}

interface ControlPlaneSnapshot {
  readonly rev: number;
  readonly ttlSeconds: number;
  readonly minimumSupportedVersion: { readonly mac?: string; readonly ios?: string } | null;
  readonly devices: readonly ControlPlaneDeviceRow[];
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** Strict-enough parse of GET /v1/control/devices: malformed rows are skipped
 * rather than failing the whole snapshot (same stance as the DO's own
 * discovery mapping). */
function parseControlPlaneSnapshot(value: unknown): ControlPlaneSnapshot | null {
  if (!isObject(value)) return null;
  if (typeof value.rev !== "number" || !Number.isSafeInteger(value.rev)) return null;
  if (typeof value.ttlSeconds !== "number") return null;
  if (!Array.isArray(value.devices)) return null;
  const floors = isObject(value.minimumSupportedVersion)
    ? {
      ...(typeof value.minimumSupportedVersion.mac === "string"
        ? { mac: value.minimumSupportedVersion.mac }
        : {}),
      ...(typeof value.minimumSupportedVersion.ios === "string"
        ? { ios: value.minimumSupportedVersion.ios }
        : {}),
    }
    : null;
  const devices: ControlPlaneDeviceRow[] = [];
  for (const raw of value.devices) {
    if (!isObject(raw)) continue;
    if (typeof raw.endpointId !== "string" || raw.endpointId.length === 0) continue;
    if (typeof raw.status !== "string" || !DEVICE_STATUSES.has(raw.status)) continue;
    if (typeof raw.revoked !== "boolean") continue;
    const releaseTrack = typeof raw.releaseTrack === "string" && RELEASE_TRACKS.has(raw.releaseTrack)
      ? raw.releaseTrack as DeviceReleaseTrack
      : null;
    devices.push({
      endpointId: raw.endpointId,
      listed: raw.listed === true,
      deviceId: optionalString(raw.deviceId),
      clientNamespace: optionalString(raw.clientNamespace),
      instanceTag: optionalString(raw.instanceTag),
      status: raw.status as DeviceLifecycleStatus,
      revoked: raw.revoked,
      appVersion: optionalString(raw.appVersion),
      releaseTrack,
      capabilities: Array.isArray(raw.capabilities)
        ? raw.capabilities.filter((item): item is string => typeof item === "string")
        : [],
      lastConfirmedAt: optionalString(raw.lastConfirmedAt),
      lastAckedRev: typeof raw.lastAckedRev === "number" && Number.isSafeInteger(raw.lastAckedRev)
        ? raw.lastAckedRev
        : null,
      connected: raw.connected === true,
    });
  }
  return {
    rev: value.rev,
    ttlSeconds: value.ttlSeconds,
    minimumSupportedVersion: floors && Object.keys(floors).length > 0 ? floors : null,
    devices,
  };
}

function presenceBaseUrl(): string | null {
  return env.CMUX_PRESENCE_BASE_URL ?? null;
}

async function presenceFetch(
  path: string,
  accessToken: string,
  init: { method: string; body?: string },
): Promise<Response | null> {
  const base = presenceBaseUrl();
  if (!base) return null;
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(new Error("presence_worker_timeout")),
    WORKER_TIMEOUT_MS,
  );
  try {
    return await fetch(new URL(path, base), {
      method: init.method,
      headers: {
        authorization: `Bearer ${accessToken}`,
        accept: "application/json",
        ...(init.body !== undefined ? { "content-type": "application/json" } : {}),
      },
      ...(init.body !== undefined ? { body: init.body } : {}),
      signal: controller.signal,
    });
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchControlPlaneSnapshot(accessToken: string): Promise<ControlPlaneSnapshot | null> {
  const response = await presenceFetch("/v1/control/devices", accessToken, { method: "GET" });
  if (!response?.ok) return null;
  const body: unknown = await response.json().catch(() => null);
  return parseControlPlaneSnapshot(body);
}

interface RegistryRow {
  readonly endpointId: string;
  readonly displayName: string | null;
  readonly platform: string;
  readonly tag: string;
  readonly clientNamespace: string;
  readonly deviceUuid: string;
  readonly lastSeenAt: Date;
  readonly revokedAt: Date | null;
}

/** One preferred registry row per endpointId: the active row when one exists,
 * else the most recently updated revoked row (so a dashboard-revoked device
 * keeps its name). */
async function loadRegistryRows(userId: string): Promise<Map<string, RegistryRow>> {
  const rows = await cloudDb()
    .select({
      endpointId: irohEndpointBindings.endpointId,
      displayName: irohEndpointBindings.displayName,
      platform: irohEndpointBindings.platform,
      tag: irohEndpointBindings.tag,
      clientNamespace: irohEndpointBindings.clientNamespace,
      deviceUuid: irohEndpointBindings.deviceUuid,
      lastSeenAt: irohEndpointBindings.lastSeenAt,
      revokedAt: irohEndpointBindings.revokedAt,
    })
    .from(irohEndpointBindings)
    .where(eq(irohEndpointBindings.userId, userId))
    .orderBy(desc(irohEndpointBindings.updatedAt))
    .limit(MAX_REGISTRY_ROWS);
  const byEndpoint = new Map<string, RegistryRow>();
  for (const row of rows) {
    const existing = byEndpoint.get(row.endpointId);
    if (!existing || (existing.revokedAt !== null && row.revokedAt === null)) {
      byEndpoint.set(row.endpointId, row);
    }
  }
  return byEndpoint;
}

function inferPlatform(namespace: string | null): "mac" | "ios" | null {
  if (!namespace) return null;
  if (namespace.includes(".ios")) return "ios";
  if (namespace.includes(".app")) return "mac";
  return null;
}

function registryPlatform(value: string): "mac" | "ios" | null {
  return value === "mac" || value === "ios" ? value : null;
}

/** Join the control-plane snapshot with the registry into dashboard entries:
 * control-plane rows first (authoritative list), then registry-only rows
 * (devices that never reached the new control plane). */
export async function loadDeviceDashboard(
  userId: string,
  accessToken: string | null,
): Promise<DeviceDashboardData> {
  const [registry, snapshot] = await Promise.all([
    loadRegistryRows(userId),
    accessToken !== null
      ? fetchControlPlaneSnapshot(accessToken)
      : Promise.resolve(null),
  ]);

  const devices: DeviceDashboardEntry[] = [];
  const merged = new Set<string>();
  for (const row of snapshot?.devices ?? []) {
    merged.add(row.endpointId);
    const registryRow = registry.get(row.endpointId);
    const platform = registryRow ? registryPlatform(registryRow.platform) : null;
    const inferred = platform === null
      ? inferPlatform(row.clientNamespace ?? registryRow?.clientNamespace ?? null)
      : null;
    devices.push({
      endpointId: row.endpointId,
      displayName: registryRow?.displayName ?? null,
      platform: platform ?? inferred,
      platformInferred: platform === null && inferred !== null,
      tag: registryRow?.tag ?? row.instanceTag,
      clientNamespace: row.clientNamespace ?? registryRow?.clientNamespace ?? null,
      deviceId: row.deviceId ?? registryRow?.deviceUuid ?? null,
      lastSeenAt: registryRow?.lastSeenAt.toISOString() ?? null,
      registryRevokedAt: registryRow?.revokedAt?.toISOString() ?? null,
      listAuth: {
        listed: row.listed,
        status: row.status,
        revoked: row.revoked,
        appVersion: row.appVersion,
        releaseTrack: row.releaseTrack,
        capabilities: row.capabilities,
        lastConfirmedAt: row.lastConfirmedAt,
        lastAckedRev: row.lastAckedRev,
        connected: row.connected,
      },
    });
  }
  for (const [endpointId, row] of registry) {
    if (merged.has(endpointId)) continue;
    devices.push({
      endpointId,
      displayName: row.displayName,
      platform: registryPlatform(row.platform),
      platformInferred: false,
      tag: row.tag,
      clientNamespace: row.clientNamespace,
      deviceId: row.deviceUuid,
      lastSeenAt: row.lastSeenAt.toISOString(),
      registryRevokedAt: row.revokedAt?.toISOString() ?? null,
      listAuth: null,
    });
  }

  return {
    controlPlaneAvailable: snapshot !== null,
    rev: snapshot?.rev ?? null,
    ttlSeconds: snapshot?.ttlSeconds ?? null,
    minimumSupportedVersion: snapshot?.minimumSupportedVersion ?? null,
    devices,
  };
}

export type ControlPlaneMutationResult =
  | { readonly ok: true; readonly rev: number | null; readonly changed: boolean }
  | { readonly ok: false; readonly status: number; readonly error: string };

async function controlPlaneMutation(
  path: string,
  accessToken: string,
  body: Record<string, unknown>,
): Promise<ControlPlaneMutationResult> {
  const response = await presenceFetch(path, accessToken, {
    method: "POST",
    body: JSON.stringify(body),
  });
  if (!response) {
    return { ok: false, status: 503, error: "control_plane_unavailable" };
  }
  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const error = isObject(payload) && typeof payload.error === "string"
      ? payload.error
      : "control_plane_error";
    return { ok: false, status: response.status, error };
  }
  const rev = isObject(payload) && typeof payload.rev === "number" ? payload.rev : null;
  const changed = isObject(payload) && payload.changed === true;
  return { ok: true, rev, changed };
}

/** Flip the DO revoked flag: the device stays listed, flagged DISALLOWED; the
 * DO broadcasts the new revision, closes the device's control sockets, and
 * refuses its relay-pass mints. */
export async function revokeDeviceOnControlPlane(
  accessToken: string,
  endpointId: string,
  revoked: boolean,
): Promise<ControlPlaneMutationResult> {
  return controlPlaneMutation("/v1/control/devices/revoke", accessToken, { endpointId, revoked });
}

/** Mark a device retired on the DO (dashboard "remove": cleanup, not a
 * security action; un-retires on the device's next hello). */
export async function retireDeviceOnControlPlane(
  accessToken: string,
  endpointId: string,
): Promise<ControlPlaneMutationResult> {
  return controlPlaneMutation("/v1/control/devices/retire", accessToken, { endpointId });
}

/** Shared-store half of a dashboard revocation: revoke the endpoint's active
 * registry binding so OLD clients' discovery drops the device too, then
 * nudge v2 subscribers with the advanced account revision. Returns the
 * advanced revision, or null when there was no active row (already revoked,
 * or never registered on the old stack — both fine for the mirror). */
export async function mirrorRevocationToRegistry(
  userId: string,
  endpointId: string,
  accessToken: string,
): Promise<number | null> {
  const commit = await Effect.runPromise(
    Effect.gen(function* () {
      const repository = yield* IrohRepository;
      return yield* repository.revokeEndpointForAccountOwner({
        userId,
        endpointId,
        now: new Date(),
      });
    }).pipe(Effect.provide(IrohRepositoryLive)),
  );
  if (!commit.revoked) return null;
  const publication = buildConnectivityInvalidationRequest(
    new Request("https://cmux.com/api/devices/dashboard/revoke", {
      headers: { authorization: `Bearer ${accessToken}` },
    }),
    commit.accountRevision,
  );
  if (publication) {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(new Error("connectivity_invalidation_timeout")),
      INVALIDATION_TIMEOUT_MS,
    );
    try {
      await fetch(publication, { signal: controller.signal });
    } catch {
      // The registry commit already happened; the worker's periodic refresh
      // reconciles v2 subscribers without this accelerator.
    } finally {
      clearTimeout(timeout);
    }
  }
  return commit.accountRevision;
}
