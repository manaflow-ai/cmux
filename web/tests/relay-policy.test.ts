import { describe, expect, test } from "bun:test";
import {
  generateKeyPairSync,
  verify as edVerify,
} from "node:crypto";

import {
  relayPolicyPayload,
  signRelayPolicy,
} from "../services/relay/catalog";
import {
  assertManagedSelectionExists,
  parseRelayCatalog,
  parseRelayPreferenceUpdate,
  RELAY_POLICY_AUDIENCE,
  RELAY_POLICY_PROTOCOL,
  RELAY_POLICY_TYP,
  type RelayCatalog,
} from "../services/relay/model";
import { assertCatalogAdvance } from "../services/relay/repository";

const catalog: RelayCatalog = {
  version: 1,
  sequence: 17,
  relays: [
    {
      id: "cmux-us-west",
      provider: "cmux",
      region: "us-west",
      url: "https://relay-us-west.cmux.dev/",
    },
    {
      id: "n0-eu-central",
      provider: "n0",
      region: "eu-central",
      url: "https://relay-eu.n0.example/",
    },
  ],
};

describe("signed relay policy", () => {
  test("matches the exact v1 JWS contract and verifies with Ed25519", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const payload = relayPolicyPayload({
      catalog,
      nowSeconds: 1_700_000_000,
      jti: "01890f47-9ff8-7cc2-98b3-2fefdbb4312c",
    });
    const policy = signRelayPolicy({
      payload,
      signingKey: { kid: "relay-policy-2026-07", key: privateKey },
    });
    const [encodedHeader, encodedPayload, encodedSignature] = policy.split(".");
    const header = JSON.parse(Buffer.from(encodedHeader, "base64url").toString());
    const decoded = JSON.parse(Buffer.from(encodedPayload, "base64url").toString());

    expect(header).toEqual({
      alg: "EdDSA",
      typ: RELAY_POLICY_TYP,
      kid: "relay-policy-2026-07",
    });
    expect(Object.keys(decoded).sort()).toEqual([
      "aud",
      "exp",
      "iat",
      "jti",
      "nbf",
      "relay_protocol",
      "relays",
      "sequence",
      "version",
    ]);
    expect(decoded).toEqual({
      version: 1,
      jti: "01890f47-9ff8-7cc2-98b3-2fefdbb4312c",
      sequence: 17,
      iat: 1_700_000_000,
      nbf: 1_700_000_000,
      exp: 1_700_000_300,
      aud: RELAY_POLICY_AUDIENCE,
      relay_protocol: RELAY_POLICY_PROTOCOL,
      relays: catalog.relays,
    });
    expect(edVerify(
      null,
      Buffer.from(`${encodedHeader}.${encodedPayload}`),
      publicKey,
      Buffer.from(encodedSignature, "base64url"),
    )).toBe(true);
  });

  test("requires an explicit server catalog and rejects unsafe or duplicate entries", () => {
    expect(() => parseRelayCatalog(undefined)).toThrow();
    expect(() => parseRelayCatalog(JSON.stringify({
      ...catalog,
      relays: [catalog.relays[0], catalog.relays[0]],
    }))).toThrow();
    expect(parseRelayCatalog(JSON.stringify({
      ...catalog,
      relays: [{
        ...catalog.relays[0],
        region: "US West",
        url: "https://relay-us-west.cmux.dev:8443/",
      }],
    })).relays[0]).toMatchObject({
      region: "US West",
      url: "https://relay-us-west.cmux.dev:8443/",
    });
    expect(() => parseRelayCatalog(JSON.stringify({
      ...catalog,
      relays: [{
        ...catalog.relays[0],
        url: "https://user:secret@relay.cmux.dev/",
      }],
    }))).toThrow();
    expect(() => parseRelayCatalog(JSON.stringify({
      ...catalog,
      relays: [{
        ...catalog.relays[0],
        url: "http://relay.cmux.dev/",
      }],
    }))).toThrow();
    expect(() => parseRelayCatalog(JSON.stringify({
      ...catalog,
      relays: Array.from({ length: 17 }, (_, index) => ({
        id: `relay-${index}`,
        provider: "cmux",
        region: `region-${index}`,
        url: `https://relay-${index}.cmux.dev/`,
      })),
    }))).toThrow();
  });

  test("enforces monotonic catalog sequence and immutable contents per sequence", () => {
    expect(() => assertCatalogAdvance(
      { sequence: 17, digest: "a" },
      { sequence: 17, digest: "a" },
    )).not.toThrow();
    expect(() => assertCatalogAdvance(
      { sequence: 17, digest: "a" },
      { sequence: 18, digest: "b" },
    )).not.toThrow();
    expect(() => assertCatalogAdvance(
      { sequence: 17, digest: "a" },
      { sequence: 16, digest: "a" },
    )).toThrow();
    expect(() => assertCatalogAdvance(
      { sequence: 17, digest: "a" },
      { sequence: 17, digest: "b" },
    )).toThrow();
  });

  test("resolves selected managed IDs only against the verified catalog", () => {
    expect(() => assertManagedSelectionExists({
      mode: "managed",
      selectedManagedRelayIds: ["cmux-us-west"],
    }, catalog)).not.toThrow();
    expect(() => assertManagedSelectionExists({
      mode: "managed",
      selectedManagedRelayIds: ["substituted-relay"],
    }, catalog)).toThrow();
  });

  test("rejects every custom credential field before persistence", () => {
    for (const field of ["token", "auth_token", "authorization", "password", "secret", "apiKey"]) {
      expect(() => parseRelayPreferenceUpdate({
        preference: {
          mode: "custom",
          customRelays: [{
            id: "private-relay",
            provider: "private",
            region: "home",
            url: "https://relay.example.net/",
            authMode: "device_secret",
            [field]: "must-never-reach-the-database",
          }],
        },
      })).toThrow();
    }
  });
});
