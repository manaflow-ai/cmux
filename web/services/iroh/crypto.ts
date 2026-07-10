import {
  createHmac,
  createPrivateKey,
  createPublicKey,
  sign,
  timingSafeEqual,
  verify,
  type KeyObject,
} from "node:crypto";
import {
  IROH_ALPN,
  IROH_PAIR_GRANT_LIFETIME_SECONDS,
  IROH_PAIR_GRANT_TYP,
  IROH_PAIR_SCOPE,
  endpointId,
  sha256,
} from "./model";
import { IrohConfigurationError, IrohForbiddenError, IrohInvalidInputError } from "./errors";

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export type PairGrantPeer = {
  readonly bindingId: string;
  readonly deviceId: string;
  readonly tag: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
};

export type PairGrantClaims = {
  readonly jti: string;
  readonly iat: number;
  readonly nbf: number;
  readonly exp: number;
  readonly alpn: typeof IROH_ALPN;
  readonly scope: typeof IROH_PAIR_SCOPE;
  readonly initiator: PairGrantPeer;
  readonly acceptor: PairGrantPeer;
};

export type PairGrantVerificationExpectation = {
  readonly initiator?: PairGrantPeer;
  readonly acceptor?: PairGrantPeer;
  readonly nowSeconds: number;
};

export function registrationTranscript(input: {
  readonly challengeId: string;
  readonly nonce: string;
  readonly payloadSha256: string;
}): Uint8Array {
  return Buffer.from(
    `cmux/iroh/device-registration/v1\n${input.challengeId}\n${input.nonce}\n${input.payloadSha256}`,
    "utf8",
  );
}

export function verifyEndpointRegistrationSignature(input: {
  readonly endpointId: string;
  readonly challengeId: string;
  readonly nonce: string;
  readonly payloadSha256: string;
  readonly signature: string;
}): void {
  const publicKey = endpointPublicKey(input.endpointId);
  const signature = Buffer.from(input.signature, "base64url");
  const valid = verify(
    null,
    registrationTranscript(input),
    publicKey,
    signature,
  );
  if (!valid) throw new IrohForbiddenError({ code: "invalid_registration_signature" });
}

export function nonceHash(nonce: string): string {
  return sha256(Buffer.from(nonce, "base64url"));
}

export function hashesEqual(leftHex: string, rightHex: string): boolean {
  if (!/^[0-9a-f]{64}$/.test(leftHex) || !/^[0-9a-f]{64}$/.test(rightHex)) return false;
  return timingSafeEqual(Buffer.from(leftHex, "hex"), Buffer.from(rightHex, "hex"));
}

export function deriveLanRendezvousKey(
  secretBase64: string | undefined,
  userId: string,
  generation: number,
): string {
  const secret = decodeSecret(secretBase64, "lan_discovery");
  if (!Number.isSafeInteger(generation) || generation < 1) {
    throw new IrohConfigurationError({ component: "lan_discovery" });
  }
  return createHmac("sha256", secret)
    .update("cmux/iroh/lan-rendezvous/v1\0", "utf8")
    .update(userId, "utf8")
    .update("\0", "utf8")
    .update(String(generation), "utf8")
    .digest("base64url");
}

export function signPairGrant(input: {
  readonly privateKeyPem: string | undefined;
  readonly kid: string | undefined;
  readonly claims: PairGrantClaims;
}): string {
  const kid = validKid(input.kid, "grant_signing");
  let privateKey: KeyObject;
  try {
    privateKey = createPrivateKey(normalizePem(input.privateKeyPem, "grant_signing"));
  } catch {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  validatePairGrantClaims(input.claims, { nowSeconds: input.claims.iat });
  const encodedHeader = encodeJson({ alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid });
  const encodedClaims = encodeJson(input.claims);
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const signature = sign(null, Buffer.from(signingInput, "ascii"), privateKey).toString("base64url");
  return `${signingInput}.${signature}`;
}

export function verifyPairGrant(
  token: string,
  publicKeys: ReadonlyMap<string, string>,
  expected: PairGrantVerificationExpectation,
): PairGrantClaims {
  if (token.length > 16_384) throw new IrohInvalidInputError({ code: "invalid_pair_grant" });
  const parts = token.split(".");
  if (parts.length !== 3) throw new IrohInvalidInputError({ code: "invalid_pair_grant" });
  const header = decodeJson(parts[0]);
  assertExactKeys(header, ["alg", "typ", "kid"], "invalid_pair_grant_header");
  if (header.alg !== "EdDSA" || header.typ !== IROH_PAIR_GRANT_TYP || typeof header.kid !== "string") {
    throw new IrohForbiddenError({ code: "invalid_pair_grant_header" });
  }
  const keyPem = publicKeys.get(header.kid);
  if (!keyPem) throw new IrohForbiddenError({ code: "unknown_pair_grant_kid" });
  let publicKey: KeyObject;
  try {
    publicKey = createPublicKey(normalizePem(keyPem, "grant_verification"));
  } catch {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  if (publicKey.asymmetricKeyType !== "ed25519") {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  const valid = verify(
    null,
    Buffer.from(`${parts[0]}.${parts[1]}`, "ascii"),
    publicKey,
    decodeCanonicalBase64url(parts[2], 64),
  );
  if (!valid) throw new IrohForbiddenError({ code: "invalid_pair_grant_signature" });
  const claims = decodeJson(parts[1]) as unknown as PairGrantClaims;
  validatePairGrantClaims(claims, expected);
  return claims;
}

export function parseVerificationKeys(value: string | undefined): ReadonlyMap<string, string> {
  if (!value) return new Map();
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  const entries = Object.entries(parsed as Record<string, unknown>);
  if (entries.length < 1 || entries.length > 2) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  return new Map(entries.map(([kid, pem]) => [
    validKid(kid, "grant_verification"),
    normalizePem(typeof pem === "string" ? pem : undefined, "grant_verification"),
  ]));
}

function validatePairGrantClaims(
  value: PairGrantClaims,
  expected: PairGrantVerificationExpectation,
): void {
  if (!value || typeof value !== "object") throw new IrohForbiddenError({ code: "invalid_pair_grant_claims" });
  assertExactKeys(value as unknown as Record<string, unknown>, [
    "jti",
    "iat",
    "nbf",
    "exp",
    "alpn",
    "scope",
    "initiator",
    "acceptor",
  ], "invalid_pair_grant_claims");
  if (typeof value.jti !== "string" || !UUID_PATTERN.test(value.jti)) {
    throw new IrohForbiddenError({ code: "invalid_pair_grant_claims" });
  }
  if (value.alpn !== IROH_ALPN) throw new IrohForbiddenError({ code: "invalid_pair_grant_alpn" });
  if (value.scope !== IROH_PAIR_SCOPE) throw new IrohForbiddenError({ code: "invalid_pair_grant_scope" });
  if (!Number.isSafeInteger(value.iat) || !Number.isSafeInteger(value.nbf) || !Number.isSafeInteger(value.exp)) {
    throw new IrohForbiddenError({ code: "invalid_pair_grant_expiry" });
  }
  if (
    value.nbf > expected.nowSeconds + 30 ||
    value.exp <= expected.nowSeconds ||
    value.exp <= value.nbf ||
    value.exp - value.iat > IROH_PAIR_GRANT_LIFETIME_SECONDS ||
    value.iat > expected.nowSeconds + 30
  ) {
    throw new IrohForbiddenError({ code: "invalid_pair_grant_expiry" });
  }
  validatePeer(value.initiator, "initiator");
  validatePeer(value.acceptor, "acceptor");
  if (expected.initiator && !samePeer(value.initiator, expected.initiator)) {
    throw new IrohForbiddenError({ code: "pair_grant_initiator_mismatch" });
  }
  if (expected.acceptor && !samePeer(value.acceptor, expected.acceptor)) {
    throw new IrohForbiddenError({ code: "pair_grant_acceptor_mismatch" });
  }
}

function validatePeer(peer: PairGrantPeer, side: string): void {
  if (
    !peer || typeof peer !== "object" ||
    typeof peer.bindingId !== "string" || !UUID_PATTERN.test(peer.bindingId) ||
    typeof peer.deviceId !== "string" || !UUID_PATTERN.test(peer.deviceId) ||
    typeof peer.tag !== "string" || peer.tag.length < 1 || peer.tag.length > 64 ||
    !Number.isSafeInteger(peer.identityGeneration) || peer.identityGeneration < 1
  ) {
    throw new IrohForbiddenError({ code: `invalid_pair_grant_${side}` });
  }
  assertExactKeys(peer as unknown as Record<string, unknown>, [
    "bindingId",
    "deviceId",
    "tag",
    "endpointId",
    "identityGeneration",
  ], `invalid_pair_grant_${side}`);
  endpointId(peer.endpointId);
}

function samePeer(left: PairGrantPeer, right: PairGrantPeer): boolean {
  return left.bindingId === right.bindingId &&
    left.deviceId === right.deviceId &&
    left.tag === right.tag &&
    left.endpointId === right.endpointId &&
    left.identityGeneration === right.identityGeneration;
}

function endpointPublicKey(value: string): KeyObject {
  const canonical = endpointId(value);
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(canonical, "hex")]),
    format: "der",
    type: "spki",
  });
}

function decodeSecret(value: string | undefined, component: "lan_discovery"): Buffer {
  if (!value) throw new IrohConfigurationError({ component });
  const decoded = Buffer.from(value, "base64");
  if (decoded.byteLength < 32 || decoded.toString("base64").replace(/=+$/, "") !== value.replace(/=+$/, "")) {
    throw new IrohConfigurationError({ component });
  }
  return decoded;
}

function validKid(
  value: string | undefined,
  component: "grant_signing" | "grant_verification",
): string {
  if (!value || !/^[A-Za-z0-9._-]{1,64}$/.test(value)) {
    throw new IrohConfigurationError({ component });
  }
  return value;
}

function normalizePem(
  value: string | undefined,
  component: "grant_signing" | "grant_verification",
): string {
  if (!value) throw new IrohConfigurationError({ component });
  const normalized = value.replaceAll("\\n", "\n").trim();
  if (normalized.length > 16_384 || !normalized.includes("-----BEGIN")) {
    throw new IrohConfigurationError({ component });
  }
  return normalized;
}

function encodeJson(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function decodeJson(encoded: string): Record<string, unknown> {
  try {
    const value = JSON.parse(decodeCanonicalBase64url(encoded).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not object");
    return value as Record<string, unknown>;
  } catch {
    throw new IrohInvalidInputError({ code: "invalid_pair_grant" });
  }
}

function decodeCanonicalBase64url(encoded: string, expectedLength?: number): Buffer {
  if (!encoded || !/^[A-Za-z0-9_-]+$/.test(encoded)) {
    throw new IrohInvalidInputError({ code: "invalid_pair_grant" });
  }
  const decoded = Buffer.from(encoded, "base64url");
  if (
    decoded.toString("base64url") !== encoded ||
    (expectedLength !== undefined && decoded.byteLength !== expectedLength)
  ) {
    throw new IrohInvalidInputError({ code: "invalid_pair_grant" });
  }
  return decoded;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function assertExactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  code: string,
): void {
  const keys = Object.keys(value);
  if (keys.length !== allowed.length || keys.some((key) => !allowed.includes(key))) {
    throw new IrohForbiddenError({ code });
  }
}
