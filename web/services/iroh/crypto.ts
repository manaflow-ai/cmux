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
  IROH_ENDPOINT_ATTESTATION_LIFETIME_SECONDS,
  IROH_ENDPOINT_ATTESTATION_SCOPE,
  IROH_ENDPOINT_ATTESTATION_TYP,
  IROH_ENDPOINT_ATTESTATION_VERSION,
  IROH_OFFLINE_PAIR_SESSION_LIFETIME_SECONDS,
  IROH_OFFLINE_PAIR_SESSION_VERSION,
  IROH_ALPN,
  IROH_PAIR_GRANT_LIFETIME_SECONDS,
  IROH_PAIR_GRANT_TYP,
  IROH_PAIR_SCOPE,
  endpointId,
  POSTGRES_INT32_MAX,
  sha256,
} from "./model";
import { IrohConfigurationError, IrohForbiddenError, IrohInvalidInputError } from "./errors";

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export type PairGrantPeer = {
  readonly bindingId: string;
  readonly deviceId: string;
  readonly tag: string;
  readonly platform: "mac" | "ios";
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

export type PairGrantVerificationKey = {
  readonly kid: string;
  readonly alg: "EdDSA";
  readonly spki_der_base64: string;
};

export type PairGrantVerificationKeySet = {
  readonly version: 1;
  readonly current_kid: string;
  readonly keys: readonly PairGrantVerificationKey[];
};

export type ParsedPairGrantVerificationKeys = {
  readonly keySet: PairGrantVerificationKeySet;
  readonly publicKeys: ReadonlyMap<string, string>;
};

export type EndpointAttestationClaims = {
  readonly version: typeof IROH_ENDPOINT_ATTESTATION_VERSION;
  readonly jti: string;
  readonly sub: string;
  readonly bindingId: string;
  readonly deviceId: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly platform: "mac" | "ios";
  readonly iat: number;
  readonly nbf: number;
  readonly exp: number;
  readonly alpn: typeof IROH_ALPN;
  readonly scope: typeof IROH_ENDPOINT_ATTESTATION_SCOPE;
};

export type EndpointAttestationExpectation = {
  readonly bindingId: string;
  readonly deviceId: string;
  readonly endpointId: string;
  readonly identityGeneration: number;
  readonly platform: "mac" | "ios";
  readonly nowSeconds: number;
};

export type OfflinePairVerificationExpectation = {
  readonly initiator: Omit<EndpointAttestationExpectation, "nowSeconds" | "platform"> & {
    readonly platform: "ios";
  };
  readonly acceptor: Omit<EndpointAttestationExpectation, "nowSeconds" | "platform"> & {
    readonly platform: "mac";
  };
  readonly nowSeconds: number;
};

export type OfflinePairSessionRecord = {
  readonly version: typeof IROH_OFFLINE_PAIR_SESSION_VERSION;
  readonly sessionId: string;
  readonly acceptor: OfflinePairVerificationExpectation["acceptor"];
  readonly proofHash: string;
  readonly createdAtSeconds: number;
  readonly expiresAtSeconds: number;
  consumedAtSeconds: number | null;
};

export type OfflinePairInvitationProof = {
  readonly version: typeof IROH_OFFLINE_PAIR_SESSION_VERSION;
  readonly sessionId: string;
  readonly proof: string;
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
  const signature = decodeCanonicalBase64url(
    input.signature,
    64,
    "invalid_registration_signature",
  );
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
  if (!Number.isSafeInteger(generation) || generation < 1 || generation > POSTGRES_INT32_MAX) {
    throw new IrohConfigurationError({ component: "lan_discovery" });
  }
  return createHmac("sha256", secret)
    .update("cmux/iroh/lan-rendezvous/v1\0", "utf8")
    .update(userId, "utf8")
    .update("\0", "utf8")
    .update(String(generation), "utf8")
    .digest("base64url");
}

export function deriveAccountSubject(
  secretBase64: string | undefined,
  userId: string,
): string {
  const secret = decodeSecret(secretBase64, "account_subject");
  if (!userId || userId.length > 1_024) {
    throw new IrohConfigurationError({ component: "account_subject" });
  }
  return createHmac("sha256", secret)
    .update("cmux/iroh/account-subject/v1\0", "utf8")
    .update(userId, "utf8")
    .digest("base64url");
}

export function signPairGrant(input: {
  readonly privateKeyPem: string | undefined;
  readonly kid: string | undefined;
  readonly claims: PairGrantClaims;
}): string {
  const kid = validKid(input.kid, "grant_signing");
  const privateKey = signingPrivateKey(input.privateKeyPem);
  validatePairGrantClaims(input.claims, { nowSeconds: input.claims.iat });
  const encodedHeader = encodeJson({ alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid });
  const encodedClaims = encodeJson(input.claims);
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const signature = sign(null, Buffer.from(signingInput, "ascii"), privateKey).toString("base64url");
  return `${signingInput}.${signature}`;
}

export function signEndpointAttestation(input: {
  readonly privateKeyPem: string | undefined;
  readonly kid: string | undefined;
  readonly claims: EndpointAttestationClaims;
}): string {
  const kid = validKid(input.kid, "grant_signing");
  const privateKey = signingPrivateKey(input.privateKeyPem);
  validateEndpointAttestationClaims(input.claims, {
    bindingId: input.claims.bindingId,
    deviceId: input.claims.deviceId,
    endpointId: input.claims.endpointId,
    identityGeneration: input.claims.identityGeneration,
    platform: input.claims.platform,
    nowSeconds: input.claims.iat,
  });
  const encodedHeader = encodeJson({
    alg: "EdDSA",
    typ: IROH_ENDPOINT_ATTESTATION_TYP,
    kid,
  });
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
  const header = decodeJson(parts[0], "invalid_pair_grant");
  assertExactKeys(header, ["alg", "typ", "kid"], "invalid_pair_grant_header");
  if (header.alg !== "EdDSA" || header.typ !== IROH_PAIR_GRANT_TYP || typeof header.kid !== "string") {
    throw new IrohForbiddenError({ code: "invalid_pair_grant_header" });
  }
  const keyDerBase64 = publicKeys.get(header.kid);
  if (!keyDerBase64) throw new IrohForbiddenError({ code: "unknown_pair_grant_kid" });
  const publicKey = verificationPublicKey(keyDerBase64);
  const valid = verify(
    null,
    Buffer.from(`${parts[0]}.${parts[1]}`, "ascii"),
    publicKey,
    decodeCanonicalBase64url(parts[2], 64, "invalid_pair_grant"),
  );
  if (!valid) throw new IrohForbiddenError({ code: "invalid_pair_grant_signature" });
  const claims = decodeJson(parts[1], "invalid_pair_grant") as unknown as PairGrantClaims;
  validatePairGrantClaims(claims, expected);
  return claims;
}

export function verifyEndpointAttestation(
  token: string,
  publicKeys: ReadonlyMap<string, string>,
  expected: EndpointAttestationExpectation,
): EndpointAttestationClaims {
  if (token.length > 16_384) {
    throw new IrohInvalidInputError({ code: "invalid_endpoint_attestation" });
  }
  const parts = token.split(".");
  if (parts.length !== 3) {
    throw new IrohInvalidInputError({ code: "invalid_endpoint_attestation" });
  }
  const header = decodeJson(parts[0], "invalid_endpoint_attestation");
  assertExactKeys(header, ["alg", "typ", "kid"], "invalid_endpoint_attestation_header");
  if (
    header.alg !== "EdDSA" ||
    header.typ !== IROH_ENDPOINT_ATTESTATION_TYP ||
    typeof header.kid !== "string"
  ) {
    throw new IrohForbiddenError({ code: "invalid_endpoint_attestation_header" });
  }
  const keyDerBase64 = publicKeys.get(header.kid);
  if (!keyDerBase64) {
    throw new IrohForbiddenError({ code: "unknown_endpoint_attestation_kid" });
  }
  const publicKey = verificationPublicKey(keyDerBase64);
  const valid = verify(
    null,
    Buffer.from(`${parts[0]}.${parts[1]}`, "ascii"),
    publicKey,
    decodeCanonicalBase64url(parts[2], 64, "invalid_endpoint_attestation"),
  );
  if (!valid) {
    throw new IrohForbiddenError({ code: "invalid_endpoint_attestation_signature" });
  }
  const claims = decodeJson(
    parts[1],
    "invalid_endpoint_attestation",
  ) as unknown as EndpointAttestationClaims;
  validateEndpointAttestationClaims(claims, expected);
  return claims;
}

function verifyOfflineSameAccountPair(input: {
  readonly initiatorAttestation: string;
  readonly acceptorAttestation: string;
  readonly publicKeys: ReadonlyMap<string, string>;
  readonly expected: OfflinePairVerificationExpectation;
}): {
  readonly initiator: EndpointAttestationClaims;
  readonly acceptor: EndpointAttestationClaims;
} {
  if (
    input.expected.initiator.platform !== "ios" ||
    input.expected.acceptor.platform !== "mac"
  ) {
    throw new IrohForbiddenError({ code: "invalid_offline_pair_platforms" });
  }
  const initiator = verifyEndpointAttestation(input.initiatorAttestation, input.publicKeys, {
    ...input.expected.initiator,
    nowSeconds: input.expected.nowSeconds,
  });
  const acceptor = verifyEndpointAttestation(input.acceptorAttestation, input.publicKeys, {
    ...input.expected.acceptor,
    nowSeconds: input.expected.nowSeconds,
  });
  if (
    initiator.bindingId === acceptor.bindingId ||
    initiator.deviceId === acceptor.deviceId ||
    initiator.endpointId === acceptor.endpointId ||
    !canonicalSubjectsEqual(initiator.sub, acceptor.sub)
  ) {
    throw new IrohForbiddenError({ code: "offline_pair_same_account_proof_required" });
  }
  return { initiator, acceptor };
}

export function createOfflinePairSessionRecord(input: {
  readonly sessionId: string;
  readonly proof: string;
  readonly acceptor: OfflinePairVerificationExpectation["acceptor"];
  readonly nowSeconds: number;
  readonly expiresAtSeconds: number;
}): OfflinePairSessionRecord {
  validateOfflinePairSessionWindow(input.nowSeconds, input.expiresAtSeconds);
  validateEndpointExpectation(input.acceptor, "mac");
  if (!UUID_PATTERN.test(input.sessionId) || input.sessionId !== input.sessionId.toLowerCase()) {
    throw new IrohInvalidInputError({ code: "invalid_offline_pair_session" });
  }
  const proof = decodeCanonicalBase64url(input.proof, 32, "invalid_offline_pair_proof");
  return {
    version: IROH_OFFLINE_PAIR_SESSION_VERSION,
    sessionId: input.sessionId.toLowerCase(),
    acceptor: { ...input.acceptor },
    proofHash: offlinePairProofHash(input.sessionId.toLowerCase(), input.acceptor, proof),
    createdAtSeconds: input.nowSeconds,
    expiresAtSeconds: input.expiresAtSeconds,
    consumedAtSeconds: null,
  };
}

export function verifyAndConsumeOfflineSameAccountPair(input: {
  readonly initiatorAttestation: string;
  readonly acceptorAttestation: string;
  readonly publicKeys: ReadonlyMap<string, string>;
  readonly expected: OfflinePairVerificationExpectation;
  readonly session: OfflinePairSessionRecord;
  readonly invitation: OfflinePairInvitationProof;
}): {
  readonly initiator: EndpointAttestationClaims;
  readonly acceptor: EndpointAttestationClaims;
  readonly sessionId: string;
} {
  const { session, invitation } = input;
  if (
    typeof invitation.sessionId !== "string" ||
    !UUID_PATTERN.test(invitation.sessionId) ||
    invitation.sessionId !== invitation.sessionId.toLowerCase()
  ) {
    throw new IrohInvalidInputError({ code: "invalid_offline_pair_session" });
  }
  if (
    session.version !== IROH_OFFLINE_PAIR_SESSION_VERSION ||
    invitation.version !== IROH_OFFLINE_PAIR_SESSION_VERSION ||
    session.consumedAtSeconds !== null ||
    session.sessionId !== invitation.sessionId ||
    !sameEndpointExpectation(session.acceptor, input.expected.acceptor) ||
    session.createdAtSeconds > input.expected.nowSeconds + 30 ||
    session.expiresAtSeconds <= input.expected.nowSeconds
  ) {
    throw new IrohForbiddenError({ code: "offline_pair_session_unavailable" });
  }
  validateOfflinePairSessionWindow(
    session.createdAtSeconds,
    session.expiresAtSeconds,
  );
  const proof = decodeCanonicalBase64url(invitation.proof, 32, "invalid_offline_pair_proof");
  const actualHash = offlinePairProofHash(session.sessionId, session.acceptor, proof);
  if (!hashesEqual(session.proofHash, actualHash)) {
    throw new IrohForbiddenError({ code: "invalid_offline_pair_proof" });
  }
  const verified = verifyOfflineSameAccountPair(input);
  session.consumedAtSeconds = input.expected.nowSeconds;
  return { ...verified, sessionId: session.sessionId };
}

export function parseVerificationKeys(
  value: string | undefined,
): ParsedPairGrantVerificationKeys {
  if (!value || value.length > 32_768) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  const object = parsed as Record<string, unknown>;
  if (!hasExactKeys(object, ["version", "current_kid", "keys"])) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  if (object.version !== 1 || !Array.isArray(object.keys)) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  const currentKid = validKid(
    typeof object.current_kid === "string" ? object.current_kid : undefined,
    "grant_verification",
  );
  if (object.keys.length < 1 || object.keys.length > 2) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }

  const seen = new Set<string>();
  const keys = object.keys.map((raw): PairGrantVerificationKey => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new IrohConfigurationError({ component: "grant_verification" });
    }
    const key = raw as Record<string, unknown>;
    if (!hasExactKeys(key, ["kid", "alg", "spki_der_base64"]) || key.alg !== "EdDSA") {
      throw new IrohConfigurationError({ component: "grant_verification" });
    }
    const kid = validKid(typeof key.kid === "string" ? key.kid : undefined, "grant_verification");
    if (seen.has(kid)) {
      throw new IrohConfigurationError({ component: "grant_verification" });
    }
    seen.add(kid);
    const spkiDerBase64 = typeof key.spki_der_base64 === "string"
      ? canonicalVerificationKey(key.spki_der_base64)
      : configurationFailure();
    return { kid, alg: "EdDSA", spki_der_base64: spkiDerBase64 };
  });
  if (!seen.has(currentKid)) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  keys.sort((left, right) => {
    if (left.kid === currentKid) return -1;
    if (right.kid === currentKid) return 1;
    return left.kid.localeCompare(right.kid);
  });
  return {
    keySet: { version: 1, current_kid: currentKid, keys },
    publicKeys: new Map(keys.map((key) => [key.kid, key.spki_der_base64])),
  };
}

export function assertCurrentSigningKey(input: {
  readonly privateKeyPem: string | undefined;
  readonly kid: string | undefined;
  readonly verificationKeys: ParsedPairGrantVerificationKeys;
}): void {
  const kid = validKid(input.kid, "grant_signing");
  if (kid !== input.verificationKeys.keySet.current_kid) {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  const expectedDerBase64 = input.verificationKeys.publicKeys.get(kid);
  if (!expectedDerBase64) {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  const privateKey = signingPrivateKey(input.privateKeyPem);
  let actualDer: Buffer;
  try {
    actualDer = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  } catch {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  const expectedDer = Buffer.from(expectedDerBase64, "base64");
  if (actualDer.byteLength !== expectedDer.byteLength || !timingSafeEqual(actualDer, expectedDer)) {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
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
  if (value.initiator.platform !== "ios" || value.acceptor.platform !== "mac") {
    throw new IrohForbiddenError({ code: "invalid_pair_grant_platforms" });
  }
  if (
    value.initiator.bindingId === value.acceptor.bindingId ||
    value.initiator.deviceId === value.acceptor.deviceId ||
    value.initiator.endpointId === value.acceptor.endpointId
  ) {
    throw new IrohForbiddenError({ code: "pair_grant_peers_not_distinct" });
  }
  if (expected.initiator && !samePeer(value.initiator, expected.initiator)) {
    throw new IrohForbiddenError({ code: "pair_grant_initiator_mismatch" });
  }
  if (expected.acceptor && !samePeer(value.acceptor, expected.acceptor)) {
    throw new IrohForbiddenError({ code: "pair_grant_acceptor_mismatch" });
  }
}

function validateEndpointAttestationClaims(
  value: EndpointAttestationClaims,
  expected: EndpointAttestationExpectation,
): void {
  if (!value || typeof value !== "object") {
    throw new IrohForbiddenError({ code: "invalid_endpoint_attestation_claims" });
  }
  assertExactKeys(value as unknown as Record<string, unknown>, [
    "version",
    "jti",
    "sub",
    "bindingId",
    "deviceId",
    "endpointId",
    "identityGeneration",
    "platform",
    "iat",
    "nbf",
    "exp",
    "alpn",
    "scope",
  ], "invalid_endpoint_attestation_claims");
  if (
    value.version !== IROH_ENDPOINT_ATTESTATION_VERSION ||
    typeof value.jti !== "string" || !UUID_PATTERN.test(value.jti) ||
    typeof value.bindingId !== "string" || !UUID_PATTERN.test(value.bindingId) ||
    typeof value.deviceId !== "string" || !UUID_PATTERN.test(value.deviceId) ||
    !Number.isSafeInteger(value.identityGeneration) ||
    value.identityGeneration < 1 ||
    value.identityGeneration > POSTGRES_INT32_MAX ||
    (value.platform !== "mac" && value.platform !== "ios") ||
    value.alpn !== IROH_ALPN ||
    value.scope !== IROH_ENDPOINT_ATTESTATION_SCOPE
  ) {
    throw new IrohForbiddenError({ code: "invalid_endpoint_attestation_claims" });
  }
  endpointId(value.endpointId);
  decodeCanonicalBase64url(value.sub, 32, "invalid_endpoint_attestation_claims");
  if (
    !Number.isSafeInteger(value.iat) ||
    !Number.isSafeInteger(value.nbf) ||
    !Number.isSafeInteger(value.exp) ||
    value.nbf < value.iat - 30 ||
    value.nbf > expected.nowSeconds + 30 ||
    value.exp <= expected.nowSeconds ||
    value.exp <= value.nbf ||
    value.exp - value.iat > IROH_ENDPOINT_ATTESTATION_LIFETIME_SECONDS ||
    value.iat > expected.nowSeconds + 30
  ) {
    throw new IrohForbiddenError({ code: "invalid_endpoint_attestation_expiry" });
  }
  if (
    value.bindingId !== expected.bindingId ||
    value.deviceId !== expected.deviceId ||
    value.endpointId !== expected.endpointId ||
    value.identityGeneration !== expected.identityGeneration ||
    value.platform !== expected.platform
  ) {
    throw new IrohForbiddenError({ code: "endpoint_attestation_identity_mismatch" });
  }
}

function validatePeer(peer: PairGrantPeer, side: string): void {
  if (
    !peer || typeof peer !== "object" ||
    typeof peer.bindingId !== "string" || !UUID_PATTERN.test(peer.bindingId) ||
    typeof peer.deviceId !== "string" || !UUID_PATTERN.test(peer.deviceId) ||
    typeof peer.tag !== "string" || peer.tag.length < 1 || peer.tag.length > 64 ||
    !Number.isSafeInteger(peer.identityGeneration) ||
    peer.identityGeneration < 1 ||
    peer.identityGeneration > POSTGRES_INT32_MAX ||
    (peer.platform !== "mac" && peer.platform !== "ios")
  ) {
    throw new IrohForbiddenError({ code: `invalid_pair_grant_${side}` });
  }
  assertExactKeys(peer as unknown as Record<string, unknown>, [
    "bindingId",
    "deviceId",
    "tag",
    "platform",
    "endpointId",
    "identityGeneration",
  ], `invalid_pair_grant_${side}`);
  endpointId(peer.endpointId);
}

function samePeer(left: PairGrantPeer, right: PairGrantPeer): boolean {
  return left.bindingId === right.bindingId &&
    left.deviceId === right.deviceId &&
    left.tag === right.tag &&
    left.platform === right.platform &&
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

function decodeSecret(
  value: string | undefined,
  component: "lan_discovery" | "account_subject",
): Buffer {
  if (!value || value.length > 512) throw new IrohConfigurationError({ component });
  const decoded = Buffer.from(value, "base64");
  if (
    decoded.byteLength < 32 ||
    decoded.byteLength > 256 ||
    decoded.toString("base64").replace(/=+$/, "") !== value.replace(/=+$/, "")
  ) {
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

function normalizePem(value: string | undefined, component: "grant_signing"): string {
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

function decodeJson(encoded: string, code: string): Record<string, unknown> {
  try {
    const value = JSON.parse(decodeCanonicalBase64url(encoded, undefined, code).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not object");
    return value as Record<string, unknown>;
  } catch {
    throw new IrohInvalidInputError({ code });
  }
}

function decodeCanonicalBase64url(
  encoded: string,
  expectedLength: number | undefined,
  code: string,
): Buffer {
  if (!encoded || !/^[A-Za-z0-9_-]+$/.test(encoded)) {
    throw new IrohInvalidInputError({ code });
  }
  const decoded = Buffer.from(encoded, "base64url");
  if (
    decoded.toString("base64url") !== encoded ||
    (expectedLength !== undefined && decoded.byteLength !== expectedLength)
  ) {
    throw new IrohInvalidInputError({ code });
  }
  return decoded;
}

function signingPrivateKey(value: string | undefined): KeyObject {
  let privateKey: KeyObject;
  try {
    privateKey = createPrivateKey(normalizePem(value, "grant_signing"));
  } catch {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new IrohConfigurationError({ component: "grant_signing" });
  }
  return privateKey;
}

function verificationPublicKey(value: string): KeyObject {
  const canonical = canonicalVerificationKey(value);
  try {
    const publicKey = createPublicKey({
      key: Buffer.from(canonical, "base64"),
      format: "der",
      type: "spki",
    });
    if (publicKey.asymmetricKeyType !== "ed25519") throw new Error("wrong key type");
    return publicKey;
  } catch {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
}

function canonicalVerificationKey(value: string): string {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  const der = Buffer.from(value, "base64");
  if (
    der.byteLength !== ED25519_SPKI_PREFIX.byteLength + 32 ||
    der.toString("base64") !== value ||
    !der.subarray(0, ED25519_SPKI_PREFIX.byteLength).equals(ED25519_SPKI_PREFIX)
  ) {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
  verificationPublicKeyShape(der);
  return value;
}

function verificationPublicKeyShape(der: Buffer): void {
  try {
    const key = createPublicKey({ key: der, format: "der", type: "spki" });
    if (key.asymmetricKeyType !== "ed25519") throw new Error("wrong key type");
  } catch {
    throw new IrohConfigurationError({ component: "grant_verification" });
  }
}

function configurationFailure(): never {
  throw new IrohConfigurationError({ component: "grant_verification" });
}

function hasExactKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(value);
  return keys.length === allowed.length && keys.every((key) => allowed.includes(key));
}

function canonicalSubjectsEqual(left: string, right: string): boolean {
  const leftBytes = decodeCanonicalBase64url(left, 32, "invalid_endpoint_attestation");
  const rightBytes = decodeCanonicalBase64url(right, 32, "invalid_endpoint_attestation");
  return timingSafeEqual(leftBytes, rightBytes);
}

function validateOfflinePairSessionWindow(nowSeconds: number, expiresAtSeconds: number): void {
  if (
    !Number.isSafeInteger(nowSeconds) ||
    !Number.isSafeInteger(expiresAtSeconds) ||
    expiresAtSeconds <= nowSeconds ||
    expiresAtSeconds - nowSeconds > IROH_OFFLINE_PAIR_SESSION_LIFETIME_SECONDS
  ) {
    throw new IrohInvalidInputError({ code: "invalid_offline_pair_session" });
  }
}

function validateEndpointExpectation(
  value: OfflinePairVerificationExpectation["acceptor"],
  platform: "mac" | "ios",
): void {
  if (
    !UUID_PATTERN.test(value.bindingId) ||
    !UUID_PATTERN.test(value.deviceId) ||
    value.platform !== platform ||
    !Number.isSafeInteger(value.identityGeneration) ||
    value.identityGeneration < 1 ||
    value.identityGeneration > POSTGRES_INT32_MAX
  ) {
    throw new IrohInvalidInputError({ code: "invalid_offline_pair_session" });
  }
  endpointId(value.endpointId);
}

function sameEndpointExpectation(
  left: OfflinePairVerificationExpectation["acceptor"],
  right: OfflinePairVerificationExpectation["acceptor"],
): boolean {
  return left.bindingId === right.bindingId &&
    left.deviceId === right.deviceId &&
    left.endpointId === right.endpointId &&
    left.identityGeneration === right.identityGeneration &&
    left.platform === right.platform;
}

function offlinePairProofHash(
  sessionId: string,
  acceptor: OfflinePairVerificationExpectation["acceptor"],
  proof: Uint8Array,
): string {
  return sha256(Buffer.concat([
    Buffer.from(
      `cmux/iroh/offline-pair-session/v1\n${sessionId}\n${acceptor.bindingId}\n${acceptor.deviceId}\n${acceptor.endpointId}\n${acceptor.identityGeneration}\n${acceptor.platform}\n`,
      "utf8",
    ),
    Buffer.from(proof),
  ]));
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
