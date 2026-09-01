// Account control plane — pure core (no Workers APIs, bun-testable).
//
// One AccountControlPlane Durable Object per verified Stack user id serves a
// WebSocket over which a signed-in cmux device receives, as revisioned facts,
// everything it needs to connect to its Macs: the account directory (bindings
// + home-relay hints + grant verification keys + relay fleet), relay passes,
// and live hint updates. Phase A: the DO is a smart proxy over the existing
// Vercel broker HTTPS endpoints (GET api/devices/iroh, POST api/relay/token);
// it is NOT the source of truth. Wire contract: schemas/control-plane/*, with
// generated types in ./generated/controlPlane (frozen — never hand-edited).
//
// This module holds every piece of logic that does not need workerd: frame
// parsing/building, upstream response mapping, and the ControlPlaneCore state
// machine driven through narrow injected dependencies (storage, upstream
// fetch, sockets, clock, alarm). The thin Durable Object adapter lives in
// controlPlaneDo.ts.

import type {
  Binding,
  CTLACK,
  CTLDirectory,
  CTLDirectoryPayload,
  CTLError,
  CTLHello,
  CTLHelloACK,
  CTLHelloPayload,
  CTLHintUpdate,
  CTLMintRequest,
  CTLPublishHint,
  CTLRelayPasses,
  CTLSnapshotComplete,
  FluffyProof,
  GrantVerificationKey,
  Pass,
  PurpleMinimumSupportedVersion,
  ReleaseTrack,
  Status,
} from "./generated/controlPlane";

export const CONTROL_PROTOCOL_VERSION = 1;

/** Mirrors MAX_CONNECTIVITY_SUBSCRIBERS_PER_ACCOUNT: one account's devices are
 * few; a runaway client must not pin unbounded sockets on the account DO. */
export const MAX_CONTROL_SUBSCRIBERS_PER_ACCOUNT = 32;

/** Max bytes of an inbound WS message the DO will parse. Client-controlled
 * input on a live DO, so bounded before JSON.parse (same rationale as the
 * presence DO's MAX_SYNC_HELLO_BYTES). The largest legitimate client frame is
 * a publish_hint with proof, well under 2 KiB. */
export const MAX_CONTROL_MESSAGE_BYTES = 8 * 1024;

/** While any socket is connected, the DO re-fetches discovery on this cadence
 * (alarm-driven, hibernation-friendly) and broadcasts deltas. */
export const CONTROL_REFRESH_INTERVAL_MS = 60_000;

/** Application heartbeat for the hibernatable WebSocket. Workers exposes
 * text/binary sends but no portable server-side RFC6455 ping method, so this
 * lightweight frame keeps idle intermediaries from reaping the network path.
 * It is a liveness signal, not an authentication or subscription deadline. */
export const CONTROL_HEARTBEAT_TYPE = "ping" as const;

/** A publish_hint is an ANNOUNCEMENT (phase A never writes hints to Vercel —
 * hint registration upstream is a challenge + Ed25519-signed registration flow
 * only the Mac itself can perform). The DO broadcasts the claim immediately,
 * then confirms against broker truth this soon after. */
export const HINT_CONFIRM_DELAY_MS = 3_000;

/** When the initial directory fetch fails and there is no cache to serve, the
 * socket stays snapshot-pending and the alarm retries this soon. */
export const SNAPSHOT_RETRY_DELAY_MS = 5_000;

/** Trust lease served with every directory (and re-stamped through
 * snapshot_complete.issuedAt): clients treat the list as stale once
 * issuedAt + ttlSeconds passes without a fresher stamp. */
export const DIRECTORY_TTL_SECONDS = 86_400;

/** Advertised in every hello_ack so clients can feature-gate on the server:
 * device-list overlay, ack tracking, and account-owner revocation. */
export const CONTROL_SERVER_CAPABILITIES: readonly string[] = [
  "cmux.ctl.listv2",
  "cmux.ctl.ack",
  "cmux.ctl.revocation",
];

/** Ack retry ladder: a socket that has not acked the newest broadcast revision
 * gets the LATEST directory (never historical deltas) resent at these offsets,
 * then hourly until it acks. Per socket, reset on ack, alarm-driven — no
 * timers. */
export const ACK_RETRY_LADDER_MS: readonly number[] = [5_000, 30_000, 120_000, 600_000];
export const ACK_RETRY_STEADY_MS = 3_600_000;

const MAX_ENDPOINT_ID_CHARS = 128;
const MAX_RELAY_URL_CHARS = 512;
/** Bounds for hello client info. Exceeding one skips the confirm-on-hello
 * (the hello itself still proceeds); nothing oversized reaches storage. */
const MAX_DEVICE_ID_CHARS = 128;
const MAX_APP_VERSION_CHARS = 64;
const MAX_CLIENT_CAPABILITIES = 32;
const MAX_CLIENT_CAPABILITY_CHARS = 64;

// ---- Storage keys (all under the account DO's own storage) ----

/** Last account route revision this DO observed (upstream `revision`, or the
 * local fallback counter when upstream omits it). */
export const REV_KEY = "ctl:rev";
/** Cached BrokerDirectoryPayload from the last successful discovery fetch.
 * Broker truth only: publish_hint announcements are never folded in, and the
 * DO-owned device overlay is joined in at directory build time, not here. */
export const DIR_KEY = "ctl:dir";
/** Per-endpoint relay-pass mint generation counter (`ctl:gen:<endpointId>`).
 * The broker response carries no generation; passes minted in one batch share
 * one monotonically increasing number so clients can order credential sets. */
export const GEN_PREFIX = "ctl:gen:";
/** Per-socket bearer token (`ctl:bearer:<sessionId>`), stored so upstream
 * calls survive DO hibernation. Strictly per-socket for endpoint-bound calls
 * (mint); deleted on close and on revocation. The control adapter keeps these
 * credentials for the lifetime of its authenticated socket. */
export const BEARER_PREFIX = "ctl:bearer:";
/** Per-device authorization overlay (`ctl:dev:<endpointId>`): the DO-owned
 * listv2 facts (status, revoked, version/track/capabilities, confirmation and
 * ack watermarks) joined onto broker bindings at every directory build. Rows
 * whose binding disappeared upstream are kept (so revocation survives a
 * binding flap) but never emitted. */
export const DEV_PREFIX = "ctl:dev:";

/** The stored shape under DEV_PREFIX. lastAckedRev is bookkeeping only and is
 * never emitted in the directory. deviceId/clientNamespace are captured at
 * confirm-on-hello so a confirmed device can still be emitted (synthesized)
 * when the upstream discovery view omits it — e.g. a namespace-filtered
 * broker view, or upstream registration lag. */
export interface DeviceOverlay {
  status: Status;
  revoked: boolean;
  appVersion?: string;
  releaseTrack?: ReleaseTrack;
  capabilities?: string[];
  lastConfirmedAt?: string;
  lastAckedRev?: number;
  deviceId?: string;
  clientNamespace?: string;
}

// The generated types annotate RFC3339 `format: date-time` fields as `Date`,
// but quicktype ran with --just-types (no converters): on the wire — and at
// runtime here — they are plain RFC3339 strings. This is the single cast site.
function wireDate(iso: string): Date {
  return iso as unknown as Date;
}

function rfc3339FromMs(ms: number): string {
  return new Date(ms).toISOString();
}

// ---- Frame decoding (strict: mirrors additionalProperties:false) ----

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): boolean {
  for (const key of required) {
    if (!(key in value)) return false;
  }
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key)) return false;
  }
  return true;
}

function isRev(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function validEnvelope(
  value: Record<string, unknown>,
  type: string,
  withRev: boolean,
): boolean {
  const keys = withRev ? (["v", "type", "rev", "payload"] as const) : (["v", "type", "payload"] as const);
  if (!hasOnlyKeys(value, keys)) return false;
  if (value.v !== CONTROL_PROTOCOL_VERSION) return false;
  if (value.type !== type) return false;
  if (withRev && !isRev(value.rev)) return false;
  return isObject(value.payload);
}

const DEVICE_STATUSES: ReadonlySet<string> = new Set([
  "active",
  "seeded",
  "stale",
  "retired",
  "suspended",
  "pending",
  "superseded",
]);

const RELEASE_TRACKS: ReadonlySet<string> = new Set([
  "nightly",
  "stable",
  "internal",
  "beta",
  "appstore",
  "dev",
]);

const CLIENT_PLATFORMS: ReadonlySet<string> = new Set(["mac", "ios"]);

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function validMinimumSupportedVersion(value: unknown): boolean {
  if (!isObject(value)) return false;
  if (!hasOnlyKeys(value, [], ["mac", "ios"])) return false;
  for (const key of ["mac", "ios"] as const) {
    if (key in value && typeof value[key] !== "string") return false;
  }
  return true;
}

function validProof(value: unknown): value is FluffyProof {
  if (!isObject(value)) return false;
  if (!hasOnlyKeys(value, ["bindingId", "timestamp", "signature"])) return false;
  return typeof value.bindingId === "string"
    && typeof value.timestamp === "string"
    && typeof value.signature === "string";
}

function validBinding(value: unknown): value is Binding {
  if (!isObject(value)) return false;
  if (!hasOnlyKeys(
    value,
    ["bindingId", "endpointId", "clientNamespace", "revoked"],
    [
      "deviceId",
      "instanceTag",
      "homeRelayUrl",
      "updatedAt",
      "status",
      "appVersion",
      "releaseTrack",
      "capabilities",
      "lastConfirmedAt",
    ],
  )) return false;
  if (typeof value.bindingId !== "string") return false;
  if (typeof value.endpointId !== "string") return false;
  if (typeof value.clientNamespace !== "string") return false;
  if (typeof value.revoked !== "boolean") return false;
  for (const key of ["deviceId", "instanceTag", "homeRelayUrl", "updatedAt"] as const) {
    if (key in value && value[key] !== null && typeof value[key] !== "string") return false;
  }
  if ("status" in value
    && !(typeof value.status === "string" && DEVICE_STATUSES.has(value.status))) return false;
  if ("appVersion" in value && typeof value.appVersion !== "string") return false;
  if ("releaseTrack" in value
    && !(typeof value.releaseTrack === "string" && RELEASE_TRACKS.has(value.releaseTrack))) return false;
  if ("capabilities" in value && !isStringArray(value.capabilities)) return false;
  if ("lastConfirmedAt" in value && typeof value.lastConfirmedAt !== "string") return false;
  return true;
}

function validGrantKey(value: unknown): value is GrantVerificationKey {
  if (!isObject(value)) return false;
  if (!hasOnlyKeys(value, ["keyId", "alg", "publicKey"])) return false;
  return typeof value.keyId === "string"
    && typeof value.alg === "string"
    && typeof value.publicKey === "string";
}

function validPass(value: unknown): value is Pass {
  if (!isObject(value)) return false;
  if (!hasOnlyKeys(value, ["relayUrl", "token", "expiresAt", "refreshAfter", "generation"])) return false;
  return typeof value.relayUrl === "string"
    && typeof value.token === "string"
    && typeof value.expiresAt === "string"
    && typeof value.refreshAfter === "string"
    && typeof value.generation === "number" && Number.isSafeInteger(value.generation);
}

export type DecodedControlFrame =
  | { kind: "hello"; frame: CTLHello }
  | { kind: "hello_ack"; frame: CTLHelloACK }
  | { kind: "directory"; frame: CTLDirectory }
  | { kind: "hint_update"; frame: CTLHintUpdate }
  | { kind: "relay_passes"; frame: CTLRelayPasses }
  | { kind: "snapshot_complete"; frame: CTLSnapshotComplete }
  | { kind: "error"; frame: CTLError }
  | { kind: "mint_request"; frame: CTLMintRequest }
  | { kind: "publish_hint"; frame: CTLPublishHint }
  | { kind: "ack"; frame: CTLACK };

/** Decode ANY control-plane envelope (server- or client-originated) into the
 * generated wire types, enforcing the schemas' exact-keys and required-fields
 * rules. Returns null on any deviation. Structure-preserving: the returned
 * frame is the validated input value, so round-tripping through JSON is
 * lossless (asserted by the golden-fixture tests). */
export function decodeControlFrame(value: unknown): DecodedControlFrame | null {
  if (!isObject(value) || typeof value.type !== "string") return null;
  const payload = isObject(value.payload) ? value.payload : null;
  if (payload === null) return null;
  switch (value.type) {
    case "hello": {
      if (!validEnvelope(value, "hello", false)) return null;
      if (!hasOnlyKeys(
        payload,
        ["endpointId", "wantPasses"],
        ["haveRev", "deviceId", "platform", "appVersion", "releaseTrack", "capabilities"],
      )) return null;
      if (typeof payload.endpointId !== "string") return null;
      if (typeof payload.wantPasses !== "boolean") return null;
      if ("haveRev" in payload
        && payload.haveRev !== null
        && !(typeof payload.haveRev === "number" && Number.isSafeInteger(payload.haveRev))) {
        return null;
      }
      if ("deviceId" in payload && typeof payload.deviceId !== "string") return null;
      if ("platform" in payload
        && !(typeof payload.platform === "string" && CLIENT_PLATFORMS.has(payload.platform))) {
        return null;
      }
      if ("appVersion" in payload && typeof payload.appVersion !== "string") return null;
      if ("releaseTrack" in payload
        && !(typeof payload.releaseTrack === "string" && RELEASE_TRACKS.has(payload.releaseTrack))) {
        return null;
      }
      if ("capabilities" in payload && !isStringArray(payload.capabilities)) return null;
      return { kind: "hello", frame: value as unknown as CTLHello };
    }
    case "hello_ack": {
      if (!validEnvelope(value, "hello_ack", false)) return null;
      if (!hasOnlyKeys(
        payload,
        ["sessionId"],
        ["resumedFromRev", "serverCapabilities", "minimumSupportedVersion"],
      )) return null;
      if (typeof payload.sessionId !== "string") return null;
      if ("resumedFromRev" in payload
        && payload.resumedFromRev !== null
        && !(typeof payload.resumedFromRev === "number" && Number.isSafeInteger(payload.resumedFromRev))) {
        return null;
      }
      if ("serverCapabilities" in payload && !isStringArray(payload.serverCapabilities)) return null;
      if ("minimumSupportedVersion" in payload
        && !validMinimumSupportedVersion(payload.minimumSupportedVersion)) return null;
      return { kind: "hello_ack", frame: value as unknown as CTLHelloACK };
    }
    case "directory": {
      if (!validEnvelope(value, "directory", true)) return null;
      if (!hasOnlyKeys(payload, [
        "routeContractVersion",
        "bindings",
        "relayFleet",
        "grantVerificationKeys",
        "issuedAt",
        "ttlSeconds",
      ], ["minimumSupportedVersion"])) return null;
      if (!(typeof payload.routeContractVersion === "number"
        && Number.isSafeInteger(payload.routeContractVersion))) return null;
      if (!Array.isArray(payload.bindings) || !payload.bindings.every(validBinding)) return null;
      if (!Array.isArray(payload.relayFleet)
        || !payload.relayFleet.every((url) => typeof url === "string")) return null;
      if (!Array.isArray(payload.grantVerificationKeys)
        || !payload.grantVerificationKeys.every(validGrantKey)) return null;
      if (typeof payload.issuedAt !== "string") return null;
      if (!(typeof payload.ttlSeconds === "number" && Number.isSafeInteger(payload.ttlSeconds))) {
        return null;
      }
      if ("minimumSupportedVersion" in payload
        && !validMinimumSupportedVersion(payload.minimumSupportedVersion)) return null;
      return { kind: "directory", frame: value as unknown as CTLDirectory };
    }
    case "hint_update": {
      if (!validEnvelope(value, "hint_update", true)) return null;
      if (!hasOnlyKeys(payload, ["endpointId", "homeRelayUrl"], ["updatedAt"])) return null;
      if (typeof payload.endpointId !== "string") return null;
      if (typeof payload.homeRelayUrl !== "string") return null;
      if ("updatedAt" in payload && payload.updatedAt !== null && typeof payload.updatedAt !== "string") {
        return null;
      }
      return { kind: "hint_update", frame: value as unknown as CTLHintUpdate };
    }
    case "relay_passes": {
      if (!validEnvelope(value, "relay_passes", true)) return null;
      if (!hasOnlyKeys(payload, ["endpointId", "passes"])) return null;
      if (typeof payload.endpointId !== "string") return null;
      if (!Array.isArray(payload.passes) || !payload.passes.every(validPass)) return null;
      return { kind: "relay_passes", frame: value as unknown as CTLRelayPasses };
    }
    case "snapshot_complete": {
      if (!validEnvelope(value, "snapshot_complete", true)) return null;
      if (!hasOnlyKeys(payload, [], ["issuedAt"])) return null;
      if ("issuedAt" in payload && typeof payload.issuedAt !== "string") return null;
      return { kind: "snapshot_complete", frame: value as unknown as CTLSnapshotComplete };
    }
    case "ack": {
      if (!validEnvelope(value, "ack", true)) return null;
      if (!hasOnlyKeys(payload, [], ["appliedAt"])) return null;
      if ("appliedAt" in payload && typeof payload.appliedAt !== "string") return null;
      return { kind: "ack", frame: value as unknown as CTLACK };
    }
    case "error": {
      if (!validEnvelope(value, "error", false)) return null;
      if (!hasOnlyKeys(payload, ["code", "message", "retryable"])) return null;
      if (typeof payload.code !== "string") return null;
      if (typeof payload.message !== "string") return null;
      if (typeof payload.retryable !== "boolean") return null;
      return { kind: "error", frame: value as unknown as CTLError };
    }
    case "mint_request": {
      if (!validEnvelope(value, "mint_request", false)) return null;
      if (!hasOnlyKeys(payload, ["endpointId"], ["proof"])) return null;
      if (typeof payload.endpointId !== "string") return null;
      if ("proof" in payload && !validProof(payload.proof)) return null;
      return { kind: "mint_request", frame: value as unknown as CTLMintRequest };
    }
    case "publish_hint": {
      if (!validEnvelope(value, "publish_hint", false)) return null;
      if (!hasOnlyKeys(payload, ["endpointId", "homeRelayUrl"], ["proof"])) return null;
      if (typeof payload.endpointId !== "string") return null;
      if (typeof payload.homeRelayUrl !== "string") return null;
      if ("proof" in payload && !validProof(payload.proof)) return null;
      return { kind: "publish_hint", frame: value as unknown as CTLPublishHint };
    }
    default:
      return null;
  }
}

// ---- Broker-truth payload shapes (what DIR_KEY stores) ----

/** A binding as the upstream discovery response asserts it. Overlay fields
 * (status/revoked/version/track/capabilities/confirmation) are DO-owned and
 * joined in at directory build time, never stored in broker truth. */
export type BrokerBinding = Omit<
  Binding,
  "status" | "revoked" | "appVersion" | "releaseTrack" | "capabilities" | "lastConfirmedAt"
>;

/** What DIR_KEY stores: broker truth only — no overlay join and no freshness
 * stamps (issuedAt/ttlSeconds are stamped per outbound frame, so a re-stamp
 * never looks like a content change). */
export interface BrokerDirectoryPayload {
  routeContractVersion: number;
  bindings: BrokerBinding[];
  relayFleet: string[];
  grantVerificationKeys: GrantVerificationKey[];
  minimumSupportedVersion?: PurpleMinimumSupportedVersion;
}

/** The wire directory body minus the per-send freshness stamps. */
export type WireDirectoryBody = Omit<CTLDirectoryPayload, "issuedAt" | "ttlSeconds">;

// ---- Server frame builders ----

export function helloAckFrame(
  sessionId: string,
  resumedFromRev: number | null,
  minimumSupportedVersion: PurpleMinimumSupportedVersion | null = null,
): CTLHelloACK {
  return {
    v: CONTROL_PROTOCOL_VERSION,
    type: "hello_ack",
    payload: {
      sessionId,
      resumedFromRev,
      serverCapabilities: [...CONTROL_SERVER_CAPABILITIES],
      ...(minimumSupportedVersion ? { minimumSupportedVersion } : {}),
    },
  };
}

export function directoryFrame(
  rev: number,
  body: WireDirectoryBody,
  issuedAtIso: string,
): CTLDirectory {
  return {
    v: CONTROL_PROTOCOL_VERSION,
    type: "directory",
    rev,
    payload: { ...body, issuedAt: wireDate(issuedAtIso), ttlSeconds: DIRECTORY_TTL_SECONDS },
  };
}

export function relayPassesFrame(rev: number, endpointId: string, passes: Pass[]): CTLRelayPasses {
  return {
    v: CONTROL_PROTOCOL_VERSION,
    type: "relay_passes",
    rev,
    payload: { endpointId, passes },
  };
}

export function hintUpdateFrame(
  rev: number,
  endpointId: string,
  homeRelayUrl: string,
  updatedAtIso: string | null,
): CTLHintUpdate {
  return {
    v: CONTROL_PROTOCOL_VERSION,
    type: "hint_update",
    rev,
    payload: {
      endpointId,
      homeRelayUrl,
      updatedAt: updatedAtIso === null ? null : wireDate(updatedAtIso),
    },
  };
}

/** snapshot_complete doubles as the explicit-freshness "current" frame: when a
 * hello's haveRev already equals head, this stamp alone re-arms the client's
 * directory trust lease (no separate frame type on the wire). */
export function snapshotCompleteFrame(rev: number, issuedAtIso: string): CTLSnapshotComplete {
  return {
    v: CONTROL_PROTOCOL_VERSION,
    type: "snapshot_complete",
    rev,
    payload: { issuedAt: wireDate(issuedAtIso) },
  };
}

export function errorFrame(code: string, message: string, retryable: boolean): CTLError {
  return { v: CONTROL_PROTOCOL_VERSION, type: "error", payload: { code, message, retryable } };
}

// ---- Upstream response mapping ----

/** Map the broker discovery response (GET api/devices/iroh; see
 * web/services/iroh/trustBroker.ts serializeDiscovery) onto the wire
 * directory payload. `revision` is the broker's monotonic account route
 * revision, or null when the response omits it (the DO then falls back to a
 * storage counter). Returns null when the response is not a discovery shape,
 * which callers treat as an upstream failure. Individual malformed bindings
 * are skipped rather than failing the whole directory. */
export function directoryPayloadFromDiscovery(
  value: unknown,
): { revision: number | null; payload: BrokerDirectoryPayload } | null {
  if (!isObject(value)) return null;
  if (!Array.isArray(value.bindings)) return null;

  const bindings: BrokerBinding[] = [];
  for (const raw of value.bindings) {
    if (!isObject(raw)) continue;
    const bindingId = raw.binding_id;
    const endpointId = raw.endpoint_id;
    const clientNamespace = raw.client_namespace;
    if (typeof bindingId !== "string" || typeof endpointId !== "string"
      || typeof clientNamespace !== "string") continue;
    let homeRelayUrl: string | null = null;
    if (Array.isArray(raw.path_hints)) {
      for (const hint of raw.path_hints) {
        if (isObject(hint) && hint.kind === "relay_url" && typeof hint.value === "string") {
          homeRelayUrl = hint.value;
          break;
        }
      }
    }
    bindings.push({
      bindingId,
      endpointId,
      clientNamespace,
      deviceId: typeof raw.device_id === "string" ? raw.device_id : null,
      instanceTag: typeof raw.tag === "string" ? raw.tag : null,
      homeRelayUrl,
      updatedAt: typeof raw.last_seen_at === "string" ? wireDate(raw.last_seen_at) : null,
    });
  }

  const relayFleet = Array.isArray(value.relay_fleet)
    ? value.relay_fleet.filter((url): url is string => typeof url === "string")
    : [];

  const grantVerificationKeys: GrantVerificationKey[] = [];
  const keySet = value.grant_verification_keys;
  if (isObject(keySet) && Array.isArray(keySet.keys)) {
    for (const raw of keySet.keys) {
      if (!isObject(raw)) continue;
      if (typeof raw.kid !== "string" || typeof raw.alg !== "string"
        || typeof raw.spki_der_base64 !== "string") continue;
      grantVerificationKeys.push({
        keyId: raw.kid,
        alg: raw.alg,
        publicKey: raw.spki_der_base64,
      });
    }
  }

  const routeContractVersion =
    typeof value.route_contract_version === "number"
      && Number.isSafeInteger(value.route_contract_version)
      ? value.route_contract_version
      : 1;
  const revision =
    typeof value.revision === "number"
      && Number.isSafeInteger(value.revision)
      && value.revision > 0
      ? value.revision
      : null;

  // Optional per-platform app-version floors, when the broker publishes them.
  let minimumSupportedVersion: PurpleMinimumSupportedVersion | undefined;
  const minRaw = value.minimum_supported_version;
  if (isObject(minRaw)) {
    const mac = typeof minRaw.mac === "string" ? minRaw.mac : undefined;
    const ios = typeof minRaw.ios === "string" ? minRaw.ios : undefined;
    if (mac !== undefined || ios !== undefined) {
      minimumSupportedVersion = {
        ...(mac !== undefined ? { mac } : {}),
        ...(ios !== undefined ? { ios } : {}),
      };
    }
  }

  return {
    revision,
    payload: {
      routeContractVersion,
      bindings,
      relayFleet,
      grantVerificationKeys,
      ...(minimumSupportedVersion !== undefined ? { minimumSupportedVersion } : {}),
    },
  };
}

/** Map the relay-token mint response (POST api/relay/token; see
 * web/app/api/relay/token/route.ts) onto wire passes. Prefers the
 * per-relay `relayCredentials` set and falls back to the legacy homogeneous
 * `token`/`expiresAt`/`refreshAfter`/`relays` fields. Returns null when the
 * response issued no credentials (policy-only response for an unregistered
 * endpoint or an unsigned local runtime). `generation` is DO-assigned: the
 * broker response has no generation, so the DO stamps each mint batch with a
 * per-endpoint counter. */
export function passesFromMintResponse(value: unknown, generation: number): Pass[] | null {
  if (!isObject(value)) return null;

  const fromEpochSeconds = (raw: unknown): string | null =>
    typeof raw === "number" && Number.isSafeInteger(raw) && raw > 0
      ? rfc3339FromMs(raw * 1000)
      : null;

  if (Array.isArray(value.relayCredentials)) {
    const passes: Pass[] = [];
    for (const raw of value.relayCredentials) {
      if (!isObject(raw)) return null;
      const expiresAt = fromEpochSeconds(raw.expiresAt);
      const refreshAfter = fromEpochSeconds(raw.refreshAfter);
      if (typeof raw.relayUrl !== "string" || typeof raw.token !== "string"
        || expiresAt === null || refreshAfter === null) return null;
      passes.push({
        relayUrl: raw.relayUrl,
        token: raw.token,
        expiresAt: wireDate(expiresAt),
        refreshAfter: wireDate(refreshAfter),
        generation,
      });
    }
    return passes.length > 0 ? passes : null;
  }

  if (typeof value.token === "string" && Array.isArray(value.relays)) {
    const expiresAt = fromEpochSeconds(value.expiresAt);
    if (expiresAt === null) return null;
    // Legacy responses carry no refreshAfter; refresh at expiry.
    const refreshAfter = fromEpochSeconds(value.refreshAfter) ?? expiresAt;
    const passes: Pass[] = [];
    for (const relayUrl of value.relays) {
      if (typeof relayUrl !== "string") continue;
      passes.push({
        relayUrl,
        token: value.token,
        expiresAt: wireDate(expiresAt),
        refreshAfter: wireDate(refreshAfter),
        generation,
      });
    }
    return passes.length > 0 ? passes : null;
  }

  return null;
}

// ---- Directory delta classification ----

export type DirectoryDelta =
  | { kind: "none" }
  | { kind: "hints"; updates: { endpointId: string; homeRelayUrl: string; updatedAt: string | null }[] }
  | { kind: "full" };

/** Classify what changed between two directory payloads so refresh broadcasts
 * stay minimal: pure home-relay-hint movement becomes per-binding hint_update
 * frames; anything structural (bindings added/removed, identity or trust
 * material changed, a hint removed — hint_update cannot express null) falls
 * back to a full directory frame. */
export function directoryDelta(
  previous: BrokerDirectoryPayload | undefined,
  next: BrokerDirectoryPayload,
): DirectoryDelta {
  if (previous === undefined) return { kind: "full" };
  if (JSON.stringify(previous) === JSON.stringify(next)) return { kind: "none" };
  if (previous.routeContractVersion !== next.routeContractVersion) return { kind: "full" };
  if (JSON.stringify(previous.relayFleet) !== JSON.stringify(next.relayFleet)) return { kind: "full" };
  if (JSON.stringify(previous.grantVerificationKeys) !== JSON.stringify(next.grantVerificationKeys)) {
    return { kind: "full" };
  }
  if (JSON.stringify(previous.minimumSupportedVersion ?? null)
    !== JSON.stringify(next.minimumSupportedVersion ?? null)) {
    return { kind: "full" };
  }
  const prevById = new Map(previous.bindings.map((binding) => [binding.bindingId, binding]));
  if (prevById.size !== next.bindings.length) return { kind: "full" };
  const updates: { endpointId: string; homeRelayUrl: string; updatedAt: string | null }[] = [];
  for (const binding of next.bindings) {
    const prev = prevById.get(binding.bindingId);
    if (!prev) return { kind: "full" };
    const { homeRelayUrl: prevHint, updatedAt: prevAt, ...prevRest } = prev;
    const { homeRelayUrl: nextHint, updatedAt: nextAt, ...nextRest } = binding;
    if (JSON.stringify(prevRest) !== JSON.stringify(nextRest)) return { kind: "full" };
    if ((prevHint ?? null) === (nextHint ?? null)) continue;
    if (typeof nextHint !== "string") return { kind: "full" }; // hint removed
    updates.push({
      endpointId: binding.endpointId,
      homeRelayUrl: nextHint,
      updatedAt: typeof nextAt === "string" ? nextAt : null,
    });
  }
  return updates.length > 0 ? { kind: "hints", updates } : { kind: "none" };
}

// ---- Core dependencies (injected; the DO adapter and tests provide them) ----

export interface CtlAttachment {
  sessionId: string;
  /** Optional lifecycle cutoff used by test doubles and legacy adapters. The
   * production control adapter uses a non-expiring sentinel after authenticating
   * the upgrade in the worker. */
  expiresAt?: number;
  /** Validated x-cmux-app-namespace from the upgrade request; forwarded on
   * upstream calls so discovery/mint see the same namespace the client's own
   * HTTPS calls would carry. */
  namespace?: string;
  /** Declared by hello. Phase A trusts the declaration: facts are account-
   * scoped, and passes minted for a declared endpointId are useless to any
   * other key by relay design. */
  endpointId?: string;
  wantPasses?: boolean;
  /** True once a hello arrived. Only helloed sockets receive broadcasts. */
  helloed?: boolean;
  /** True when the initial directory fetch failed with no cache to serve; the
   * alarm retries and completes the snapshot when upstream recovers. */
  snapshotPending?: boolean;
  /** Highest revision this socket has acked (client applied that directory or
   * hint revision). Mirrored into the device overlay's lastAckedRev when the
   * socket is bound to a known device. */
  lastAckedRev?: number;
  /** Retry-ladder state for the newest revision delivered but not yet acked:
   * resend the LATEST directory at nextAt, then climb the ladder. Cleared by
   * an ack covering `rev`. */
  ackRetry?: { rev: number; attempt: number; nextAt: number };
}

// ---- Device revocation (worker HTTP route -> account DO) ----

export interface RevocationRequest {
  endpointId: string;
  revoked: boolean;
}

/** Strict body parse for POST /v1/control/devices/revoke, shared by the
 * worker route and the DO adapter. The account identity NEVER rides in this
 * body — the worker derives the DO from the verified Stack user id. */
export function parseRevocationRequest(value: unknown): RevocationRequest | null {
  if (!isObject(value)) return null;
  if (!hasOnlyKeys(value, ["endpointId", "revoked"])) return null;
  if (typeof value.endpointId !== "string"
    || value.endpointId.length === 0
    || value.endpointId.length > MAX_ENDPOINT_ID_CHARS) return null;
  if (typeof value.revoked !== "boolean") return null;
  return { endpointId: value.endpointId, revoked: value.revoked };
}

export interface CtlSocket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  getAttachment(): CtlAttachment | null;
  setAttachment(attachment: CtlAttachment): void;
}

export interface CtlStorage {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<boolean>;
  /** Prefix scan (DurableObjectStorage.list-compatible). */
  list<T>(options: { prefix: string }): Promise<Map<string, T>>;
}

export interface CtlUpstreamInit {
  method: string;
  headers: Record<string, string>;
  body?: string;
}

export interface CtlUpstreamResult {
  status: number;
  json: unknown;
}

export interface CtlDeps {
  storage: CtlStorage;
  now(): number;
  /** Perform one upstream HTTPS call against the configured Vercel base URL.
   * MUST throw on connection-level failure (DNS, TCP, TLS, aborted body) and
   * resolve with the status for any HTTP response. */
  upstream(path: string, init: CtlUpstreamInit): Promise<CtlUpstreamResult>;
  /** Pull the DO alarm earlier if `atMs` precedes the currently scheduled
   * one (ensure-at semantics, provided by the adapter). */
  scheduleAlarmAt(atMs: number): Promise<void>;
  /** All currently connected sockets (hibernation-aware in the adapter). */
  sockets(): CtlSocket[];
}

export interface CtlConnectInput {
  sessionId: string;
  expiresAt?: number;
  bearer: string;
  /** Stack refresh token: the web API's native auth (parseNativeStackTokens)
   * requires BOTH the bearer and x-stack-refresh-token; a bearer alone 401s. */
  refresh?: string;
  namespace?: string;
}

/** Stored per-socket credentials under BEARER_PREFIX. Serialized as JSON;
 * a bare-string value (pre-refresh deploys) is read as bearer-only. */
interface StoredCtlCredentials {
  bearer: string;
  refresh?: string;
}

function encodeStoredCredentials(input: StoredCtlCredentials): string {
  return JSON.stringify(input);
}

function decodeStoredCredentials(raw: string | undefined): StoredCtlCredentials | undefined {
  if (raw === undefined) return undefined;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed === "object" && parsed !== null
      && typeof (parsed as { bearer?: unknown }).bearer === "string") {
      const refresh = (parsed as { refresh?: unknown }).refresh;
      return {
        bearer: (parsed as { bearer: string }).bearer,
        ...(typeof refresh === "string" ? { refresh } : {}),
      };
    }
  } catch {
    // fall through: legacy bare-bearer value
  }
  return { bearer: raw };
}

const DISCOVERY_PATH = "/api/devices/iroh";
const MINT_PATH = "/api/relay/token";

function upstreamHeaders(credentials: StoredCtlCredentials, namespace: string | undefined, json: boolean): Record<string, string> {
  return {
    authorization: `Bearer ${credentials.bearer}`,
    ...(credentials.refresh ? { "x-stack-refresh-token": credentials.refresh } : {}),
    accept: "application/json",
    ...(json ? { "content-type": "application/json" } : {}),
    ...(namespace ? { "x-cmux-app-namespace": namespace } : {}),
  };
}

export class ControlPlaneCore {
  constructor(private readonly deps: CtlDeps) {}

  // ---- Connection lifecycle ----

  async handleConnect(socket: CtlSocket, input: CtlConnectInput): Promise<void> {
    socket.setAttachment({
      sessionId: input.sessionId,
      ...(input.expiresAt !== undefined ? { expiresAt: input.expiresAt } : {}),
      ...(input.namespace ? { namespace: input.namespace } : {}),
    });
    await this.deps.storage.put(
      BEARER_PREFIX + input.sessionId,
      encodeStoredCredentials({
        bearer: input.bearer,
        ...(input.refresh ? { refresh: input.refresh } : {}),
      }),
    );
    const now = this.deps.now();
    await this.deps.scheduleAlarmAt(
      input.expiresAt === undefined
        ? now + CONTROL_REFRESH_INTERVAL_MS
        : Math.min(now + CONTROL_REFRESH_INTERVAL_MS, input.expiresAt),
    );
  }

  async handleClose(socket: CtlSocket): Promise<void> {
    const attachment = socket.getAttachment();
    if (attachment) await this.deps.storage.delete(BEARER_PREFIX + attachment.sessionId);
  }

  // ---- Inbound messages ----

  async handleMessage(socket: CtlSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = socket.getAttachment();
    if (!attachment) return;
    const now = this.deps.now();
    if (attachment.expiresAt !== undefined && attachment.expiresAt <= now) {
      try {
        socket.close(1000, "subscription expired; reconnect with a fresh token");
      } catch {
        // already closed
      }
      return;
    }
    // Bound BEFORE parse: client-controlled input on a live DO.
    const byteLength = typeof message === "string" ? message.length : message.byteLength;
    if (byteLength > MAX_CONTROL_MESSAGE_BYTES) return;
    let body: unknown;
    try {
      body = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch {
      return; // not JSON; ignore (consistent with the presence DO)
    }
    // Heartbeats are transport liveness frames, not durable control facts.
    if (isObject(body) && body.type === CONTROL_HEARTBEAT_TYPE) {
      try {
        socket.send(JSON.stringify({
          v: CONTROL_PROTOCOL_VERSION,
          type: "pong",
          payload: { at: new Date(now).toISOString() },
        }));
      } catch {
        // The peer went away between receive and reply.
      }
      return;
    }
    if (isObject(body) && body.type === "pong") return;
    const decoded = decodeControlFrame(body);
    if (decoded === null) return;
    switch (decoded.kind) {
      case "hello":
        await this.handleHello(socket, attachment, decoded.frame);
        return;
      case "mint_request":
        await this.handleMintRequest(socket, attachment, decoded.frame);
        return;
      case "publish_hint":
        await this.handlePublishHint(socket, attachment, decoded.frame);
        return;
      case "ack":
        await this.handleAck(socket, attachment, decoded.frame);
        return;
      default:
        return; // server-to-client frame echoed back; ignore
    }
  }

  // ---- hello: stream facts as each becomes ready, never assemble-then-send ----

  private async handleHello(
    socket: CtlSocket,
    attachment: CtlAttachment,
    frame: CTLHello,
  ): Promise<void> {
    // One hello per connection: a repeat would let an authenticated client
    // force repeated upstream fetches; the supported resync path is reconnect
    // (same rule as the presence DO's sync.hello).
    if (attachment.helloed) return;
    const payload = frame.payload;
    if (payload.endpointId.length > MAX_ENDPOINT_ID_CHARS) return;
    attachment.helloed = true;
    attachment.endpointId = payload.endpointId;
    attachment.wantPasses = payload.wantPasses;
    socket.setAttachment(attachment);

    // Confirm-on-hello BEFORE reading the head revision: the overlay flip
    // (seeded -> active, plus version/track/capabilities) bumps the revision
    // and broadcasts to peers, and the snapshot this client is about to
    // receive must already show its own confirmed entry.
    await this.confirmDeviceFromHello(attachment, payload);

    const storedRev = await this.deps.storage.get<number>(REV_KEY);
    const cached = await this.deps.storage.get<BrokerDirectoryPayload>(DIR_KEY);
    const haveRev = payload.haveRev ?? null;
    const resumed = haveRev !== null && storedRev !== undefined
      && haveRev === storedRev && cached !== undefined;

    this.sendFrame(socket, attachment, helloAckFrame(
      attachment.sessionId,
      resumed ? haveRev : null,
      // Version floors ride the hello_ack too, so clients hold them even
      // before (or without) a directory body.
      cached?.minimumSupportedVersion ?? null,
    ));

    if (resumed) {
      // Client already holds the current snapshot; skip the directory body.
      // snapshot_complete carries issuedAt: that stamp alone re-arms the
      // client's trust lease (the explicit-freshness "current" role rides on
      // the existing frame instead of adding a new one). The 60s alarm
      // refresh heals any staleness the DO itself has.
      await this.finishSnapshot(socket, attachment, storedRev);
      return;
    }

    const fetched = await this.fetchDirectory(attachment);
    if (fetched === null) {
      this.sendFrame(socket, attachment, errorFrame(
        "directory_unavailable",
        "directory fetch failed upstream; retrying",
        true,
      ));
      if (cached !== undefined && storedRev !== undefined) {
        // Serve the cached facts (stale rev is honest: the client can resume
        // from it) and complete the snapshot; the alarm refresh delivers
        // deltas when upstream recovers.
        await this.sendDirectory(socket, attachment, storedRev, cached);
        await this.finishSnapshot(socket, attachment, storedRev);
      } else {
        attachment.snapshotPending = true;
        socket.setAttachment(attachment);
        await this.deps.scheduleAlarmAt(this.deps.now() + SNAPSHOT_RETRY_DELAY_MS);
      }
      return;
    }

    const { rev, previous, previousRev } = await this.storeDirectory(fetched);
    await this.sendDirectory(socket, attachment, rev, fetched.payload);
    // This fetch doubles as a refresh for everyone else already snapshotted.
    await this.broadcastDirectoryChange(previous, fetched.payload, rev, previousRev, attachment.sessionId);
    await this.finishSnapshot(socket, attachment, rev);
  }

  // ---- Confirm-on-hello: client info claims the device's overlay entry ----

  /** A hello carrying any client-info field is the device confirming itself:
   * its overlay flips to "active", lastConfirmedAt is stamped, and declared
   * version/track/capabilities are recorded. That is a revision-bearing list
   * change, so the account revision bumps and peers get the new directory
   * (the confirming socket is excluded — its snapshot arrives inline).
   * Oversized client info skips the confirmation, never the hello. */
  private async confirmDeviceFromHello(
    attachment: CtlAttachment,
    payload: CTLHelloPayload,
  ): Promise<void> {
    const hasClientInfo = payload.deviceId != null || payload.platform != null
      || payload.appVersion != null || payload.releaseTrack != null
      || payload.capabilities != null;
    if (!hasClientInfo) return;
    if (payload.deviceId != null && payload.deviceId.length > MAX_DEVICE_ID_CHARS) return;
    if (payload.appVersion != null && payload.appVersion.length > MAX_APP_VERSION_CHARS) return;
    if (payload.capabilities != null && (
      payload.capabilities.length > MAX_CLIENT_CAPABILITIES
      || payload.capabilities.some((cap) => cap.length > MAX_CLIENT_CAPABILITY_CHARS)
    )) return;
    const overlay = await this.ensureOverlay(payload.endpointId);
    const updated: DeviceOverlay = {
      ...overlay,
      status: "active",
      lastConfirmedAt: rfc3339FromMs(this.deps.now()),
      ...(payload.appVersion != null ? { appVersion: payload.appVersion } : {}),
      ...(payload.releaseTrack != null ? { releaseTrack: payload.releaseTrack } : {}),
      ...(payload.capabilities != null ? { capabilities: [...payload.capabilities] } : {}),
      ...(payload.deviceId != null ? { deviceId: payload.deviceId } : {}),
      ...(attachment.namespace !== undefined ? { clientNamespace: attachment.namespace } : {}),
    };
    await this.deps.storage.put(DEV_PREFIX + payload.endpointId, updated);
    await this.bumpOverlayRevisionAndBroadcast(attachment.sessionId);
  }

  /** Mint passes if requested, then close the snapshot. */
  private async finishSnapshot(
    socket: CtlSocket,
    attachment: CtlAttachment,
    rev: number,
  ): Promise<void> {
    if (attachment.wantPasses && attachment.endpointId) {
      await this.mintAndSend(socket, attachment, attachment.endpointId, rev);
    }
    this.sendFrame(socket, attachment, snapshotCompleteFrame(rev, rfc3339FromMs(this.deps.now())));
    if (attachment.snapshotPending) {
      attachment.snapshotPending = false;
      socket.setAttachment(attachment);
    }
  }

  // ---- Directory delivery + ack tracking ----

  /** Send one socket the merged, freshness-stamped directory and arm its ack
   * retry ladder for that revision. */
  private async sendDirectory(
    socket: CtlSocket,
    attachment: CtlAttachment,
    rev: number,
    broker: BrokerDirectoryPayload,
  ): Promise<void> {
    const merged = await this.mergedDirectory(broker);
    this.sendFrame(socket, attachment, directoryFrame(rev, merged, rfc3339FromMs(this.deps.now())));
    await this.markAckPending(socket, attachment, rev);
  }

  /** Arm (or re-arm at the newest revision) the socket's ack retry ladder and
   * pull the alarm to the first rung. No-op when the socket already acked this
   * revision or newer. */
  private async markAckPending(
    socket: CtlSocket,
    attachment: CtlAttachment,
    rev: number,
  ): Promise<void> {
    if ((attachment.lastAckedRev ?? -1) >= rev) return;
    const now = this.deps.now();
    const nextAt = now + (ACK_RETRY_LADDER_MS[0] ?? ACK_RETRY_STEADY_MS);
    attachment.ackRetry = { rev, attempt: 0, nextAt };
    socket.setAttachment(attachment);
    await this.deps.scheduleAlarmAt(nextAt);
  }

  // ---- ack: the client applied revision `rev`; stand the ladder down ----

  private async handleAck(
    socket: CtlSocket,
    attachment: CtlAttachment,
    frame: CTLACK,
  ): Promise<void> {
    const rev = frame.rev;
    // Stale acks are fine; ignore anything at or below the current watermark.
    if ((attachment.lastAckedRev ?? -1) >= rev) return;
    attachment.lastAckedRev = rev;
    if (attachment.ackRetry !== undefined && rev >= attachment.ackRetry.rev) {
      delete attachment.ackRetry;
    }
    socket.setAttachment(attachment);
    // Mirror into the device overlay when the socket is bound to a known
    // device (bookkeeping only: no revision bump, never emitted).
    if (attachment.endpointId) {
      const overlay = await this.deps.storage.get<DeviceOverlay>(DEV_PREFIX + attachment.endpointId);
      if (overlay !== undefined && (overlay.lastAckedRev ?? -1) < rev) {
        await this.deps.storage.put(DEV_PREFIX + attachment.endpointId, {
          ...overlay,
          lastAckedRev: rev,
        });
      }
    }
  }

  // ---- mint_request: proxy the exact client mint with the socket's own token ----

  private async handleMintRequest(
    socket: CtlSocket,
    attachment: CtlAttachment,
    frame: CTLMintRequest,
  ): Promise<void> {
    const endpointId = frame.payload.endpointId;
    if (!endpointId || endpointId.length > MAX_ENDPOINT_ID_CHARS) return;
    const rev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
    await this.mintAndSend(socket, attachment, endpointId, rev);
  }

  /** Replicate the Swift client's own mint (POST api/relay/token with bearer
   * auth and body {"endpointId"}; see CmxIrohTrustBrokerClient
   * issueRelayBootstrap) using THIS socket's stored token, with one immediate
   * retry on connection-level failure. Phase A ignores any proof on the
   * message: the broker authorizes the endpoint from its registration state.
   * The reply goes to this socket only. */
  private async mintAndSend(
    socket: CtlSocket,
    attachment: CtlAttachment,
    endpointId: string,
    rev: number,
  ): Promise<void> {
    // A revoked device keeps its socket and may see the directory, but never
    // fresh relay credentials. Non-retryable: only an un-revoke (or asking for
    // a non-revoked endpoint) changes the answer. Checked for both the minted
    // endpoint and the requesting socket's own bound endpoint.
    if (await this.isEndpointRevoked(endpointId)
      || (attachment.endpointId !== undefined
        && attachment.endpointId !== endpointId
        && await this.isEndpointRevoked(attachment.endpointId))) {
      this.sendFrame(socket, attachment, errorFrame(
        "mint_revoked",
        "device revoked for this account",
        false,
      ));
      return;
    }
    const credentials = decodeStoredCredentials(
      await this.deps.storage.get<string>(BEARER_PREFIX + attachment.sessionId),
    );
    if (credentials === undefined) {
      this.sendFrame(socket, attachment, errorFrame(
        "mint_unauthorized",
        "no bearer token for this connection; reconnect",
        false,
      ));
      return;
    }
    const result = await this.upstreamOnceRetry(MINT_PATH, {
      method: "POST",
      headers: upstreamHeaders(credentials, attachment.namespace, true),
      body: JSON.stringify({ endpointId }),
    });
    if (result === null) {
      this.sendFrame(socket, attachment, errorFrame(
        "mint_upstream_unavailable",
        "relay token mint failed upstream",
        true,
      ));
      return;
    }
    if (result.status < 200 || result.status >= 300) {
      const retryable = result.status >= 500 || result.status === 429;
      this.sendFrame(socket, attachment, errorFrame(
        retryable ? "mint_upstream_unavailable" : "mint_rejected",
        `relay token mint failed upstream (${result.status})`,
        retryable,
      ));
      return;
    }
    const generation = ((await this.deps.storage.get<number>(GEN_PREFIX + endpointId)) ?? 0) + 1;
    const passes = passesFromMintResponse(result.json, generation);
    if (passes === null) {
      this.sendFrame(socket, attachment, errorFrame(
        "mint_no_credentials",
        "upstream issued no relay credentials for this endpoint",
        false,
      ));
      return;
    }
    await this.deps.storage.put(GEN_PREFIX + endpointId, generation);
    this.sendFrame(socket, attachment, relayPassesFrame(rev, endpointId, passes));
  }

  // ---- publish_hint: instant-propagation announcement + confirm re-fetch ----

  /** Phase A never writes hints to Vercel (upstream hint registration is a
   * challenge + endpoint-signed flow only the Mac itself can perform; the Mac
   * keeps doing that over HTTPS in parallel). The socket path is the
   * instant-propagation lane: broadcast the claim to the account's OTHER
   * sockets at the current known rev, then confirm against broker truth a few
   * seconds later and re-broadcast if the authoritative revision moved. Spoof
   * scope is bounded to same-account devices, and a wrong announcement costs
   * peers one failed dial before the confirm pass corrects it. */
  private async handlePublishHint(
    socket: CtlSocket,
    attachment: CtlAttachment,
    frame: CTLPublishHint,
  ): Promise<void> {
    const { endpointId, homeRelayUrl } = frame.payload;
    if (!endpointId || endpointId.length > MAX_ENDPOINT_ID_CHARS) return;
    if (!isPlausibleRelayUrl(homeRelayUrl)) {
      this.sendFrame(socket, attachment, errorFrame(
        "invalid_hint",
        "homeRelayUrl must be an http(s) URL",
        false,
      ));
      return;
    }
    const now = this.deps.now();
    const rev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
    const frameJson = JSON.stringify(
      hintUpdateFrame(rev, endpointId, homeRelayUrl, rfc3339FromMs(now)),
    );
    // The announcement is NOT revision-bearing (rev did not move), so it never
    // arms the peers' ack retry ladders; the confirm re-fetch does when the
    // broker revision actually advances.
    for (const peer of this.deps.sockets()) {
      const peerAttachment = peer.getAttachment();
      if (!peerAttachment) continue;
      if (peerAttachment.sessionId === attachment.sessionId) continue; // announcer knows its own hint
      if (!this.deliverable(peerAttachment, now)) continue;
      try {
        peer.send(frameJson);
      } catch {
        // Socket already gone; hibernation cleans it up.
      }
    }
    await this.deps.scheduleAlarmAt(now + HINT_CONFIRM_DELAY_MS);
  }

  // ---- Device overlay (listv2): storage-driven, joined at directory build ----

  /** Load a device's overlay, materializing the seeded default on first
   * sighting so admin mutations (revoke) always have a record to land on. */
  private async ensureOverlay(endpointId: string): Promise<DeviceOverlay> {
    const existing = await this.deps.storage.get<DeviceOverlay>(DEV_PREFIX + endpointId);
    if (existing !== undefined) return existing;
    const seeded: DeviceOverlay = { status: "seeded", revoked: false };
    await this.deps.storage.put(DEV_PREFIX + endpointId, seeded);
    return seeded;
  }

  private async isEndpointRevoked(endpointId: string): Promise<boolean> {
    const overlay = await this.deps.storage.get<DeviceOverlay>(DEV_PREFIX + endpointId);
    return overlay?.revoked === true;
  }

  /** Join broker bindings with the DO-owned overlay. Bindings never seen
   * before get a seeded overlay row created; overlay rows whose binding
   * disappeared upstream are kept in storage but not emitted. lastAckedRev is
   * bookkeeping and never emitted. */
  private async mergedDirectory(broker: BrokerDirectoryPayload): Promise<WireDirectoryBody> {
    const bindings: Binding[] = [];
    const emitted = new Set<string>();
    for (const binding of broker.bindings) {
      const overlay = await this.ensureOverlay(binding.endpointId);
      emitted.add(binding.endpointId);
      bindings.push({
        ...binding,
        status: overlay.status,
        revoked: overlay.revoked,
        ...(overlay.appVersion !== undefined ? { appVersion: overlay.appVersion } : {}),
        ...(overlay.releaseTrack !== undefined ? { releaseTrack: overlay.releaseTrack } : {}),
        ...(overlay.capabilities !== undefined ? { capabilities: overlay.capabilities } : {}),
        ...(overlay.lastConfirmedAt !== undefined
          ? { lastConfirmedAt: wireDate(overlay.lastConfirmedAt) }
          : {}),
      });
    }
    // Confirmed-but-unlisted devices: a device that proved itself over its
    // own authenticated hello stays in the emitted directory even when the
    // upstream discovery view omits it (namespace-filtered upstream views,
    // registration lag, caller self-exclusion). Without this, the device's
    // peers fail closed against it — the exact wedge the confirm-on-hello
    // contract exists to prevent. Bounded by the directory TTL so an
    // upstream deletion cannot outlive the trust lease; revoked rides along
    // so peers still see the kill switch.
    const overlays = await this.deps.storage.list<DeviceOverlay>({ prefix: DEV_PREFIX });
    const cutoffMs = this.deps.now() - DIRECTORY_TTL_SECONDS * 1000;
    for (const [key, overlay] of overlays) {
      const endpointId = key.slice(DEV_PREFIX.length);
      if (emitted.has(endpointId)) continue;
      if (overlay.status !== "active") continue;
      const confirmedAtMs = overlay.lastConfirmedAt === undefined
        ? Number.NaN
        : Date.parse(overlay.lastConfirmedAt);
      if (!(confirmedAtMs > cutoffMs)) continue;
      bindings.push({
        bindingId: `ctl-hello:${endpointId}`,
        clientNamespace: overlay.clientNamespace ?? "legacy",
        endpointId,
        status: overlay.status,
        revoked: overlay.revoked,
        ...(overlay.deviceId !== undefined ? { deviceId: overlay.deviceId } : {}),
        ...(overlay.appVersion !== undefined ? { appVersion: overlay.appVersion } : {}),
        ...(overlay.releaseTrack !== undefined ? { releaseTrack: overlay.releaseTrack } : {}),
        ...(overlay.capabilities !== undefined ? { capabilities: overlay.capabilities } : {}),
        ...(overlay.lastConfirmedAt !== undefined
          ? { lastConfirmedAt: wireDate(overlay.lastConfirmedAt) }
          : {}),
      });
    }
    return { ...broker, bindings };
  }

  /** Bump the account revision for a DO-local overlay change (confirm-on-hello
   * or revocation — broker truth did not move, so storeDirectory could never
   * see it) and broadcast the merged directory to every snapshotted socket,
   * except the optionally excluded one whose snapshot arrives inline. */
  private async bumpOverlayRevisionAndBroadcast(excludeSessionId: string | null): Promise<number> {
    const previousRev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
    const rev = previousRev + 1;
    await this.deps.storage.put(REV_KEY, rev);
    const broker = await this.deps.storage.get<BrokerDirectoryPayload>(DIR_KEY);
    if (broker === undefined) return rev; // no directory yet; nothing to broadcast
    const merged = await this.mergedDirectory(broker);
    const frameJson = JSON.stringify(directoryFrame(rev, merged, rfc3339FromMs(this.deps.now())));
    const now = this.deps.now();
    for (const socket of this.deps.sockets()) {
      const peer = socket.getAttachment();
      if (!peer) continue;
      if (excludeSessionId !== null && peer.sessionId === excludeSessionId) continue;
      if (!this.deliverable(peer, now)) continue;
      try {
        socket.send(frameJson);
      } catch {
        continue; // Socket already gone; hibernation cleans it up.
      }
      await this.markAckPending(socket, peer, rev);
    }
    return rev;
  }

  // ---- Revocation: account-owner kill switch over the worker HTTP route ----

  /** Flip one device's revoked flag (status untouched — revoked is
   * orthogonal). Idempotent. On revoke: bump the revision, broadcast the
   * merged directory immediately (the revoked device may still see the list),
   * then close every socket bound to that endpoint with 1008 "revoked". Mints
   * for the endpoint are refused until un-revoked. */
  async handleRevocation(
    request: RevocationRequest,
  ): Promise<{ rev: number; changed: boolean; revoked: boolean }> {
    const overlay = await this.ensureOverlay(request.endpointId);
    if (overlay.revoked === request.revoked) {
      const rev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
      return { rev, changed: false, revoked: overlay.revoked };
    }
    await this.deps.storage.put(DEV_PREFIX + request.endpointId, {
      ...overlay,
      revoked: request.revoked,
    });
    const rev = await this.bumpOverlayRevisionAndBroadcast(null);
    if (request.revoked) {
      for (const socket of this.deps.sockets()) {
        const attachment = socket.getAttachment();
        if (!attachment || attachment.endpointId !== request.endpointId) continue;
        await this.deps.storage.delete(BEARER_PREFIX + attachment.sessionId);
        try {
          socket.close(1008, "revoked");
        } catch {
          // already closed
        }
      }
    }
    return { rev, changed: true, revoked: request.revoked };
  }

  // ---- Alarm: periodic refresh + pending-snapshot recovery ----

  async handleAlarm(): Promise<void> {
    const now = this.deps.now();
    const live: CtlSocket[] = [];
    for (const socket of this.deps.sockets()) {
      const attachment = socket.getAttachment();
      if (!attachment) continue;
      if (attachment.expiresAt !== undefined && attachment.expiresAt <= now) {
        await this.deps.storage.delete(BEARER_PREFIX + attachment.sessionId);
        try {
          socket.close(1000, "subscription expired; reconnect with a fresh token");
        } catch {
          // already closed
        }
        continue;
      }
      live.push(socket);
    }
    if (live.length === 0) return; // idle account: stop the refresh cadence
    await this.refreshDirectory(live);
    await this.retryUnackedDirectories(live);
    this.sendHeartbeat(live);
    let earliestExpiry = Number.POSITIVE_INFINITY;
    let earliestAckRetry = Number.POSITIVE_INFINITY;
    for (const socket of live) {
      const attachment = socket.getAttachment();
      if (!attachment) continue;
      if (attachment.expiresAt !== undefined && attachment.expiresAt < earliestExpiry) {
        earliestExpiry = attachment.expiresAt;
      }
      if (attachment.ackRetry !== undefined && attachment.ackRetry.nextAt < earliestAckRetry) {
        earliestAckRetry = attachment.ackRetry.nextAt;
      }
    }
    await this.deps.scheduleAlarmAt(
      Math.min(this.deps.now() + CONTROL_REFRESH_INTERVAL_MS, earliestExpiry),
    );
    // Pull the alarm to the earliest due ack rung (ensure-at keeps the min).
    if (earliestAckRetry !== Number.POSITIVE_INFINITY) {
      await this.deps.scheduleAlarmAt(earliestAckRetry);
    }
  }

  /** Send one lightweight application heartbeat to every live, handshaken
   * socket. Production control sockets have no subscription deadline. */
  private sendHeartbeat(live: CtlSocket[]): void {
    const frame = JSON.stringify({
      v: CONTROL_PROTOCOL_VERSION,
      type: CONTROL_HEARTBEAT_TYPE,
      payload: { at: new Date(this.deps.now()).toISOString() },
    });
    for (const socket of live) {
      const attachment = socket.getAttachment();
      if (!attachment || !attachment.helloed
        || (attachment.expiresAt !== undefined && attachment.expiresAt <= this.deps.now())) {
        continue;
      }
      try {
        socket.send(frame);
      } catch {
        // Runtime close callbacks own stale socket cleanup.
      }
    }
  }

  /** Resend the LATEST merged directory to every live socket whose retry rung
   * is due and which still has not acked the head revision. Ladder offsets:
   * 5s, 30s, 2m, 10m after delivery, then hourly; the ladder resets on ack. */
  private async retryUnackedDirectories(live: CtlSocket[]): Promise<void> {
    const now = this.deps.now();
    const rev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
    const broker = await this.deps.storage.get<BrokerDirectoryPayload>(DIR_KEY);
    let frameJson: string | null = null;
    for (const socket of live) {
      const attachment = socket.getAttachment();
      if (!attachment || attachment.ackRetry === undefined) continue;
      if (attachment.ackRetry.nextAt > now) continue;
      if ((attachment.lastAckedRev ?? -1) >= rev) {
        // Already acked through head; stand down.
        delete attachment.ackRetry;
        socket.setAttachment(attachment);
        continue;
      }
      if (broker !== undefined
        && (attachment.expiresAt === undefined || attachment.expiresAt > now)) {
        if (frameJson === null) {
          frameJson = JSON.stringify(
            directoryFrame(rev, await this.mergedDirectory(broker), rfc3339FromMs(now)),
          );
        }
        try {
          socket.send(frameJson);
        } catch {
          // Socket already gone; hibernation cleans it up.
        }
      }
      const attempt = attachment.ackRetry.attempt + 1;
      const delay = ACK_RETRY_LADDER_MS[attempt] ?? ACK_RETRY_STEADY_MS;
      // The resend carried the head revision, so the ladder now tracks it.
      attachment.ackRetry = { rev, attempt, nextAt: now + delay };
      socket.setAttachment(attachment);
    }
  }

  /** Re-fetch discovery with a live socket's token and broadcast what changed.
   * Directory facts are account-scoped, so any live socket's token yields the
   * same account view. When legacy adapters provide deadlines, the socket with
   * the latest one is preferred because it was verified most recently. Control
   * sockets omit that field. Endpoint-bound mints never borrow across sockets. */
  private async refreshDirectory(live: CtlSocket[]): Promise<void> {
    const holder = await this.freshestBearerHolder(live);
    if (holder === null) return;
    const fetched = await this.fetchDirectory(holder);
    if (fetched === null) return; // upstream down; keep serving cached facts
    const { rev, previous, previousRev } = await this.storeDirectory(fetched);
    await this.broadcastDirectoryChange(previous, fetched.payload, rev, previousRev, null);
    // Recover sockets whose initial snapshot fetch failed.
    const now = this.deps.now();
    for (const socket of live) {
      const attachment = socket.getAttachment();
      if (!attachment || !attachment.snapshotPending) continue;
      if (attachment.expiresAt !== undefined && attachment.expiresAt <= now) continue;
      await this.sendDirectory(socket, attachment, rev, fetched.payload);
      await this.finishSnapshot(socket, attachment, rev);
    }
  }

  // ---- Shared internals ----

  private async freshestBearerHolder(live: CtlSocket[]): Promise<CtlAttachment | null> {
    const attachments = live
      .map((socket) => socket.getAttachment())
      .filter((attachment): attachment is CtlAttachment => attachment !== null)
      .sort((left, right) => (right.expiresAt ?? Number.POSITIVE_INFINITY)
        - (left.expiresAt ?? Number.POSITIVE_INFINITY));
    return attachments[0] ?? null;
  }

  /** GET the discovery endpoint with the given connection's token, one
   * immediate retry on connection-level failure. Null on any failure. */
  private async fetchDirectory(
    attachment: CtlAttachment,
  ): Promise<{ revision: number | null; payload: BrokerDirectoryPayload } | null> {
    const credentials = decodeStoredCredentials(
      await this.deps.storage.get<string>(BEARER_PREFIX + attachment.sessionId),
    );
    if (credentials === undefined) return null;
    const result = await this.upstreamOnceRetry(DISCOVERY_PATH, {
      method: "GET",
      // The control-plane socket is authenticated with the account's Stack
      // bearer, but it does not hold the endpoint private key needed to sign
      // a binding-request proof.  Discovery is intentionally account-scoped
      // here, so use the legacy namespace compatibility mode.  The returned
      // directory is still protected by the socket's account bearer and the
      // DO's per-account routing, while the app's own namespace remains on
      // mutation/relay requests.
      headers: upstreamHeaders(credentials, "legacy", false),
    });
    if (result === null || result.status < 200 || result.status >= 300) return null;
    return directoryPayloadFromDiscovery(result.json);
  }

  private async storeDirectory(
    fetched: { revision: number | null; payload: BrokerDirectoryPayload },
  ): Promise<{ rev: number; previous: BrokerDirectoryPayload | undefined; previousRev: number }> {
    const previous = await this.deps.storage.get<BrokerDirectoryPayload>(DIR_KEY);
    const previousRev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
    // Upstream revision when it is ahead, otherwise a local bump — and never
    // backwards: DO-local overlay changes (confirm-on-hello, revocation)
    // advance the account revision past anything the broker has issued yet.
    const contentChanged = previous === undefined
      || JSON.stringify(previous) !== JSON.stringify(fetched.payload);
    const rev = contentChanged
      ? Math.max(fetched.revision ?? 0, previousRev + 1)
      : previousRev;
    if (contentChanged) await this.deps.storage.put(DIR_KEY, fetched.payload);
    if (rev !== previousRev) await this.deps.storage.put(REV_KEY, rev);
    return { rev, previous, previousRev };
  }

  /** Broadcast a refreshed directory to every snapshotted socket except
   * `excludeSessionId` (the one that just received the full body inline).
   * Full-directory frames carry the overlay join and a fresh stamp; both
   * frame kinds are revision-bearing and arm the recipients' ack ladders. */
  private async broadcastDirectoryChange(
    previous: BrokerDirectoryPayload | undefined,
    next: BrokerDirectoryPayload,
    rev: number,
    previousRev: number,
    excludeSessionId: string | null,
  ): Promise<void> {
    if (rev === previousRev) return;
    const delta = directoryDelta(previous, next);
    if (delta.kind === "none") return;
    const now = this.deps.now();
    const frames = delta.kind === "full"
      ? [JSON.stringify(directoryFrame(rev, await this.mergedDirectory(next), rfc3339FromMs(now)))]
      : delta.updates.map((update) => JSON.stringify(
        hintUpdateFrame(rev, update.endpointId, update.homeRelayUrl, update.updatedAt),
      ));
    for (const socket of this.deps.sockets()) {
      const attachment = socket.getAttachment();
      if (!attachment) continue;
      if (excludeSessionId !== null && attachment.sessionId === excludeSessionId) continue;
      if (!this.deliverable(attachment, now)) continue;
      let delivered = false;
      for (const json of frames) {
        try {
          socket.send(json);
          delivered = true;
        } catch {
          // Socket already gone; hibernation cleans it up.
        }
      }
      if (delivered) await this.markAckPending(socket, attachment, rev);
    }
  }

  /** Deltas are deliverable only to sockets that finished their snapshot and
   * have not passed an adapter-provided lifecycle cutoff. */
  private deliverable(attachment: CtlAttachment, now: number): boolean {
    return (attachment.expiresAt === undefined || attachment.expiresAt > now)
      && attachment.helloed === true
      && attachment.snapshotPending !== true;
  }

  private sendFrame(socket: CtlSocket, attachment: CtlAttachment, frame: unknown): void {
    if (attachment.expiresAt !== undefined && attachment.expiresAt <= this.deps.now()) return;
    try {
      socket.send(JSON.stringify(frame));
    } catch {
      // Socket already gone; hibernation cleans it up.
    }
  }

  private async upstreamOnceRetry(
    path: string,
    init: CtlUpstreamInit,
  ): Promise<CtlUpstreamResult | null> {
    try {
      return await this.deps.upstream(path, init);
    } catch {
      // ONE immediate retry on connection-level failure only (an HTTP error
      // status resolves and is never retried here).
      try {
        return await this.deps.upstream(path, init);
      } catch {
        return null;
      }
    }
  }
}

function isPlausibleRelayUrl(value: string): boolean {
  if (!value || value.length > MAX_RELAY_URL_CHARS) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return url.protocol === "https:" || url.protocol === "http:";
}
