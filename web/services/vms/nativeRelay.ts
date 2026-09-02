import { createHash, createHmac } from "node:crypto";
import type {
  NativeRelayAttachGrant,
  NativeRelayBootstrap,
  NativeRelayRoute,
} from "./drivers/types";

/** Maximum number of independent relay endpoints a client can try. */
export const NATIVE_RELAY_MAX_SHARDS = 4;
/** The client invitation format currently carries two relay bootstrap records. */
export const NATIVE_RELAY_MACHINE_SHARD_COUNT = 2;
/** Keep ticket rotation below the protocol's five-minute maximum lifetime. */
export const NATIVE_RELAY_TICKET_TTL_SECONDS = 240;
export const NATIVE_RELAY_TICKET_REFRESH_MARGIN_SECONDS = 90;
/** Persisted capability marker. It contains no secret and distinguishes new
 * native-relay machines from VMs created before the feature was enabled. */
export const NATIVE_RELAY_METADATA_KEY = "nativeRelay";

const SHARD_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const SCOPE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/;
const VM_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/_-]+={0,2}$/;

export type NativeRelayRuntimeEnv = Readonly<Record<string, string | undefined>>;

export type NativeRelayShard = {
  readonly id: string;
  readonly route: string;
  readonly issuer: string;
  readonly secret: Uint8Array;
};

export type NativeRelayConfig = {
  readonly shards: readonly NativeRelayShard[];
  readonly bootstrapSecret: Uint8Array;
  readonly ticketIssuerBaseUrl: string;
};

export type NativeRelayTicketPermission = "register" | "connect";

export class NativeRelayConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "NativeRelayConfigError";
  }
}

/** Return true only for a VM that was provisioned with the native relay. */
export function isNativeRelayProvisioned(
  metadata: Record<string, unknown> | null | undefined,
): boolean {
  return metadata?.[NATIVE_RELAY_METADATA_KEY] === true;
}

/** Add the non-secret capability marker to persisted provider metadata. */
export function markNativeRelayProvisioned(
  metadata: Record<string, unknown> | null | undefined,
): Record<string, unknown> {
  return {
    ...(metadata ?? {}),
    [NATIVE_RELAY_METADATA_KEY]: true,
  };
}

/**
 * Read the self-hosted relay configuration without importing Next's env module.
 * This keeps unit tests and preview builds credential-free while deployed
 * runtimes still fail closed when the feature is explicitly enabled.
 */
export function readNativeRelayConfig(
  runtimeEnv: NativeRelayRuntimeEnv = process.env,
): NativeRelayConfig | null {
  if (!isTruthyFlag(runtimeEnv.CMUX_NATIVE_RELAY_ENABLED)) return null;

  const rawShards = runtimeEnv.CMUX_NATIVE_RELAY_SHARDS_JSON?.trim();
  if (!rawShards) throw new NativeRelayConfigError("CMUX_NATIVE_RELAY_SHARDS_JSON is required when native relay is enabled");
  if (rawShards.length > 64 * 1024) throw new NativeRelayConfigError("native relay shard configuration is too large");

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawShards);
  } catch {
    throw new NativeRelayConfigError("CMUX_NATIVE_RELAY_SHARDS_JSON is not valid JSON");
  }
  if (!Array.isArray(parsed)) throw new NativeRelayConfigError("native relay shard configuration must be an array");
  if (parsed.length < NATIVE_RELAY_MACHINE_SHARD_COUNT || parsed.length > NATIVE_RELAY_MAX_SHARDS) {
    throw new NativeRelayConfigError(
      `native relay requires ${NATIVE_RELAY_MACHINE_SHARD_COUNT}-${NATIVE_RELAY_MAX_SHARDS} shards for redundancy`,
    );
  }

  const ids = new Set<string>();
  const routes = new Set<string>();
  const issuers = new Set<string>();
  const shards: NativeRelayShard[] = [];
  for (const [index, value] of parsed.entries()) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new NativeRelayConfigError(`native relay shard ${index} must be an object`);
    }
    const record = value as Record<string, unknown>;
    const id = requiredString(record.id, `native relay shard ${index} id`);
    if (!SHARD_ID_PATTERN.test(id) || !ids.add(id)) {
      throw new NativeRelayConfigError(`native relay shard ${index} id is invalid or repeated`);
    }
    const route = normalizeRelayRoute(requiredString(record.route, `native relay shard ${id} route`));
    if (!routes.add(route)) throw new NativeRelayConfigError(`native relay route is repeated for shard ${id}`);
    const issuer = requiredString(record.issuer, `native relay shard ${id} issuer`);
    if (!SCOPE_PATTERN.test(issuer) || !issuers.add(issuer)) {
      throw new NativeRelayConfigError(`native relay issuer for shard ${id} is invalid or repeated`);
    }
    const secretValue = record.secretB64 ?? record.secret_b64 ?? record.secret;
    const secret = decodeSecret(secretValue, `native relay shard ${id} secret`);
    shards.push({ id, route, issuer, secret });
  }

  const bootstrapSecret = decodeSecret(
    runtimeEnv.CMUX_NATIVE_RELAY_BOOTSTRAP_SECRET_B64,
    "CMUX_NATIVE_RELAY_BOOTSTRAP_SECRET_B64",
  );
  const ticketIssuerBaseUrl = normalizeTicketIssuerUrl(runtimeEnv.CMUX_NATIVE_RELAY_TICKET_ISSUER_URL);
  return Object.freeze({ shards: Object.freeze(shards), bootstrapSecret, ticketIssuerBaseUrl });
}

/** Stable slot identity. The Cloud VM row id, not a provider id, is the owner. */
export function nativeRelaySlot(vmId: string): string {
  const id = vmId.trim();
  if (!VM_ID_PATTERN.test(id)) throw new NativeRelayConfigError("Cloud VM id has an invalid shape for relay scope");
  return `vm-${id}`;
}

/**
 * Derive a machine-only bootstrap credential. A VM can use it only with its
 * own URL path, and the control plane never stores the derived value.
 */
export function deriveNativeRelayBootstrapToken(
  vmId: string,
  bootstrapSecret: Uint8Array,
): string {
  const slot = nativeRelaySlot(vmId);
  return createHmac("sha256", bootstrapSecret)
    .update(`cmux-native-relay-bootstrap-v1\n${slot}`)
    .digest("base64url");
}

/** Select two stable shards while spreading machines across the configured set. */
export function nativeRelayShardsForVm(
  vmId: string,
  config: NativeRelayConfig,
): readonly NativeRelayShard[] {
  if (config.shards.length < NATIVE_RELAY_MACHINE_SHARD_COUNT) {
    throw new NativeRelayConfigError("native relay has too few shards for redundancy");
  }
  const digest = createHash("sha256")
    .update(`cmux-native-relay-shard-v1\n${nativeRelaySlot(vmId)}`)
    .digest();
  const first = digest.readUInt32BE(0) % config.shards.length;
  const offset = 1 + (digest[4] % (config.shards.length - 1));
  const second = (first + offset) % config.shards.length;
  return [config.shards[first]!, config.shards[second]!];
}

/** Build the provider bootstrap values for its daemon supervisor. */
export function nativeRelayBootstrapForVm(
  vmId: string,
  config: NativeRelayConfig | null = readNativeRelayConfig(),
): NativeRelayBootstrap | undefined {
  if (!config) return undefined;
  const slot = nativeRelaySlot(vmId);
  const routes: NativeRelayRoute[] = nativeRelayShardsForVm(vmId, config).map((shard) => ({
    id: shard.id,
    route: shard.route,
    slot,
  }));
  const ticketUrl = `${config.ticketIssuerBaseUrl}/api/internal/vm/${encodeURIComponent(vmId)}/relay-ticket`;
  return {
    slot,
    ticketUrl,
    bootstrapToken: deriveNativeRelayBootstrapToken(vmId, config.bootstrapSecret),
    routes: Object.freeze(routes),
  };
}

/** Environment values for providers that support create-time env injection. */
export function nativeRelayProviderEnvironment(
  bootstrap: NativeRelayBootstrap | undefined,
): Record<string, string> {
  if (!bootstrap) return {};
  const env: Record<string, string> = {
    CMUX_NATIVE_RELAY_ENABLED: "1",
    CMUX_NATIVE_RELAY_SLOT: bootstrap.slot,
    CMUX_NATIVE_RELAY_TICKET_URL: bootstrap.ticketUrl,
    CMUX_NATIVE_RELAY_BOOTSTRAP_TOKEN: bootstrap.bootstrapToken,
  };
  bootstrap.routes.forEach((route, index) => {
    const number = index + 1;
    env[`CMUX_NATIVE_RELAY_${number}_ID`] = route.id;
    env[`CMUX_NATIVE_RELAY_${number}_URL`] = route.route;
    env[`CMUX_NATIVE_RELAY_${number}_SLOT`] = route.slot;
  });
  return env;
}

/** Mint a v2 ticket byte-for-byte compatible with cmux-relay's Rust verifier. */
export function mintNativeRelayTicket(input: {
  readonly shard: NativeRelayShard;
  readonly permission: NativeRelayTicketPermission;
  readonly slot: string;
  readonly nowSeconds?: number;
}): { readonly ticket: string; readonly issuedAtUnix: number; readonly expiresAtUnix: number } {
  const slot = input.slot.trim();
  if (!SCOPE_PATTERN.test(slot)) throw new NativeRelayConfigError("relay ticket slot has an invalid shape");
  const now = input.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (!Number.isSafeInteger(now) || now <= 0) throw new NativeRelayConfigError("relay ticket clock is invalid");
  const expiresAtUnix = now + NATIVE_RELAY_TICKET_TTL_SECONDS;
  const permission = input.permission;
  const role = permission === "register" ? "daemon" : "client";
  const claims = {
    version: 2,
    issuer: input.shard.issuer,
    permission,
    role,
    slot,
    circuit: null,
    lane: null,
    generation: null,
    issued_at_unix: now,
    expires_at_unix: expiresAtUnix,
  };
  const signingPayload = [
    "cmux-relay-ticket-v2",
    claims.version,
    claims.issuer,
    claims.permission,
    claims.role,
    claims.slot,
    "",
    "",
    "",
    claims.issued_at_unix,
    claims.expires_at_unix,
  ].join("\n");
  const encodedClaims = Buffer.from(JSON.stringify(claims), "utf8").toString("base64url");
  const signature = createHmac("sha256", input.shard.secret)
    .update(signingPayload, "utf8")
    .digest("base64url");
  return {
    ticket: `v2.${encodedClaims}.${signature}`,
    issuedAtUnix: now,
    expiresAtUnix,
  };
}

/** Mint the two Connect credentials returned to the signed-in client. */
export function nativeRelayAttachGrants(
  vmId: string,
  config: NativeRelayConfig | null = readNativeRelayConfig(),
  nowSeconds = Math.floor(Date.now() / 1000),
): readonly NativeRelayAttachGrant[] {
  if (!config) return [];
  const slot = nativeRelaySlot(vmId);
  return nativeRelayShardsForVm(vmId, config).map((shard) => {
    const minted = mintNativeRelayTicket({ shard, permission: "connect", slot, nowSeconds });
    return {
      shardId: shard.id,
      route: shard.route,
      slot,
      ticket: minted.ticket,
      expiresAtUnix: minted.expiresAtUnix,
      refreshAfterUnix: minted.expiresAtUnix - NATIVE_RELAY_TICKET_REFRESH_MARGIN_SECONDS,
    };
  });
}

/** Mint the daemon's Register credential only for one of its assigned shards. */
export function nativeRelayRegisterTicket(input: {
  readonly vmId: string;
  readonly shardId: string;
  readonly config: NativeRelayConfig;
  readonly nowSeconds?: number;
}): { readonly ticket: string; readonly expiresAtUnix: number } {
  const slot = nativeRelaySlot(input.vmId);
  const assigned = nativeRelayShardsForVm(input.vmId, input.config);
  const shard = assigned.find((candidate) => candidate.id === input.shardId);
  if (!shard) throw new NativeRelayConfigError("relay shard is not assigned to this VM");
  const minted = mintNativeRelayTicket({
    shard,
    permission: "register",
    slot,
    nowSeconds: input.nowSeconds,
  });
  return { ticket: minted.ticket, expiresAtUnix: minted.expiresAtUnix };
}

export function shardById(config: NativeRelayConfig, id: string): NativeRelayShard | undefined {
  return config.shards.find((shard) => shard.id === id);
}

export function isTruthyFlag(value: string | undefined): boolean {
  switch (value?.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
    case "enabled":
      return true;
    default:
      return false;
  }
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim() === "") throw new NativeRelayConfigError(`${field} is required`);
  return value.trim();
}

function decodeSecret(value: unknown, field: string): Uint8Array {
  const encoded = requiredString(value, field);
  if (encoded.length > 512 || !BASE64_PATTERN.test(encoded)) {
    throw new NativeRelayConfigError(`${field} must be base64 encoded`);
  }
  const padding = encoded.match(/=*$/)?.[0] ?? "";
  const body = encoded.slice(0, encoded.length - padding.length);
  // Base64 has no one-character remainder, and padding is only valid when it
  // brings the complete encoding to a four-byte boundary. Normalize both
  // alphabets before decoding so malformed or silently truncated secrets do
  // not become accepted configuration.
  if (body.length % 4 === 1 || padding.length > 2 || (padding.length > 0 && encoded.length % 4 !== 0)) {
    throw new NativeRelayConfigError(`${field} is not valid base64`);
  }
  const normalized = body.replace(/-/g, "+").replace(/_/g, "/") + padding;
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  let bytes: Buffer;
  try {
    bytes = Buffer.from(padded, "base64");
  } catch {
    throw new NativeRelayConfigError(`${field} is not valid base64`);
  }
  const canonical = bytes.toString("base64url");
  const suppliedCanonical = body.replace(/\+/g, "-").replace(/\//g, "_");
  if (canonical !== suppliedCanonical) {
    throw new NativeRelayConfigError(`${field} is not valid base64`);
  }
  if (bytes.length < 32) throw new NativeRelayConfigError(`${field} must contain at least 32 bytes`);
  return new Uint8Array(bytes);
}

function normalizeRelayRoute(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new NativeRelayConfigError("native relay route is not a valid URL");
  }
  if (url.protocol !== "relay+wss:" && url.protocol !== "relay+https:") {
    throw new NativeRelayConfigError("native relay routes must use relay+wss or relay+https");
  }
  if (!url.hostname || url.username || url.password || url.search || url.hash) {
    throw new NativeRelayConfigError("native relay route must not contain credentials, query, or fragment");
  }
  const path = url.pathname.replace(/\/+$/, "") || "/";
  if (path !== "/v1/relay") throw new NativeRelayConfigError("native relay route must end in /v1/relay");
  url.pathname = path;
  return url.toString();
}

function normalizeTicketIssuerUrl(value: string | undefined): string {
  const raw = requiredString(value, "CMUX_NATIVE_RELAY_TICKET_ISSUER_URL");
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new NativeRelayConfigError("CMUX_NATIVE_RELAY_TICKET_ISSUER_URL is not a valid URL");
  }
  // WHATWG URL keeps brackets on an IPv6 hostname (`[::1]`). Accept both
  // spellings because Node versions differ here, while still allowing only
  // loopback HTTP issuers.
  const hostname = url.hostname.toLowerCase();
  const local = hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) {
    throw new NativeRelayConfigError("native relay ticket issuer must use HTTPS");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new NativeRelayConfigError("native relay ticket issuer must not contain credentials, query, or fragment");
  }
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}
