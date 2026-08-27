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
  CTLDirectory,
  CTLDirectoryPayload,
  CTLError,
  CTLHello,
  CTLHelloACK,
  CTLHintUpdate,
  CTLMintRequest,
  CTLPublishHint,
  CTLRelayPasses,
  CTLSnapshotComplete,
  FluffyProof,
  GrantVerificationKey,
  Pass,
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

/** A publish_hint is an ANNOUNCEMENT (phase A never writes hints to Vercel —
 * hint registration upstream is a challenge + Ed25519-signed registration flow
 * only the Mac itself can perform). The DO broadcasts the claim immediately,
 * then confirms against broker truth this soon after. */
export const HINT_CONFIRM_DELAY_MS = 3_000;

/** When the initial directory fetch fails and there is no cache to serve, the
 * socket stays snapshot-pending and the alarm retries this soon. */
export const SNAPSHOT_RETRY_DELAY_MS = 5_000;

const MAX_ENDPOINT_ID_CHARS = 128;
const MAX_RELAY_URL_CHARS = 512;

// ---- Storage keys (all under the account DO's own storage) ----

/** Last account route revision this DO observed (upstream `revision`, or the
 * local fallback counter when upstream omits it). */
export const REV_KEY = "ctl:rev";
/** Cached CTLDirectoryPayload from the last successful discovery fetch. Broker
 * truth only: publish_hint announcements are never folded in. */
export const DIR_KEY = "ctl:dir";
/** Per-endpoint relay-pass mint generation counter (`ctl:gen:<endpointId>`).
 * The broker response carries no generation; passes minted in one batch share
 * one monotonically increasing number so clients can order credential sets. */
export const GEN_PREFIX = "ctl:gen:";
/** Per-socket bearer token (`ctl:bearer:<sessionId>`), stored so upstream
 * calls survive DO hibernation. Strictly per-socket for endpoint-bound calls
 * (mint); deleted on close and on expiry sweep, and never usable past the
 * socket's own deadline (which the worker capped at token expiry). */
export const BEARER_PREFIX = "ctl:bearer:";

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
    ["bindingId", "endpointId", "clientNamespace"],
    ["deviceId", "instanceTag", "homeRelayUrl", "updatedAt"],
  )) return false;
  if (typeof value.bindingId !== "string") return false;
  if (typeof value.endpointId !== "string") return false;
  if (typeof value.clientNamespace !== "string") return false;
  for (const key of ["deviceId", "instanceTag", "homeRelayUrl", "updatedAt"] as const) {
    if (key in value && value[key] !== null && typeof value[key] !== "string") return false;
  }
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
  | { kind: "publish_hint"; frame: CTLPublishHint };

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
      if (!hasOnlyKeys(payload, ["endpointId", "wantPasses"], ["haveRev"])) return null;
      if (typeof payload.endpointId !== "string") return null;
      if (typeof payload.wantPasses !== "boolean") return null;
      if ("haveRev" in payload
        && payload.haveRev !== null
        && !(typeof payload.haveRev === "number" && Number.isSafeInteger(payload.haveRev))) {
        return null;
      }
      return { kind: "hello", frame: value as unknown as CTLHello };
    }
    case "hello_ack": {
      if (!validEnvelope(value, "hello_ack", false)) return null;
      if (!hasOnlyKeys(payload, ["sessionId"], ["resumedFromRev"])) return null;
      if (typeof payload.sessionId !== "string") return null;
      if ("resumedFromRev" in payload
        && payload.resumedFromRev !== null
        && !(typeof payload.resumedFromRev === "number" && Number.isSafeInteger(payload.resumedFromRev))) {
        return null;
      }
      return { kind: "hello_ack", frame: value as unknown as CTLHelloACK };
    }
    case "directory": {
      if (!validEnvelope(value, "directory", true)) return null;
      if (!hasOnlyKeys(payload, [
        "routeContractVersion",
        "bindings",
        "relayFleet",
        "grantVerificationKeys",
      ])) return null;
      if (!(typeof payload.routeContractVersion === "number"
        && Number.isSafeInteger(payload.routeContractVersion))) return null;
      if (!Array.isArray(payload.bindings) || !payload.bindings.every(validBinding)) return null;
      if (!Array.isArray(payload.relayFleet)
        || !payload.relayFleet.every((url) => typeof url === "string")) return null;
      if (!Array.isArray(payload.grantVerificationKeys)
        || !payload.grantVerificationKeys.every(validGrantKey)) return null;
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
      if (Object.keys(payload).length !== 0) return null;
      return { kind: "snapshot_complete", frame: value as unknown as CTLSnapshotComplete };
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

// ---- Server frame builders ----

export function helloAckFrame(sessionId: string, resumedFromRev: number | null): CTLHelloACK {
  return {
    v: CONTROL_PROTOCOL_VERSION,
    type: "hello_ack",
    payload: { sessionId, resumedFromRev },
  };
}

export function directoryFrame(rev: number, payload: CTLDirectoryPayload): CTLDirectory {
  return { v: CONTROL_PROTOCOL_VERSION, type: "directory", rev, payload };
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

export function snapshotCompleteFrame(rev: number): CTLSnapshotComplete {
  return { v: CONTROL_PROTOCOL_VERSION, type: "snapshot_complete", rev, payload: {} };
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
): { revision: number | null; payload: CTLDirectoryPayload } | null {
  if (!isObject(value)) return null;
  if (!Array.isArray(value.bindings)) return null;

  const bindings: Binding[] = [];
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

  return {
    revision,
    payload: { routeContractVersion, bindings, relayFleet, grantVerificationKeys },
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
  previous: CTLDirectoryPayload | undefined,
  next: CTLDirectoryPayload,
): DirectoryDelta {
  if (previous === undefined) return { kind: "full" };
  if (JSON.stringify(previous) === JSON.stringify(next)) return { kind: "none" };
  if (previous.routeContractVersion !== next.routeContractVersion) return { kind: "full" };
  if (JSON.stringify(previous.relayFleet) !== JSON.stringify(next.relayFleet)) return { kind: "full" };
  if (JSON.stringify(previous.grantVerificationKeys) !== JSON.stringify(next.grantVerificationKeys)) {
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
  /** Stream deadline: token expiry capped at MAX_SUBSCRIBE_AGE_MS, computed by
   * the worker from the VERIFIED token, never client input. */
  expiresAt: number;
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
  expiresAt: number;
  bearer: string;
  namespace?: string;
}

const DISCOVERY_PATH = "/api/devices/iroh";
const MINT_PATH = "/api/relay/token";

function upstreamHeaders(bearer: string, namespace: string | undefined, json: boolean): Record<string, string> {
  return {
    authorization: `Bearer ${bearer}`,
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
      expiresAt: input.expiresAt,
      ...(input.namespace ? { namespace: input.namespace } : {}),
    });
    await this.deps.storage.put(BEARER_PREFIX + input.sessionId, input.bearer);
    const now = this.deps.now();
    await this.deps.scheduleAlarmAt(
      Math.min(now + CONTROL_REFRESH_INTERVAL_MS, input.expiresAt),
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
    if (attachment.expiresAt <= now) {
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

    const storedRev = await this.deps.storage.get<number>(REV_KEY);
    const cached = await this.deps.storage.get<CTLDirectoryPayload>(DIR_KEY);
    const haveRev = payload.haveRev ?? null;
    const resumed = haveRev !== null && storedRev !== undefined
      && haveRev === storedRev && cached !== undefined;

    this.sendFrame(socket, attachment, helloAckFrame(attachment.sessionId, resumed ? haveRev : null));

    if (resumed) {
      // Client already holds the current snapshot; skip the directory body.
      // The 60s alarm refresh heals any staleness the DO itself has.
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
        this.sendFrame(socket, attachment, directoryFrame(storedRev, cached));
        await this.finishSnapshot(socket, attachment, storedRev);
      } else {
        attachment.snapshotPending = true;
        socket.setAttachment(attachment);
        await this.deps.scheduleAlarmAt(this.deps.now() + SNAPSHOT_RETRY_DELAY_MS);
      }
      return;
    }

    const { rev, previous, previousRev } = await this.storeDirectory(fetched);
    this.sendFrame(socket, attachment, directoryFrame(rev, fetched.payload));
    // This fetch doubles as a refresh for everyone else already snapshotted.
    this.broadcastDirectoryChange(previous, fetched.payload, rev, previousRev, attachment.sessionId);
    await this.finishSnapshot(socket, attachment, rev);
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
    this.sendFrame(socket, attachment, snapshotCompleteFrame(rev));
    if (attachment.snapshotPending) {
      attachment.snapshotPending = false;
      socket.setAttachment(attachment);
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
    const bearer = await this.deps.storage.get<string>(BEARER_PREFIX + attachment.sessionId);
    if (bearer === undefined) {
      this.sendFrame(socket, attachment, errorFrame(
        "mint_unauthorized",
        "no bearer token for this connection; reconnect",
        false,
      ));
      return;
    }
    const result = await this.upstreamOnceRetry(MINT_PATH, {
      method: "POST",
      headers: upstreamHeaders(bearer, attachment.namespace, true),
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

  // ---- Alarm: expiry sweep + periodic refresh + pending-snapshot recovery ----

  async handleAlarm(): Promise<void> {
    const now = this.deps.now();
    const live: CtlSocket[] = [];
    for (const socket of this.deps.sockets()) {
      const attachment = socket.getAttachment();
      if (!attachment) continue;
      if (attachment.expiresAt <= now) {
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
    let earliestExpiry = Number.POSITIVE_INFINITY;
    for (const socket of live) {
      const attachment = socket.getAttachment();
      if (attachment && attachment.expiresAt < earliestExpiry) earliestExpiry = attachment.expiresAt;
    }
    await this.deps.scheduleAlarmAt(
      Math.min(this.deps.now() + CONTROL_REFRESH_INTERVAL_MS, earliestExpiry),
    );
  }

  /** Re-fetch discovery with a live socket's token and broadcast what changed.
   * Directory facts are account-scoped, so any live socket's token yields the
   * same account view; the freshest-expiring one is picked because its token
   * verified most recently. Endpoint-bound mints never borrow across sockets. */
  private async refreshDirectory(live: CtlSocket[]): Promise<void> {
    const holder = await this.freshestBearerHolder(live);
    if (holder === null) return;
    const fetched = await this.fetchDirectory(holder);
    if (fetched === null) return; // upstream down; keep serving cached facts
    const { rev, previous, previousRev } = await this.storeDirectory(fetched);
    this.broadcastDirectoryChange(previous, fetched.payload, rev, previousRev, null);
    // Recover sockets whose initial snapshot fetch failed.
    const now = this.deps.now();
    for (const socket of live) {
      const attachment = socket.getAttachment();
      if (!attachment || !attachment.snapshotPending) continue;
      if (attachment.expiresAt <= now) continue;
      this.sendFrame(socket, attachment, directoryFrame(rev, fetched.payload));
      await this.finishSnapshot(socket, attachment, rev);
    }
  }

  // ---- Shared internals ----

  private async freshestBearerHolder(live: CtlSocket[]): Promise<CtlAttachment | null> {
    const attachments = live
      .map((socket) => socket.getAttachment())
      .filter((attachment): attachment is CtlAttachment => attachment !== null)
      .sort((left, right) => right.expiresAt - left.expiresAt);
    return attachments[0] ?? null;
  }

  /** GET the discovery endpoint with the given connection's token, one
   * immediate retry on connection-level failure. Null on any failure. */
  private async fetchDirectory(
    attachment: CtlAttachment,
  ): Promise<{ revision: number | null; payload: CTLDirectoryPayload } | null> {
    const bearer = await this.deps.storage.get<string>(BEARER_PREFIX + attachment.sessionId);
    if (bearer === undefined) return null;
    const result = await this.upstreamOnceRetry(DISCOVERY_PATH, {
      method: "GET",
      headers: upstreamHeaders(bearer, attachment.namespace, false),
    });
    if (result === null || result.status < 200 || result.status >= 300) return null;
    return directoryPayloadFromDiscovery(result.json);
  }

  private async storeDirectory(
    fetched: { revision: number | null; payload: CTLDirectoryPayload },
  ): Promise<{ rev: number; previous: CTLDirectoryPayload | undefined; previousRev: number }> {
    const previous = await this.deps.storage.get<CTLDirectoryPayload>(DIR_KEY);
    const previousRev = (await this.deps.storage.get<number>(REV_KEY)) ?? 0;
    // Upstream revision when present; otherwise a storage counter that bumps
    // only when the directory content actually changed.
    const contentChanged = previous === undefined
      || JSON.stringify(previous) !== JSON.stringify(fetched.payload);
    const rev = fetched.revision ?? (contentChanged ? previousRev + 1 : previousRev);
    if (contentChanged) await this.deps.storage.put(DIR_KEY, fetched.payload);
    if (rev !== previousRev) await this.deps.storage.put(REV_KEY, rev);
    return { rev, previous, previousRev };
  }

  /** Broadcast a refreshed directory to every snapshotted socket except
   * `excludeSessionId` (the one that just received the full body inline). */
  private broadcastDirectoryChange(
    previous: CTLDirectoryPayload | undefined,
    next: CTLDirectoryPayload,
    rev: number,
    previousRev: number,
    excludeSessionId: string | null,
  ): void {
    if (rev === previousRev) return;
    const delta = directoryDelta(previous, next);
    if (delta.kind === "none") return;
    const now = this.deps.now();
    const frames = delta.kind === "full"
      ? [JSON.stringify(directoryFrame(rev, next))]
      : delta.updates.map((update) => JSON.stringify(
        hintUpdateFrame(rev, update.endpointId, update.homeRelayUrl, update.updatedAt),
      ));
    for (const socket of this.deps.sockets()) {
      const attachment = socket.getAttachment();
      if (!attachment) continue;
      if (excludeSessionId !== null && attachment.sessionId === excludeSessionId) continue;
      if (!this.deliverable(attachment, now)) continue;
      for (const json of frames) {
        try {
          socket.send(json);
        } catch {
          // Socket already gone; hibernation cleans it up.
        }
      }
    }
  }

  /** Deltas are deliverable only to sockets that finished their snapshot and
   * have not passed their deadline (deadline enforced at delivery too, like
   * the presence DO). */
  private deliverable(attachment: CtlAttachment, now: number): boolean {
    return attachment.expiresAt > now
      && attachment.helloed === true
      && attachment.snapshotPending !== true;
  }

  private sendFrame(socket: CtlSocket, attachment: CtlAttachment, frame: unknown): void {
    if (attachment.expiresAt <= this.deps.now()) return;
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
