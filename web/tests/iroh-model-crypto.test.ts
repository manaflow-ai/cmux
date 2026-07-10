import { describe, expect, test } from "bun:test";
import { createHash, createHmac, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  assertCurrentSigningKey,
  deriveAccountSubject,
  parseVerificationKeys,
  signEndpointAttestation,
  signPairGrant,
  verifyEndpointAttestation,
  verifyOfflineSameAccountPair,
  verifyPairGrant,
  type EndpointAttestationClaims,
  type PairGrantClaims,
  type PairGrantPeer,
} from "../services/iroh/crypto";
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
} from "../services/iroh/relayMinter";

const NOW = new Date("2026-07-09T20:00:00.000Z");

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

  test("accepts only endpoint-reported home relays from the separate fleet allowlist", () => {
    const relayHint = directHint({ kind: "relay_url", value: MANAGED_RELAY_URLS[0] });
    expect(parseRegistrationPayload(registrationPayload(relayHint), NOW).pathHints[0]?.value).toBe(MANAGED_RELAY_URLS[0]);
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
    ["unmanaged relay", directHint({ kind: "relay_url", value: "https://example.com/" })],
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
    endpointId: "22".repeat(32),
    identityGeneration: 2,
  };
  const acceptor: PairGrantPeer = {
    bindingId: "30000000-0000-4000-8000-000000000002",
    deviceId: "10000000-0000-4000-8000-000000000002",
    tag: "stable",
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

    expect(verifyOfflineSameAccountPair({
      initiatorAttestation: initiatorToken,
      acceptorAttestation: acceptorToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
    }).acceptor.endpointId).toBe(acceptor.endpointId);
    expect(() => verifyOfflineSameAccountPair({
      initiatorAttestation: "",
      acceptorAttestation: acceptorToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
    })).toThrow();

    const otherAccountToken = signEndpointAttestation({
      privateKeyPem: currentPrivate,
      kid: "current",
      claims: { ...acceptor, sub: Buffer.alloc(32, 0x52).toString("base64url") },
    });
    expect(() => verifyOfflineSameAccountPair({
      initiatorAttestation: initiatorToken,
      acceptorAttestation: otherAccountToken,
      publicKeys: parsedKeys.publicKeys,
      expected,
    })).toThrow();
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

  test("requires HTTPS and the exact isolated minter route", () => {
    expect(parseMinterUrl("https://minter.cmux.test/api/relay-token").pathname).toBe("/api/relay-token");
    for (const value of [
      "http://minter.cmux.test/api/relay-token",
      "https://minter.cmux.test/api/relay-token/",
      "https://minter.cmux.test/other",
      "https://minter.cmux.test/api/relay-token?debug=1",
    ]) {
      expect(() => parseMinterUrl(value)).toThrow();
    }
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
