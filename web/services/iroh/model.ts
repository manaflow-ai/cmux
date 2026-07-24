import { createHash } from "node:crypto";
import { isIP } from "node:net";
import { IrohInvalidInputError } from "./errors";
export { MANAGED_RELAY_URLS } from "./publicationPolicy";

export const IROH_ALPN = "cmux/mobile/1";
export const IROH_PAIR_SCOPE = "cmux.mobile.attach";
export const IROH_PAIR_GRANT_TYP = "cmux-pair-grant+jwt";
export const IROH_ENDPOINT_ATTESTATION_VERSION = 1;
export const IROH_ENDPOINT_ATTESTATION_TYP = "cmux-endpoint-attestation-v1+jwt";
export const IROH_ENDPOINT_ATTESTATION_SCOPE = "cmux.offline-pair.same-account";
export const IROH_CHALLENGE_LIFETIME_MS = 5 * 60 * 1_000;
export const IROH_PAIR_GRANT_LIFETIME_SECONDS = 7 * 24 * 60 * 60;
export const IROH_ENDPOINT_ATTESTATION_LIFETIME_SECONDS = 24 * 60 * 60;
export const IROH_OFFLINE_PAIR_SESSION_LIFETIME_SECONDS = 5 * 60;
export const IROH_OFFLINE_PAIR_SESSION_VERSION = 1;
export const IROH_RELAY_TOKEN_LIFETIME_SECONDS = 24 * 60 * 60;
export const IROH_RELAY_TOKEN_REFRESH_SECONDS = 12 * 60 * 60;
export const IROH_ROUTE_CONTRACT_VERSION = 1;
export const POSTGRES_INT32_MAX = 2_147_483_647;

export type IrohPathHint = {
  readonly kind: "direct_address" | "relay_url";
  readonly value: string;
  readonly source: "native" | "lan" | "tailscale" | "custom_vpn";
  readonly privacy_scope: "public_internet" | "local_network" | "private_network";
  readonly observed_at: string;
  readonly expires_at: string;
  readonly network_profile?: {
    readonly source: "lan" | "tailscale" | "custom_vpn";
    readonly profile_id: string;
  };
};

export type IrohDirectPorts = {
  readonly ipv4?: number;
  readonly ipv6?: number;
};

export type IrohRegistrationPayload = {
  readonly route_contract_version: typeof IROH_ROUTE_CONTRACT_VERSION;
  readonly deviceId: string;
  readonly appInstanceId: string;
  readonly tag: string;
  readonly platform: "mac" | "ios";
  readonly displayName?: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly pairingEnabled: boolean;
  readonly capabilities: readonly string[];
  readonly directPorts?: IrohDirectPorts;
  readonly pathHints: readonly IrohPathHint[];
};

export type IrohChallengeRequest = Pick<
  IrohRegistrationPayload,
  "deviceId" | "appInstanceId" | "tag" | "endpointId" | "identityGeneration"
> & {
  readonly payloadSha256: string;
};

export type IrohRegisterRequest = {
  readonly challengeId: string;
  readonly nonce: string;
  readonly payload: string;
  readonly signature: string;
};

export function parseChallengeRequest(value: unknown): IrohChallengeRequest {
  const body = record(value);
  const parsed: IrohChallengeRequest = {
    deviceId: uuid(body.deviceId, "invalid_device_id"),
    appInstanceId: uuid(body.appInstanceId, "invalid_app_instance_id"),
    tag: safeTag(body.tag),
    endpointId: endpointId(body.endpointId),
    identityGeneration: positiveInteger(body.identityGeneration, "invalid_identity_generation"),
    payloadSha256: sha256Hex(body.payloadSha256, "invalid_payload_hash"),
  };
  rejectUnknownKeys(body, [
    "deviceId",
    "appInstanceId",
    "tag",
    "endpointId",
    "identityGeneration",
    "payloadSha256",
  ]);
  return parsed;
}

export function parseRegisterRequest(value: unknown): IrohRegisterRequest {
  const body = record(value);
  const parsed = {
    challengeId: uuid(body.challengeId, "invalid_challenge_id"),
    nonce: base64url(body.nonce, 32, "invalid_nonce"),
    payload: boundedString(body.payload, 1, 48_000, "invalid_payload"),
    signature: base64url(body.signature, 64, "invalid_signature"),
  };
  rejectUnknownKeys(body, ["challengeId", "nonce", "payload", "signature"]);
  return parsed;
}

export function decodeRegistrationPayload(encoded: string, now: Date): {
  readonly bytes: Uint8Array;
  readonly sha256: string;
  readonly payload: IrohRegistrationPayload;
} {
  let bytes: Uint8Array;
  try {
    bytes = Buffer.from(encoded, "base64url");
  } catch {
    throw new IrohInvalidInputError({ code: "invalid_payload" });
  }
  if (bytes.byteLength === 0 || bytes.byteLength > 32_768) {
    throw new IrohInvalidInputError({ code: "invalid_payload" });
  }
  let raw: unknown;
  try {
    raw = JSON.parse(Buffer.from(bytes).toString("utf8"));
  } catch {
    throw new IrohInvalidInputError({ code: "invalid_payload" });
  }
  return {
    bytes,
    sha256: sha256(bytes),
    payload: parseRegistrationPayload(raw, now),
  };
}

export function parseRegistrationPayload(value: unknown, now: Date): IrohRegistrationPayload {
  const body = record(value);
  const capabilitiesRaw = Array.isArray(body.capabilities) ? body.capabilities : null;
  if (!capabilitiesRaw || capabilitiesRaw.length > 32) {
    throw new IrohInvalidInputError({ code: "invalid_capabilities" });
  }
  const capabilities = [...new Set(capabilitiesRaw.map((item) => {
    const capability = boundedString(item, 1, 64, "invalid_capabilities");
    if (!/^[A-Za-z0-9._:-]+$/.test(capability)) {
      throw new IrohInvalidInputError({ code: "invalid_capabilities" });
    }
    return capability;
  }))];
  const hintsRaw = Array.isArray(body.pathHints) ? body.pathHints : null;
  if (!hintsRaw || hintsRaw.length > 16) {
    throw new IrohInvalidInputError({ code: "invalid_path_hints" });
  }
  const pathHints = hintsRaw.map((hint) => parseIrohPathHint(hint, now));
  if (pathHints.filter((hint) => hint.kind === "relay_url").length > 2) {
    throw new IrohInvalidInputError({ code: "too_many_relay_hints" });
  }
  if (new Set(pathHints.map((hint) => JSON.stringify(hint))).size !== pathHints.length) {
    throw new IrohInvalidInputError({ code: "duplicate_path_hint" });
  }
  const payload: IrohRegistrationPayload = {
    route_contract_version: routeContractVersion(body.route_contract_version),
    deviceId: uuid(body.deviceId, "invalid_device_id"),
    appInstanceId: uuid(body.appInstanceId, "invalid_app_instance_id"),
    tag: safeTag(body.tag),
    platform: oneOf(body.platform, ["mac", "ios"] as const, "invalid_platform"),
    ...(body.displayName === undefined || body.displayName === null
      ? {}
      : { displayName: safeDisplayName(body.displayName) }),
    endpointId: endpointId(body.endpointId),
    identityGeneration: positiveInteger(body.identityGeneration, "invalid_identity_generation"),
    pairingEnabled: boolean(body.pairingEnabled, "invalid_pairing_enabled"),
    capabilities,
    ...(body.directPorts === undefined
      ? {}
      : { directPorts: parseIrohDirectPorts(body.directPorts) }),
    pathHints,
  };
  rejectUnknownKeys(body, [
    "deviceId",
    "route_contract_version",
    "appInstanceId",
    "tag",
    "platform",
    "displayName",
    "endpointId",
    "identityGeneration",
    "pairingEnabled",
    "capabilities",
    "directPorts",
    "pathHints",
  ]);
  return payload;
}

export function parseIrohDirectPorts(value: unknown): IrohDirectPorts {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new IrohInvalidInputError({ code: "invalid_direct_ports" });
  }
  const ports = value as Record<string, unknown>;
  rejectUnknownKeys(ports, ["ipv4", "ipv6"]);
  const ipv4 = ports.ipv4 === undefined ? undefined : udpPort(ports.ipv4);
  const ipv6 = ports.ipv6 === undefined ? undefined : udpPort(ports.ipv6);
  if (ipv4 === undefined && ipv6 === undefined) {
    throw new IrohInvalidInputError({ code: "invalid_direct_ports" });
  }
  return {
    ...(ipv4 === undefined ? {} : { ipv4 }),
    ...(ipv6 === undefined ? {} : { ipv6 }),
  };
}

export function parseBindingIdBody(value: unknown): { readonly bindingId: string } {
  const body = record(value);
  const result = { bindingId: uuid(body.bindingId, "invalid_binding_id") };
  rejectUnknownKeys(body, ["bindingId"]);
  return result;
}

export function parsePairGrantRequest(value: unknown): {
  readonly initiatorBindingId: string;
  readonly acceptorBindingId: string;
} {
  const body = record(value);
  const result = {
    initiatorBindingId: uuid(body.initiatorBindingId, "invalid_initiator_binding_id"),
    acceptorBindingId: uuid(body.acceptorBindingId, "invalid_acceptor_binding_id"),
  };
  if (result.initiatorBindingId === result.acceptorBindingId) {
    throw new IrohInvalidInputError({ code: "grant_peers_must_differ" });
  }
  rejectUnknownKeys(body, ["initiatorBindingId", "acceptorBindingId"]);
  return result;
}

export function assertChallengeMatchesPayload(
  challenge: IrohChallengeIdentity,
  payload: IrohRegistrationPayload,
): void {
  if (
    challenge.deviceUuid !== payload.deviceId ||
    challenge.appInstanceId !== payload.appInstanceId ||
    challenge.tag !== payload.tag ||
    challenge.endpointId !== payload.endpointId ||
    challenge.identityGeneration !== payload.identityGeneration
  ) {
    throw new IrohInvalidInputError({ code: "challenge_payload_mismatch" });
  }
}

export type IrohChallengeIdentity = {
  readonly deviceUuid: string;
  readonly appInstanceId: string;
  readonly tag: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
};

export function parseIrohPathHint(value: unknown, now: Date): IrohPathHint {
  const hint = record(value);
  const kind = oneOf(hint.kind, ["direct_address", "relay_url"] as const, "invalid_path_hint_kind");
  const source = oneOf(hint.source, ["native", "lan", "tailscale", "custom_vpn"] as const, "invalid_path_hint_source");
  const privacyScope = oneOf(
    hint.privacy_scope,
    ["public_internet", "local_network", "private_network"] as const,
    "invalid_path_hint_scope",
  );
  const expectedScope = source === "native"
    ? "public_internet"
    : source === "lan"
      ? "local_network"
      : "private_network";
  if (privacyScope !== expectedScope) throw new IrohInvalidInputError({ code: "invalid_path_hint_scope" });

  const observedAtRaw = boundedString(hint.observed_at, 1, 40, "invalid_path_hint_observation");
  const observedAt = new Date(observedAtRaw);
  if (
    !Number.isFinite(observedAt.getTime()) ||
    observedAt.getTime() > now.getTime() + 5 * 60 * 1_000 ||
    observedAt.getTime() < now.getTime() - 60 * 60 * 1_000
  ) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_observation" });
  }
  const expiresAtRaw = boundedString(hint.expires_at, 1, 40, "invalid_path_hint_expiry");
  const expiresAt = new Date(expiresAtRaw);
  if (
    !Number.isFinite(expiresAt.getTime()) ||
    expiresAt <= now ||
    expiresAt.getTime() > observedAt.getTime() + 60 * 60 * 1_000
  ) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_expiry" });
  }

  const networkProfile = source === "native"
    ? undefined
    : parseNetworkProfile(hint.network_profile, source);
  if (source === "native" && hint.network_profile !== undefined) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_profile" });
  }
  const hintValue = kind === "relay_url"
    ? relayUrl(hint.value, source, privacyScope)
    : literalSocketAddress(hint.value, privacyScope, source);
  const parsed: IrohPathHint = {
    kind,
    value: hintValue,
    source,
    privacy_scope: privacyScope,
    observed_at: observedAt.toISOString(),
    expires_at: expiresAt.toISOString(),
    ...(networkProfile ? { network_profile: networkProfile } : {}),
  };
  rejectUnknownKeys(hint, [
    "kind",
    "value",
    "source",
    "privacy_scope",
    "observed_at",
    "expires_at",
    "network_profile",
  ]);
  return parsed;
}

export function nextPathHintExpiry(pathHints: readonly IrohPathHint[]): Date | null {
  if (pathHints.length === 0) return null;
  const earliest = Math.min(...pathHints.map((hint) => new Date(hint.expires_at).getTime()));
  if (!Number.isFinite(earliest)) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_expiry" });
  }
  return new Date(earliest);
}

function literalSocketAddress(
  value: unknown,
  scope: IrohPathHint["privacy_scope"],
  source: IrohPathHint["source"],
): string {
  const address = boundedString(value, 3, 80, "invalid_path_hint_address");
  let host = "";
  let port = "";
  if (address.startsWith("[")) {
    const close = address.indexOf("]");
    if (close <= 1 || address[close + 1] !== ":") {
      throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
    }
    host = address.slice(1, close);
    port = address.slice(close + 2);
    if (host.includes("%") || isIP(host) !== 6) {
      throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
    }
  } else {
    const colon = address.lastIndexOf(":");
    if (colon <= 0) throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
    host = address.slice(0, colon);
    port = address.slice(colon + 1);
    if (isIP(host) !== 4) throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
  }
  const numericPort = Number(port);
  if (
    !/^\d{1,5}$/.test(port) ||
    !Number.isInteger(numericPort) ||
    numericPort < 1 || numericPort > 65_535 ||
    String(numericPort) !== port
  ) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
  }
  assertAddressSafe(host, scope, source);
  return isIP(host) === 6
    ? `[${canonicalIpv6(ipv6Bytes(host))}]:${numericPort}`
    : `${host}:${numericPort}`;
}

function parseNetworkProfile(
  value: unknown,
  source: Exclude<IrohPathHint["source"], "native">,
): NonNullable<IrohPathHint["network_profile"]> {
  const profile = record(value);
  if (profile.source !== source) throw new IrohInvalidInputError({ code: "invalid_path_hint_profile" });
  const profileId = boundedString(profile.profile_id, 1, 96, "invalid_path_hint_profile");
  if (!/^[A-Za-z0-9._-]{1,96}$/.test(profileId)) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_profile" });
  }
  rejectUnknownKeys(profile, ["source", "profile_id"]);
  return { source, profile_id: profileId };
}

function relayUrl(
  value: unknown,
  source: IrohPathHint["source"],
  privacyScope: IrohPathHint["privacy_scope"],
): string {
  if (
    source !== "native" ||
    privacyScope !== "public_internet" ||
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 2_048
  ) {
    throw new IrohInvalidInputError({ code: "invalid_relay_hint" });
  }
  try {
    const parsed = new URL(value);
    if (
      parsed.protocol !== "https:" ||
      parsed.username ||
      parsed.password ||
      parsed.search ||
      parsed.hash ||
      parsed.pathname !== "/" ||
      parsed.toString() !== value
    ) {
      throw new Error("non-canonical relay URL");
    }
    return value;
  } catch {
    throw new IrohInvalidInputError({ code: "invalid_relay_hint" });
  }
}

function assertAddressSafe(
  host: string,
  scope: IrohPathHint["privacy_scope"],
  source: IrohPathHint["source"],
): void {
  const family = isIP(host);
  const classification = family === 4 ? classifyIpv4(host) : classifyIpv6(host);
  if (classification === "forbidden") {
    throw new IrohInvalidInputError({ code: "unsafe_path_hint_address" });
  }
  if (scope === "public_internet" && classification !== "public") {
    throw new IrohInvalidInputError({ code: "unsafe_public_path_hint_address" });
  }
  if (scope !== "public_internet" && classification === "public" && source !== "custom_vpn") {
    throw new IrohInvalidInputError({ code: "unsafe_private_path_hint_address" });
  }
  if (scope === "private_network" && classification === "ipv4_link_local") {
    throw new IrohInvalidInputError({ code: "unsafe_private_path_hint_address" });
  }
}

type AddressClassification = "public" | "private" | "ipv4_link_local" | "forbidden";

function classifyIpv4(host: string): AddressClassification {
  const rawOctets = host.split(".");
  const octets = rawOctets.map(Number);
  if (rawOctets.some((octet, index) => String(octets[index]) !== octet)) return "forbidden";
  const [a, b, c, d] = octets as [number, number, number, number];
  if (a === 0 || a === 127 || a >= 224) return "forbidden";
  if (a === 169 && b === 254) {
    if (c === 169 && d === 254) return "forbidden";
    return "ipv4_link_local";
  }
  if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) return "private";
  if (a === 100 && b >= 64 && b <= 127) return "private";
  if (
    (a === 192 && b === 0 && (c === 0 || c === 2)) ||
    (a === 192 && b === 88 && c === 99) ||
    (a === 198 && (b === 18 || b === 19)) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113)
  ) return "forbidden";
  return "public";
}

function classifyIpv6(host: string): AddressClassification {
  const bytes = ipv6Bytes(host);
  const allZero = bytes.every((byte) => byte === 0);
  const loopback = bytes.slice(0, 15).every((byte) => byte === 0) && bytes[15] === 1;
  const multicast = bytes[0] === 0xff;
  const linkLocal = bytes[0] === 0xfe && (bytes[1]! & 0xc0) === 0x80;
  const documentation = bytes[0] === 0x20 && bytes[1] === 0x01 && bytes[2] === 0x0d && bytes[3] === 0xb8;
  const mappedIpv4 = bytes.slice(0, 10).every((byte) => byte === 0) && bytes[10] === 0xff && bytes[11] === 0xff;
  const metadata = bytesEqual(bytes, [0xfd, 0x00, 0x0e, 0xc2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54]);
  if (allZero || loopback || multicast || linkLocal || documentation || mappedIpv4 || metadata) return "forbidden";
  if ((bytes[0]! & 0xfe) === 0xfc) return "private";
  return "public";
}

function ipv6Bytes(host: string): number[] {
  const sides = host.toLowerCase().split("::");
  if (sides.length > 2) throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
  const left = sides[0] ? sides[0].split(":") : [];
  const right = sides.length === 2 && sides[1] ? sides[1].split(":") : [];
  const expand = (groups: string[]): number[] => groups.flatMap((group) => {
    if (!/^[0-9a-f]{1,4}$/.test(group)) {
      throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
    }
    const value = Number.parseInt(group, 16);
    return [(value >> 8) & 0xff, value & 0xff];
  });
  const missingGroups = 8 - left.length - right.length;
  if ((sides.length === 1 && missingGroups !== 0) || missingGroups < (sides.length === 2 ? 1 : 0)) {
    throw new IrohInvalidInputError({ code: "invalid_path_hint_address" });
  }
  return [
    ...expand(left),
    ...Array.from({ length: missingGroups * 2 }, () => 0),
    ...expand(right),
  ];
}

function canonicalIpv6(bytes: readonly number[]): string {
  const groups = Array.from({ length: 8 }, (_, index) =>
    ((bytes[index * 2]! << 8) | bytes[index * 2 + 1]!).toString(16));
  let bestStart = -1;
  let bestLength = 0;
  for (let start = 0; start < groups.length;) {
    if (groups[start] !== "0") {
      start += 1;
      continue;
    }
    let end = start;
    while (end < groups.length && groups[end] === "0") end += 1;
    if (end - start > bestLength && end - start >= 2) {
      bestStart = start;
      bestLength = end - start;
    }
    start = end;
  }
  if (bestStart < 0) return groups.join(":");
  const left = groups.slice(0, bestStart).join(":");
  const right = groups.slice(bestStart + bestLength).join(":");
  if (!left && !right) return "::";
  if (!left) return `::${right}`;
  if (!right) return `${left}::`;
  return `${left}::${right}`;
}

function bytesEqual(left: readonly number[], right: readonly number[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function routeContractVersion(value: unknown): typeof IROH_ROUTE_CONTRACT_VERSION {
  if (value !== IROH_ROUTE_CONTRACT_VERSION) {
    throw new IrohInvalidInputError({ code: "unsupported_route_contract" });
  }
  return IROH_ROUTE_CONTRACT_VERSION;
}

export function endpointId(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new IrohInvalidInputError({ code: "invalid_endpoint_id" });
  }
  return value;
}

export function sha256Hex(value: unknown, code: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new IrohInvalidInputError({ code });
  }
  return value;
}

export function sha256(value: Uint8Array | string): string {
  return createHash("sha256").update(value).digest("hex");
}

function base64url(value: unknown, decodedLength: number, code: string): string {
  if (typeof value !== "string" || value.length > decodedLength * 2 || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new IrohInvalidInputError({ code });
  }
  const decoded = Buffer.from(value, "base64url");
  if (decoded.byteLength !== decodedLength || decoded.toString("base64url") !== value) {
    throw new IrohInvalidInputError({ code });
  }
  return value;
}

function uuid(value: unknown, code: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new IrohInvalidInputError({ code });
  }
  return value.toLowerCase();
}

function positiveInteger(value: unknown, code: string): number {
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < 1 ||
    (value as number) > POSTGRES_INT32_MAX
  ) throw new IrohInvalidInputError({ code });
  return value as number;
}

function udpPort(value: unknown): number {
  if (!Number.isInteger(value) || (value as number) < 1 || (value as number) > 65_535) {
    throw new IrohInvalidInputError({ code: "invalid_direct_ports" });
  }
  return value as number;
}

function boundedString(value: unknown, min: number, max: number, code: string): string {
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new IrohInvalidInputError({ code });
  }
  return value;
}

function safeTag(value: unknown): string {
  const tag = boundedString(value, 1, 64, "invalid_tag");
  if (!/^[A-Za-z0-9._-]+$/.test(tag)) throw new IrohInvalidInputError({ code: "invalid_tag" });
  return tag;
}

function safeDisplayName(value: unknown): string {
  const displayName = boundedString(value, 1, 128, "invalid_display_name");
  if (/[\u0000-\u001f\u007f]/.test(displayName)) {
    throw new IrohInvalidInputError({ code: "invalid_display_name" });
  }
  return displayName;
}

function boolean(value: unknown, code: string): boolean {
  if (typeof value !== "boolean") throw new IrohInvalidInputError({ code });
  return value;
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new IrohInvalidInputError({ code: "invalid_json" });
  }
  return value as Record<string, unknown>;
}

function rejectUnknownKeys(value: Record<string, unknown>, allowed: readonly string[]): void {
  const allow = new Set(allowed);
  if (Object.keys(value).some((key) => !allow.has(key))) {
    throw new IrohInvalidInputError({ code: "unknown_field" });
  }
}

function oneOf<const T extends readonly string[]>(value: unknown, allowed: T, code: string): T[number] {
  if (typeof value !== "string" || !allowed.includes(value)) throw new IrohInvalidInputError({ code });
  return value as T[number];
}
