import { describe, expect, test } from "bun:test";
import { createHash, createHmac, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import {
  assertCurrentSigningKey,
  createOfflinePairSessionRecord,
  deriveAccountSubject,
  deriveLanRendezvousKey,
  parseVerificationKeys,
  registrationTranscript,
  signEndpointAttestation,
  signPairGrant,
  verifyEndpointAttestation,
  verifyEndpointRegistrationSignature,
  verifyAndConsumeOfflineSameAccountPair,
  verifyPairGrant,
  type EndpointAttestationClaims,
  type PairGrantClaims,
  type PairGrantPeer,
} from "../services/iroh/crypto";
import {
  IrohTrustBrokerConfig,
  type IrohTrustBrokerConfigShape,
} from "../services/iroh/config";
import {
  IROH_ALPN,
  IROH_ENDPOINT_ATTESTATION_SCOPE,
  IROH_ENDPOINT_ATTESTATION_VERSION,
  IROH_PAIR_GRANT_TYP,
  IROH_PAIR_SCOPE,
  MANAGED_RELAY_URLS,
  parseRegistrationPayload,
} from "../services/iroh/model";
import {
  parseMinterHmacSecret,
  parseMinterUrl,
  readBoundedMinterJson,
  IrohRelayMinter,
  IrohRelayMinterLive,
} from "../services/iroh/relayMinter";

const NOW = new Date("2026-07-09T20:00:00.000Z");

describe("Iroh LAN rendezvous derivation", () => {
  test("derives an account-scoped generation key with a server-only HMAC secret", () => {
    const secret = Buffer.alloc(32, 0x4c);
    const encodedSecret = secret.toString("base64");
    const expected = createHmac("sha256", secret)
      .update("cmux/iroh/lan-rendezvous/v1\0", "utf8")
      .update("account-a", "utf8")
      .update("\0", "utf8")
      .update("1", "utf8")
      .digest("base64url");

    expect(deriveLanRendezvousKey(encodedSecret, "account-a", 1)).toBe(expected);
    expect(deriveLanRendezvousKey(encodedSecret, "account-b", 1)).not.toBe(expected);
    expect(deriveLanRendezvousKey(encodedSecret, "account-a", 2)).not.toBe(expected);
    expect(
      deriveLanRendezvousKey(Buffer.alloc(32, 0x4d).toString("base64"), "account-a", 1),
    ).not.toBe(expected);
    expect(() => deriveLanRendezvousKey(Buffer.alloc(31).toString("base64"), "account-a", 1))
      .toThrow();
  });
});

describe("Iroh endpoint registration signatures", () => {
  test("rejects a valid signature encoded with noncanonical padding", () => {
    const keys = generateKeyPairSync("ed25519");
    const endpointId = keys.publicKey
      .export({ format: "der", type: "spki" })
      .subarray(-32)
      .toString("hex");
    const input = {
      endpointId,
      challengeId: "10000000-0000-4000-8000-000000000001",
      nonce: Buffer.alloc(32, 0x42).toString("base64url"),
      payloadSha256: "ab".repeat(32),
    };
    const signature = sign(
      null,
      registrationTranscript(input),
      keys.privateKey,
    ).toString("base64url");

    expect(() => verifyEndpointRegistrationSignature({ ...input, signature })).not.toThrow();
    expect(() => verifyEndpointRegistrationSignature({
      ...input,
      signature: `${signature}=`,
    })).toThrow();
  });
});

function registrationPayload(pathHint: Record<string, unknown>) {
  return {
    route_contract_version: 1,
    deviceId: "10000000-0000-4000-8000-000000000001",
    appInstanceId: "20000000-0000-4000-8000-000000000001",
    tag: "stable",
    platform: "mac",
    endpointId: "11".repeat(32),
    identityGeneration: 1,
    pairingEnabled: true,
    capabilities: ["terminal", "artifacts"],
    pathHints: [pathHint],
  };
}

function directHint(overrides: Record<string, unknown> = {}) {
  return {
    kind: "direct_address",
    value: "203.0.113.42:4433",
    source: "native",
    privacy_scope: "public_internet",
    observed_at: "2026-07-09T19:55:00.000Z",
    expires_at: "2026-07-09T20:45:00.000Z",
    ...overrides,
  };
}

describe("Iroh route wire contract", () => {
  test("matches the versioned Swift Codable path-hint shape", () => {
    const fixture = JSON.parse(readFileSync(
      new URL("../../tests/fixtures/iroh/path-hint-v1.json", import.meta.url),
      "utf8",
    )) as Record<string, unknown>;
    const parsed = parseRegistrationPayload(registrationPayload(fixture), NOW);
    expect(parsed.route_contract_version).toBe(1);
    expect(parsed.pathHints).toEqual([fixture]);
    expect(Object.keys(parsed.pathHints[0]!).sort()).toEqual([
      "expires_at",
      "kind",
      "observed_at",
      "privacy_scope",
      "source",
      "value",
    ]);
  });

  test("accepts provider-qualified private hints", () => {
    const hint = directHint({
      value: "100.64.10.12:4433",
      source: "tailscale",
      privacy_scope: "private_network",
      network_profile: { source: "tailscale", profile_id: "tailnet-prod" },
    });
    expect(parseRegistrationPayload(registrationPayload(hint), NOW).pathHints[0]).toEqual(hint);
  });

  test("accepts independent IPv4 and IPv6 UDP ports while preserving legacy omission", () => {
    const safeDirectHint = directHint({ value: "8.8.8.8:4433" });
    const legacy = parseRegistrationPayload(registrationPayload(safeDirectHint), NOW);
    expect("directPorts" in legacy).toBe(false);

    for (const directPorts of [
      { ipv4: 49_152 },
      { ipv6: 49_153 },
      { ipv4: 49_152, ipv6: 49_153 },
    ]) {
      const parsed = parseRegistrationPayload({
        ...registrationPayload(safeDirectHint),
        directPorts,
      }, NOW) as unknown as { directPorts?: unknown };
      expect(parsed.directPorts).toEqual(directPorts);
    }
  });

  for (const directPorts of [
    {},
    { ipv4: 0 },
    { ipv4: 65_536 },
    { ipv4: 4_433.5 },
    { ipv6: 0 },
    { ipv6: 65_536 },
    { ipv6: 4_433.5 },
    { ipv4: 4_433, extra: 4_434 },
  ]) {
    test(`rejects invalid direct ports ${JSON.stringify(directPorts)}`, () => {
      expect(() => parseRegistrationPayload({
        ...registrationPayload(directHint({ value: "8.8.8.8:4433" })),
        directPorts,
      }, NOW)).toThrow();
    });
  }

  test("allows globally routed address space inside an explicit custom VPN profile", () => {
    const hint = directHint({
      value: "8.8.4.4:4433",
      source: "custom_vpn",
      privacy_scope: "private_network",
      network_profile: { source: "custom_vpn", profile_id: "corp-routes" },
    });
    expect(parseRegistrationPayload(registrationPayload(hint), NOW).pathHints[0]).toEqual(hint);
  });

  test("canonicalizes accepted IPv6 spellings", () => {
    const hint = directHint({
      value: "[FD00:0000:0000:0000:0000:0000:0000:0001]:4433",
      source: "tailscale",
      privacy_scope: "private_network",
      network_profile: { source: "tailscale", profile_id: "tailnet-prod" },
    });
    expect(parseRegistrationPayload(registrationPayload(hint), NOW).pathHints[0]?.value).toBe("[fd00::1]:4433");
  });

  test("rejects an unknown platform before it can affect Mac pairability", () => {
    expect(() => parseRegistrationPayload({
      ...registrationPayload(directHint({ value: "8.8.8.8:4433" })),
      platform: "linux",
    }, NOW)).toThrow();
  });

  test("rejects identity generations that overflow the Postgres integer contract", () => {
    expect(() => parseRegistrationPayload({
      ...registrationPayload(directHint({ value: "8.8.8.8:4433" })),
      identityGeneration: 2_147_483_648,
    }, NOW)).toThrow();
  });

  test("accepts bounded canonical relay candidates before account authorization", () => {
    const relayHint = directHint({ kind: "relay_url", value: MANAGED_RELAY_URLS[0] });
    expect(parseRegistrationPayload(registrationPayload(relayHint), NOW).pathHints[0]?.value).toBe(MANAGED_RELAY_URLS[0]);
    const customHint = directHint({ kind: "relay_url", value: "https://relay.example.net/" });
    expect(parseRegistrationPayload(registrationPayload(customHint), NOW).pathHints[0]?.value)
      .toBe("https://relay.example.net/");
    const payload = registrationPayload(relayHint);
    payload.pathHints = MANAGED_RELAY_URLS.slice(0, 3).map((value) => directHint({ kind: "relay_url", value }));
    expect(() => parseRegistrationPayload(payload, NOW)).toThrow();
  });

  for (const [name, hint] of [
    ["RFC1918 advertised as public", directHint({ value: "10.0.0.1:4433" })],
    ["ULA advertised as public", directHint({ value: "[fd00::1]:4433" })],
    ["loopback", directHint({ value: "127.0.0.1:4433" })],
    ["multicast", directHint({ value: "224.0.0.1:4433" })],
    ["cloud metadata", directHint({ value: "169.254.169.254:4433", source: "lan", privacy_scope: "local_network", network_profile: { source: "lan", profile_id: "local" } })],
    ["IPv6 link-local", directHint({ value: "[fe80::1]:4433", source: "lan", privacy_scope: "local_network", network_profile: { source: "lan", profile_id: "local" } })],
    ["IPv6 remote interface scope", directHint({ value: "[2001:4860::1%en0]:4433" })],
    ["alternate-spelling IPv6 documentation range", directHint({ value: "[2001:0db8::1]:4433" })],
    ["IPv4 leading zero", directHint({ value: "8.8.08.8:4433" })],
    ["port leading zero", directHint({ value: "8.8.8.8:04433" })],
    ["LAN marked private", directHint({ value: "192.168.1.2:4433", source: "lan", privacy_scope: "private_network", network_profile: { source: "lan", profile_id: "local" } })],
    ["Tailscale marked local", directHint({ value: "100.64.1.2:4433", source: "tailscale", privacy_scope: "local_network", network_profile: { source: "tailscale", profile_id: "ts" } })],
    ["stale observation", directHint({ value: "8.8.8.8:4433", observed_at: "2026-07-09T18:00:00.000Z" })],
    ["overlong lifetime", directHint({ value: "8.8.8.8:4433", observed_at: "2026-07-09T19:55:00.000Z", expires_at: "2026-07-09T21:00:01.000Z" })],
    ["credential-bearing relay", directHint({ kind: "relay_url", value: "https://user:secret@example.com/" })],
  ] as const) {
    test(`rejects ${name}`, () => {
      expect(() => parseRegistrationPayload(registrationPayload(hint), NOW)).toThrow();
    });
  }
});

describe("Iroh pair-grant verification", () => {
  const current = generateKeyPairSync("ed25519");
  const previous = generateKeyPairSync("ed25519");
  const currentPrivate = current.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const previousPrivate = previous.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const currentPublic = current.publicKey.export({ format: "der", type: "spki" }).toString("base64");
  const previousPublic = previous.publicKey.export({ format: "der", type: "spki" }).toString("base64");
  const keys = new Map([
    ["current", currentPublic],
    ["previous", previousPublic],
  ]);
  const initiator: PairGrantPeer = {
    bindingId: "30000000-0000-4000-8000-000000000001",
    deviceId: "10000000-0000-4000-8000-000000000001",
    tag: "ios",
    platform: "ios",
    endpointId: "22".repeat(32),
    identityGeneration: 2,
  };
  const acceptor: PairGrantPeer = {
    bindingId: "30000000-0000-4000-8000-000000000002",
    deviceId: "10000000-0000-4000-8000-000000000002",
    tag: "stable",
    platform: "mac",
    endpointId: "33".repeat(32),
    identityGeneration: 4,
  };
  const claims: PairGrantClaims = {
    jti: "40000000-0000-4000-8000-000000000001",
    iat: 1_783_627_200,
    nbf: 1_783_627_195,
    exp: 1_784_232_000,
    alpn: IROH_ALPN,
    scope: IROH_PAIR_SCOPE,
    initiator,
    acceptor,
  };

  test("accepts the current key while retaining a previous verification key", () => {
    const token = signPairGrant({ privateKeyPem: currentPrivate, kid: "current", claims });
    expect(verifyPairGrant(token, keys, { initiator, acceptor, nowSeconds: claims.iat }).jti).toBe(claims.jti);
    const previousToken = signPairGrant({ privateKeyPem: previousPrivate, kid: "previous", claims });
    expect(verifyPairGrant(previousToken, keys, {
      initiator,
      acceptor,
      nowSeconds: claims.iat,
    }).jti).toBe(claims.jti);
  });

  test("rejects peer and identity-generation substitution", () => {
    const token = signPairGrant({ privateKeyPem: currentPrivate, kid: "current", claims });
    expect(() => verifyPairGrant(token, keys, {
      initiator: { ...initiator, identityGeneration: 3 },
      acceptor,
      nowSeconds: claims.iat,
    })).toThrow();
    expect(() => verifyPairGrant(token, keys, {
      initiator: { ...initiator, endpointId: "44".repeat(32) },
      acceptor,
      nowSeconds: claims.iat,
    })).toThrow();
  });

  test("rejects grants whose peers claim the same physical device", () => {
    const sameDeviceClaims = {
      ...claims,
      acceptor: { ...acceptor, deviceId: initiator.deviceId },
    };
    const token = manuallySignedJws(
      { alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid: "current" },
      sameDeviceClaims,
      current.privateKey,
    );

    expect(() => verifyPairGrant(token, keys, {
      initiator,
      acceptor: sameDeviceClaims.acceptor,
      nowSeconds: claims.iat,
    })).toThrow();
  });

  test("rejects identity or team claims outside the fixed grant contract", () => {
    const token = manuallySignedJws(
      { alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid: "current" },
      { ...claims, userId: "must-not-appear" },
      current.privateKey,
    );
    expect(() => verifyPairGrant(token, keys, { initiator, acceptor, nowSeconds: claims.iat })).toThrow();
  });

  test("rejects a noncanonical signature segment", () => {
    const token = signPairGrant({ privateKeyPem: currentPrivate, kid: "current", claims });
    expect(() => verifyPairGrant(`${token}!`, keys, {
      initiator,
      acceptor,
      nowSeconds: claims.iat,
    })).toThrow();
  });

  for (const [name, header, changedClaims, nowSeconds] of [
    ["alg", { alg: "ES256", typ: IROH_PAIR_GRANT_TYP, kid: "current" }, claims, claims.iat],
    ["kid", { alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid: "unknown" }, claims, claims.iat],
    ["ALPN", { alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid: "current" }, { ...claims, alpn: "cmux/other/1" }, claims.iat],
    ["platform direction", { alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid: "current" }, { ...claims, initiator: { ...claims.initiator, platform: "mac" } }, claims.iat],
    ["expiry", { alg: "EdDSA", typ: IROH_PAIR_GRANT_TYP, kid: "current" }, claims, claims.exp],
  ] as const) {
    test(`rejects invalid ${name}`, () => {
      const token = manuallySignedJws(header, changedClaims, current.privateKey);
      expect(() => verifyPairGrant(token, keys, { initiator, acceptor, nowSeconds })).toThrow();
    });
  }
});

describe("Iroh grant verification keys and offline endpoint attestations", () => {
  const current = generateKeyPairSync("ed25519");
  const previous = generateKeyPairSync("ed25519");
  const currentPrivate = current.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const currentPublic = current.publicKey.export({ format: "der", type: "spki" }).toString("base64");
  const previousPublic = previous.publicKey.export({ format: "der", type: "spki" }).toString("base64");
  const parsedKeys = parseVerificationKeys(JSON.stringify({
    version: 1,
    current_kid: "current",
    keys: [
      { kid: "previous", alg: "EdDSA", spki_der_base64: previousPublic },
      { kid: "current", alg: "EdDSA", spki_der_base64: currentPublic },
    ],
  }));
  const nowSeconds = 1_783_627_200;
  const subject = deriveAccountSubject(Buffer.alloc(32, 0x51).toString("base64"), "private-user-id");
  const initiator: EndpointAttestationClaims = {
    version: IROH_ENDPOINT_ATTESTATION_VERSION,
    jti: "40000000-0000-4000-8000-000000000011",
    sub: subject,
    bindingId: "30000000-0000-4000-8000-000000000011",
    deviceId: "10000000-0000-4000-8000-000000000011",
    endpointId: "44".repeat(32),
    identityGeneration: 2,
    platform: "ios",
    iat: nowSeconds,
    nbf: nowSeconds - 5,
    exp: nowSeconds + 86_400,
    alpn: IROH_ALPN,
    scope: IROH_ENDPOINT_ATTESTATION_SCOPE,
  };
  const acceptor: EndpointAttestationClaims = {
    ...initiator,
    jti: "40000000-0000-4000-8000-000000000012",
    bindingId: "30000000-0000-4000-8000-000000000012",
    deviceId: "10000000-0000-4000-8000-000000000012",
    endpointId: "55".repeat(32),
    identityGeneration: 3,
    platform: "mac",
  };

  test("publishes only canonical current and previous public keys and binds the signer", () => {
    expect(parsedKeys.keySet).toEqual({
      version: 1,
      current_kid: "current",
      keys: [
        { kid: "current", alg: "EdDSA", spki_der_base64: currentPublic },
        { kid: "previous", alg: "EdDSA", spki_der_base64: previousPublic },
      ],
    });
    expect(JSON.stringify(parsedKeys.keySet)).not.toContain("PRIVATE KEY");
    expect(() => assertCurrentSigningKey({
      privateKeyPem: currentPrivate,
      kid: "current",
      verificationKeys: parsedKeys,
    })).not.toThrow();
    expect(() => assertCurrentSigningKey({
      privateKeyPem: previous.privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
      kid: "current",
      verificationKeys: parsedKeys,
    })).toThrow();
  });

  test("supports prepublish, signer flip, and delayed old-key retirement", () => {
    const oldPrivate = previous.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
    const prepublished = parseVerificationKeys(JSON.stringify({
      version: 1,
      current_kid: "old",
      keys: [
        { kid: "old", alg: "EdDSA", spki_der_base64: previousPublic },
        { kid: "next", alg: "EdDSA", spki_der_base64: currentPublic },
      ],
    }));
    expect(() => assertCurrentSigningKey({
      privateKeyPem: oldPrivate,
      kid: "old",
      verificationKeys: prepublished,
    })).not.toThrow();
    const oldToken = signEndpointAttestation({
      privateKeyPem: oldPrivate,
      kid: "old",
      claims: initiator,
    });

    const flipped = parseVerificationKeys(JSON.stringify({
      version: 1,
      current_kid: "next",
      keys: [
        { kid: "next", alg: "EdDSA", spki_der_base64: currentPublic },
        { kid: "old", alg: "EdDSA", spki_der_base64: previousPublic },
      ],
    }));
    expect(() => assertCurrentSigningKey({
      privateKeyPem: currentPrivate,
      kid: "next",
      verificationKeys: flipped,
    })).not.toThrow();
    expect(verifyEndpointAttestation(
      oldToken,
      flipped.publicKeys,
      { ...endpointExpectation(initiator), nowSeconds },
    ).jti).toBe(initiator.jti);

    const retired = parseVerificationKeys(JSON.stringify({
      version: 1,
      current_kid: "next",
      keys: [{ kid: "next", alg: "EdDSA", spki_der_base64: currentPublic }],
    }));
    expect(() => verifyEndpointAttestation(
      oldToken,
      retired.publicKeys,
      { ...endpointExpectation(initiator), nowSeconds },
    )).toThrow();
  });

  test("requires two fresh endpoint-bound attestations with the same opaque account subject", () => {
    const initiatorToken = signEndpointAttestation({
      privateKeyPem: currentPrivate,
      kid: "current",
      claims: initiator,
    });
    const acceptorToken = signEndpointAttestation({
      privateKeyPem: currentPrivate,
      kid: "current",
      claims: acceptor,
    });
    const expected = {
      initiator: { ...endpointExpectation(initiator), platform: "ios" as const },
      acceptor: { ...endpointExpectation(acceptor), platform: "mac" as const },
      nowSeconds,
    } as const;
    const proof = Buffer.alloc(32, 0x61).toString("base64url");
    const session = createOfflinePairSessionRecord({
      sessionId: "70000000-0000-4000-8000-000000000001",
      proof,
      acceptor: expected.acceptor,
      nowSeconds,
      expiresAtSeconds: nowSeconds + 300,
    });
    const invitation = { version: 1 as const, sessionId: session.sessionId, proof };

    expect(verifyAndConsumeOfflineSameAccountPair({
      initiatorAttestation: initiatorToken,
      acceptorAttestation: acceptorToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
      session,
      invitation,
    }).acceptor.endpointId).toBe(acceptor.endpointId);
    expect(session.consumedAtSeconds).toBe(nowSeconds);
    expect(() => verifyAndConsumeOfflineSameAccountPair({
      initiatorAttestation: initiatorToken,
      acceptorAttestation: acceptorToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
      session,
      invitation,
    })).toThrow();

    const missingSession = createOfflinePairSessionRecord({
      sessionId: "70000000-0000-4000-8000-000000000002",
      proof,
      acceptor: expected.acceptor,
      nowSeconds,
      expiresAtSeconds: nowSeconds + 300,
    });
    expect(() => verifyAndConsumeOfflineSameAccountPair({
      initiatorAttestation: "",
      acceptorAttestation: acceptorToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
      session: missingSession,
      invitation: { ...invitation, sessionId: missingSession.sessionId },
    })).toThrow();
    expect(missingSession.consumedAtSeconds).toBeNull();

    const wrongProofSession = createOfflinePairSessionRecord({
      sessionId: "70000000-0000-4000-8000-000000000004",
      proof,
      acceptor: expected.acceptor,
      nowSeconds,
      expiresAtSeconds: nowSeconds + 300,
    });
    expect(() => verifyAndConsumeOfflineSameAccountPair({
      initiatorAttestation: initiatorToken,
      acceptorAttestation: acceptorToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
      session: wrongProofSession,
      invitation: {
        version: 1,
        sessionId: wrongProofSession.sessionId,
        proof: Buffer.alloc(32, 0x62).toString("base64url"),
      },
    })).toThrow();
    expect(wrongProofSession.consumedAtSeconds).toBeNull();

    const otherAccountToken = signEndpointAttestation({
      privateKeyPem: currentPrivate,
      kid: "current",
      claims: { ...acceptor, sub: Buffer.alloc(32, 0x52).toString("base64url") },
    });
    const mismatchSession = createOfflinePairSessionRecord({
      sessionId: "70000000-0000-4000-8000-000000000003",
      proof,
      acceptor: expected.acceptor,
      nowSeconds,
      expiresAtSeconds: nowSeconds + 300,
    });
    expect(() => verifyAndConsumeOfflineSameAccountPair({
      initiatorAttestation: initiatorToken,
      acceptorAttestation: otherAccountToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
      session: mismatchSession,
      invitation: { ...invitation, sessionId: mismatchSession.sessionId },
    })).toThrow();
    expect(mismatchSession.consumedAtSeconds).toBeNull();
  });

  test("rejects endpoint substitution, expiry, extra identity claims, and noncanonical signatures", () => {
    const token = signEndpointAttestation({
      privateKeyPem: currentPrivate,
      kid: "current",
      claims: initiator,
    });
    expect(() => verifyEndpointAttestation(token, parsedKeys.publicKeys, {
      ...endpointExpectation(initiator),
      endpointId: "66".repeat(32),
      nowSeconds,
    })).toThrow();
    expect(() => verifyEndpointAttestation(token, parsedKeys.publicKeys, {
      ...endpointExpectation(initiator),
      nowSeconds: initiator.exp,
    })).toThrow();
    expect(() => verifyEndpointAttestation(`${token}!`, parsedKeys.publicKeys, {
      ...endpointExpectation(initiator),
      nowSeconds,
    })).toThrow();
    const tokenWithRawIdentity = manuallySignedJws(
      { alg: "EdDSA", typ: "cmux-endpoint-attestation-v1+jwt", kid: "current" },
      { ...initiator, userId: "must-not-appear" },
      current.privateKey,
    );
    expect(() => verifyEndpointAttestation(tokenWithRawIdentity, parsedKeys.publicKeys, {
      ...endpointExpectation(initiator),
      nowSeconds,
    })).toThrow();
  });

  test("rejects malformed, oversized, duplicate, and signer-misaligned key sets", () => {
    expect(() => parseVerificationKeys(undefined)).toThrow();
    expect(() => parseVerificationKeys(JSON.stringify({ current: currentPublic }))).toThrow();
    expect(() => parseVerificationKeys(JSON.stringify({
      version: 1,
      current_kid: "current",
      keys: [
        { kid: "current", alg: "EdDSA", spki_der_base64: currentPublic },
        { kid: "current", alg: "EdDSA", spki_der_base64: currentPublic },
      ],
    }))).toThrow();
    expect(() => parseVerificationKeys(JSON.stringify({
      version: 1,
      current_kid: "missing",
      keys: [{ kid: "current", alg: "EdDSA", spki_der_base64: currentPublic }],
    }))).toThrow();
    expect(() => parseVerificationKeys("x".repeat(32_769))).toThrow();
  });
});

describe("Iroh relay minter response bounds", () => {
  test("the production Live layer sends the canonical fetch body and HMAC", async () => {
    const secret = Buffer.alloc(32, 0x63);
    const originalFetch = globalThis.fetch;
    let captured: { url: string; init: RequestInit } | undefined;
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      captured = { url: String(input), init: init ?? {} };
      return new Response(JSON.stringify({
        token: "a".repeat(64),
        expiresAt: "2026-07-10T20:00:00.000Z",
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    try {
      const config: IrohTrustBrokerConfigShape = {
        relayMinterUrl: "https://minter.cmux.test/api/relay-token",
        relayMinterHmacSecretBase64: secret.toString("base64"),
        relayMinterInsecureLoopbackOptIn: false,
        deviceLimitOverrideEnabled: false,
        developmentAccountBindingLimit: 256,
        developmentDeviceBindingLimit: 128,
        deviceLimitOverrideUserIds: new Set(),
        deviceLimitOverrideEnvironments: new Set(),
        deploymentEnvironment: "test",
        isVercelDeployment: false,
      };
      const layer = IrohRelayMinterLive.pipe(
        Layer.provide(Layer.succeed(IrohTrustBrokerConfig, config)),
      );
      const result = await Effect.runPromise(
        Effect.gen(function* () {
          const minter = yield* IrohRelayMinter;
          return yield* minter.mint({
            endpointId: "ab".repeat(32),
            lifetimeSeconds: 86_400,
            now: NOW,
          });
        }).pipe(Effect.provide(layer)),
      );
      expect(result.token).toBe("a".repeat(64));
    } finally {
      globalThis.fetch = originalFetch;
    }

    const request = captured;
    expect(request?.url).toBe("https://minter.cmux.test/api/relay-token");
    expect(request?.init.method).toBe("POST");
    expect(request?.init.redirect).toBe("error");
    const body = JSON.stringify({ endpointId: "ab".repeat(32), lifetimeSeconds: 86_400 });
    expect(request?.init.body).toBe(body);
    const timestamp = String(Math.floor(NOW.getTime() / 1_000));
    const expectedSignature = createHmac("sha256", secret)
      .update(`POST\n/api/relay-token\n${timestamp}\n${createHash("sha256").update(body).digest("hex")}`)
      .digest("base64url");
    expect(new Headers(request?.init.headers).get("x-cmux-iroh-timestamp")).toBe(timestamp);
    expect(new Headers(request?.init.headers).get("x-cmux-iroh-signature")).toBe(expectedSignature);
    expect(new Headers(request?.init.headers).get("content-type")).toBe("application/json");
  });

  test("preserves an invalid EndpointID as an input error", async () => {
    const config: IrohTrustBrokerConfigShape = {
      relayMinterUrl: "https://minter.cmux.test/api/relay-token",
      relayMinterHmacSecretBase64: Buffer.alloc(32, 0x63).toString("base64"),
      relayMinterInsecureLoopbackOptIn: false,
      deviceLimitOverrideEnabled: false,
      developmentAccountBindingLimit: 256,
      developmentDeviceBindingLimit: 128,
      deviceLimitOverrideUserIds: new Set(),
      deviceLimitOverrideEnvironments: new Set(),
      deploymentEnvironment: "test",
      isVercelDeployment: false,
    };
    const layer = IrohRelayMinterLive.pipe(
      Layer.provide(Layer.succeed(IrohTrustBrokerConfig, config)),
    );
    const exit = await Effect.runPromiseExit(
      Effect.gen(function* () {
        const minter = yield* IrohRelayMinter;
        return yield* minter.mint({
          endpointId: "not-an-endpoint-id",
          lifetimeSeconds: 86_400,
          now: NOW,
        });
      }).pipe(Effect.provide(layer)),
    );

    expect(exit._tag).toBe("Failure");
    const failure = exit._tag === "Failure"
      ? Option.getOrUndefined(Cause.failureOption(exit.cause))
      : undefined;
    expect((failure as { _tag?: string } | undefined)?._tag).toBe("IrohInvalidInputError");
  });

  test("matches the Rust minter HMAC wire fixture", () => {
    const fixture = JSON.parse(readFileSync(
      new URL("../../tests/fixtures/iroh/relay-minter-request-v1.json", import.meta.url),
      "utf8",
    )) as { path: string; timestamp: string; body: string; signature: string };
    const bodyHash = createHash("sha256").update(fixture.body).digest("hex");
    const signature = createHmac("sha256", Buffer.alloc(32, 0x42))
      .update(`POST\n${fixture.path}\n${fixture.timestamp}\n${bodyHash}`, "utf8")
      .digest("base64url");
    expect(fixture.path).toBe("/api/relay-token");
    expect(signature).toBe(fixture.signature);
  });

  test("requires a canonical 32-byte-or-longer HMAC secret", () => {
    const valid = Buffer.alloc(32, 9).toString("base64");
    expect(parseMinterHmacSecret(valid)).toEqual(Buffer.alloc(32, 9));
    expect(() => parseMinterHmacSecret("%%%%" + valid)).toThrow();
    expect(() => parseMinterHmacSecret(Buffer.alloc(16, 9).toString("base64"))).toThrow();
    expect(() => parseMinterHmacSecret(Buffer.alloc(257, 9).toString("base64"))).toThrow();
    expect(() => parseMinterHmacSecret(Buffer.alloc(32, 0xff).toString("base64url"))).toThrow();
  });

  test("allows plaintext only for opted-in local loopback minters", () => {
    const localDevelopment = {
      allowInsecureLoopback: true,
      deploymentEnvironment: "development",
      isVercelDeployment: false,
    };
    expect(parseMinterUrl("https://minter.cmux.test/api/relay-token").pathname).toBe("/api/relay-token");
    for (const value of [
      "http://localhost:49152/api/relay-token",
      "http://127.0.0.1:49152/api/relay-token",
      "http://[::1]:49152/api/relay-token",
    ]) {
      expect(parseMinterUrl(value, localDevelopment).protocol).toBe("http:");
    }
    for (const value of [
      "http://minter.cmux.test/api/relay-token",
      "http://192.168.1.10:49152/api/relay-token",
      "https://minter.cmux.test/api/relay-token/",
      "https://minter.cmux.test/other",
      "https://minter.cmux.test/api/relay-token?debug=1",
    ]) {
      expect(() => parseMinterUrl(value, localDevelopment)).toThrow();
    }
    expect(() => parseMinterUrl("http://localhost:49152/api/relay-token", {
      ...localDevelopment,
      allowInsecureLoopback: false,
    })).toThrow();
    expect(() => parseMinterUrl("http://localhost:49152/api/relay-token", {
      ...localDevelopment,
      deploymentEnvironment: "production",
    })).toThrow();
    expect(() => parseMinterUrl("http://localhost:49152/api/relay-token", {
      ...localDevelopment,
      deploymentEnvironment: "preview",
      isVercelDeployment: true,
    })).toThrow();
  });

  test("parses a bounded response", async () => {
    const body = { token: "a".repeat(32), expiresAt: "2026-07-10T20:00:00.000Z" };
    expect(await readBoundedMinterJson(new Response(JSON.stringify(body), {
      headers: { "content-type": "application/json" },
    }))).toEqual(body);
  });

  test("rejects a non-JSON or expanded minter response contract", async () => {
    await expect(readBoundedMinterJson(new Response("{}"))).rejects.toThrow();
    await expect(readBoundedMinterJson(new Response(JSON.stringify({
      token: "a".repeat(32),
      expiresAt: "2026-07-10T20:00:00.000Z",
      servicesSecret: "must-not-appear",
    }), {
      headers: { "content-type": "application/json" },
    }))).rejects.toThrow();
  });

  test("rejects oversized fixed-length and chunked responses", async () => {
    await expect(readBoundedMinterJson(new Response("{}", {
      headers: { "content-length": "999999", "content-type": "application/json" },
    }))).rejects.toThrow();

    const chunk = new Uint8Array(20_000);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(chunk);
        controller.enqueue(chunk);
        controller.close();
      },
    });
    await expect(readBoundedMinterJson(new Response(stream, {
      headers: { "content-type": "application/json" },
    }))).rejects.toThrow();
  });
});

function manuallySignedJws(header: unknown, claims: unknown, privateKey: CryptoKey | import("node:crypto").KeyObject): string {
  const encodedHeader = Buffer.from(JSON.stringify(header)).toString("base64url");
  const encodedClaims = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const input = `${encodedHeader}.${encodedClaims}`;
  const signature = sign(null, Buffer.from(input), privateKey as import("node:crypto").KeyObject).toString("base64url");
  return `${input}.${signature}`;
}

function endpointExpectation(claims: EndpointAttestationClaims) {
  return {
    bindingId: claims.bindingId,
    deviceId: claims.deviceId,
    endpointId: claims.endpointId,
    identityGeneration: claims.identityGeneration,
    platform: claims.platform,
  };
}
