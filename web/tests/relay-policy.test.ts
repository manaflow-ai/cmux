import { describe, expect, test } from "bun:test";
import {
  generateKeyPairSync,
  verify as edVerify,
} from "node:crypto";

import {
  RELAY_ROTATION_MIN_OVERLAP_SECONDS,
  assertSafeRelayCatalogRotation,
  configuredRelayCatalog,
  relayCatalogDigest,
  relayPolicyPayload,
  relayPolicySigningKey,
  signRelayPolicy,
} from "../services/relay/catalog";
import { RelayCatalogIntegrityError } from "../services/relay/errors";
import { relayErrorResponse } from "../services/relay/http";
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
import {
  MANAGED_RELAY_CATALOG_SEQUENCE,
  MANAGED_RELAY_URLS,
} from "../services/iroh/publicationPolicy";
import {
  APPROVED_IROH_RELAY_CATALOG,
  APPROVED_IROH_RELAY_CATALOG_SEQUENCE,
  APPROVED_IROH_RELAY_URLS,
} from "../../workers/presence/src/routePrivacy";

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
  test("uses a canonical catalog digest across JSON object key order", () => {
    const reordered = {
      relays: catalog.relays.map((relay) => ({
        url: relay.url,
        region: relay.region,
        provider: relay.provider,
        id: relay.id,
      })),
      sequence: catalog.sequence,
      version: catalog.version,
    } as RelayCatalog;

    expect(relayCatalogDigest(reordered)).toBe(relayCatalogDigest(catalog));
  });

  test("logs a safe reason when persisted catalog integrity fails", async () => {
    const originalConsoleError = console.error;
    const calls: unknown[][] = [];
    console.error = (...args: unknown[]) => { calls.push(args); };
    try {
      const response = relayErrorResponse(new RelayCatalogIntegrityError({
        reason: "persisted_catalog_digest_mismatch",
      }));

      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "relay_policy_unavailable" });
      expect(calls).toEqual([[
        "relay.policy.catalog_integrity",
        { reason: "persisted_catalog_digest_mismatch" },
      ]]);
    } finally {
      console.error = originalConsoleError;
    }
  });

  test("never logs unexpected relay policy error contents", async () => {
    const originalConsoleError = console.error;
    const calls: unknown[][] = [];
    console.error = (...args: unknown[]) => { calls.push(args); };
    try {
      const response = relayErrorResponse(new Error(
        "token=secret-token url=https://private-relay.example database=postgres://secret",
      ));

      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "internal_error" });
      expect(calls).toEqual([[
        "relay.policy.unexpected",
        { failure: "unexpected" },
      ]]);
    } finally {
      console.error = originalConsoleError;
    }
  });

  test("keeps signed policy, web publication, and Presence on one catalog digest", () => {
    const configured = configuredRelayCatalog();
    const presence = parseRelayCatalog(JSON.stringify(APPROVED_IROH_RELAY_CATALOG));
    const policy = relayPolicyPayload({
      catalog: configured,
      nowSeconds: 1_700_000_000,
      jti: "01890f47-9ff8-7cc2-98b3-2fefdbb4312c",
    });

    expect(relayCatalogDigest(configured)).toBe(relayCatalogDigest(presence));
    expect(configured.sequence).toBe(MANAGED_RELAY_CATALOG_SEQUENCE);
    expect(configured.sequence).toBe(APPROVED_IROH_RELAY_CATALOG_SEQUENCE);
    expect(configured.relays.map((relay) => relay.url)).toEqual(MANAGED_RELAY_URLS);
    expect(configured.relays.map((relay) => relay.url)).toEqual(APPROVED_IROH_RELAY_URLS);
    expect(policy.relays).toEqual(configured.relays);
  });

  test("enforces add-before-remove rotation and one-policy-lifetime overlap", () => {
    const current = configuredRelayCatalog();
    const added = parseRelayCatalog(JSON.stringify({
      ...current,
      sequence: current.sequence + 1,
      relays: [
        ...current.relays,
        {
          id: "cmux-rotation",
          provider: "cmux",
          region: "rotation",
          url: "https://rotation.relay.cmux.dev/",
        },
      ],
    }));
    expect(() => assertSafeRelayCatalogRotation({ current, next: added })).not.toThrow();

    const replacedInOneStep = parseRelayCatalog(JSON.stringify({
      ...added,
      sequence: added.sequence + 1,
      relays: [
        ...added.relays.slice(1),
        {
          id: "cmux-replacement",
          provider: "cmux",
          region: "replacement",
          url: "https://replacement.relay.cmux.dev/",
        },
      ],
    }));
    expect(() => assertSafeRelayCatalogRotation({
      current: added,
      next: replacedInOneStep,
      overlapSeconds: RELAY_ROTATION_MIN_OVERLAP_SECONDS,
    })).toThrow();

    const removed = parseRelayCatalog(JSON.stringify({
      ...added,
      sequence: added.sequence + 1,
      relays: added.relays.slice(1),
    }));
    expect(() => assertSafeRelayCatalogRotation({
      current: added,
      next: removed,
      overlapSeconds: RELAY_ROTATION_MIN_OVERLAP_SECONDS - 1,
    })).toThrow();
    expect(() => assertSafeRelayCatalogRotation({
      current: added,
      next: removed,
      overlapSeconds: RELAY_ROTATION_MIN_OVERLAP_SECONDS,
    })).not.toThrow();
  });

  test("requires a dedicated policy key instead of reusing the relay token key", () => {
    const { privateKey } = generateKeyPairSync("ed25519");
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    expect(() => relayPolicySigningKey({
      CMUX_RELAY_POLICY_KEY_ID: "relay-policy-test",
      CMUX_RELAY_JWT_PRIVATE_KEY_PEM: pem,
    })).toThrow();
    expect(relayPolicySigningKey({
      CMUX_RELAY_POLICY_KEY_ID: "relay-policy-test",
      CMUX_RELAY_POLICY_PRIVATE_KEY_PEM: pem,
    }).key.asymmetricKeyType).toBe("ed25519");
  });

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
      nbf: 1_699_999_995,
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
      customRelays: [],
    }, catalog)).not.toThrow();
    expect(() => assertManagedSelectionExists({
      mode: "managed",
      selectedManagedRelayIds: ["substituted-relay"],
      customRelays: [],
    }, catalog)).toThrow();
  });

  test("rejects every custom credential field before persistence", () => {
    for (const field of ["token", "auth_token", "authorization", "password", "secret", "apiKey"]) {
      expect(() => parseRelayPreferenceUpdate({
        preference: {
          mode: "custom",
          selectedManagedRelayIds: [],
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

  test("keeps dormant managed selection and custom definitions in every mode", () => {
    const customRelay = {
      id: "private-relay",
      provider: "private",
      region: "home",
      url: "https://relay.example.net/",
      authMode: "none" as const,
    };
    const automatic = parseRelayPreferenceUpdate({
      expectedRevision: 7,
      preference: {
        mode: "automatic",
        selectedManagedRelayIds: ["cmux-us-west"],
        customRelays: [customRelay],
      },
    });
    expect(automatic.preference).toEqual({
      mode: "automatic",
      selectedManagedRelayIds: ["cmux-us-west"],
      customRelays: [customRelay],
    });
    expect(() => parseRelayPreferenceUpdate({
      preference: {
        mode: "custom",
        selectedManagedRelayIds: ["cmux-us-west"],
        customRelays: [],
      },
    })).toThrow();
    expect(() => parseRelayPreferenceUpdate({
      preference: {
        mode: "automatic",
        selectedManagedRelayIds: ["private-relay"],
        customRelays: [customRelay],
      },
    })).toThrow();
  });
});
