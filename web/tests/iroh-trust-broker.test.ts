import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import * as Effect from "effect/Effect";
import {
  type IrohTrustBrokerConfigShape,
} from "../services/iroh/config";
import {
  bindingRequestTranscript,
  parseVerificationKeys,
  registrationTranscript,
  type IrohBindingRequestProof,
  verifyEndpointAttestation,
} from "../services/iroh/crypto";
import {
  IrohConflictError,
  IrohForbiddenError,
  IrohNotFoundError,
} from "../services/iroh/errors";
import {
  MANAGED_RELAY_URLS,
  sha256,
  type IrohRegistrationPayload,
} from "../services/iroh/model";
import {
  canBindingRevokeStale,
  canIOSBindingForgetMac,
  canIOSBindingUseMac,
} from "../services/iroh/buildCompatibility";
import {
  type IrohBindingRecord,
  type IrohChallengeRecord,
  type IrohRepositoryShape,
} from "../services/iroh/repository";
import { makeIrohTrustBroker } from "../services/iroh/trustBroker";
import type { IrohDiscoveryScope } from "../services/iroh/discoveryScope";
import type { RelayPreference } from "../services/relay/model";

const NOW = new Date("2026-07-09T20:00:00.000Z");
const USER_A = "user-a";
const USER_B = "user-b";
type TestDirectPorts = {
  readonly ipv4?: number;
  readonly ipv6?: number;
};

describe("Iroh build compatibility", () => {
  test("accepts distinct bundle-derived Mac namespaces for one tag", () => {
    const ios = binding({
      platform: "ios",
      tag: "default",
      clientNamespace: "dev.cmux.app.internal",
    });
    const stableMac = binding({
      platform: "mac",
      tag: "default",
      clientNamespace: "mac:com.cmuxterm.app",
    });
    const stagingMac = binding({
      platform: "mac",
      tag: "default",
      clientNamespace: "mac:com.cmuxterm.app.staging",
    });

    expect(stableMac.clientNamespace).not.toBe(stagingMac.clientNamespace);
    expect(canIOSBindingUseMac(ios, stableMac)).toBe(true);
    expect(canIOSBindingUseMac(ios, stagingMac)).toBe(true);
  });

  test("a tagged DEV iOS build may discover every tagged DEV Mac build", () => {
    const ios = binding({
      platform: "ios",
      tag: "mdev",
      clientNamespace: "dev.cmux.ios.mdev",
    });
    const siblingTags = ["msta", "mnyt", "cdial"];

    for (const tag of siblingTags) {
      expect(canIOSBindingUseMac(ios, binding({
        platform: "mac",
        tag,
        clientNamespace: `mac:com.cmuxterm.app.debug.${tag}`,
      }))).toBe(true);
    }
    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "default",
      clientNamespace: "mac:com.cmuxterm.app",
    }))).toBe(false);
    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "rc",
      clientNamespace: "mac:com.cmuxterm.app.rc",
    }))).toBe(false);
    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "staging",
      clientNamespace: "mac:com.cmuxterm.app.staging",
    }))).toBe(false);
    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "rc",
      clientNamespace: "mac:com.cmuxterm.app.debug.rc",
    }))).toBe(false);
    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "staging",
      clientNamespace: "mac:com.cmuxterm.app.debug.staging",
    }))).toBe(false);
    expect(canIOSBindingForgetMac(ios, binding({
      platform: "mac",
      tag: "msta",
      clientNamespace: "mac:com.cmuxterm.app.debug.msta",
    }))).toBe(false);
  });

  test("tagged DEV discovery requires a DEV Mac bundle namespace", () => {
    const ios = binding({
      platform: "ios",
      tag: "mdev",
      clientNamespace: "dev.cmux.ios.mdev",
    });

    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "mdev",
      clientNamespace: "mac:com.cmuxterm.app.staging.mdev",
    }))).toBe(false);
    expect(canIOSBindingUseMac(ios, binding({
      platform: "mac",
      tag: "mdev",
      clientNamespace: "mac:com.cmuxterm.app.debug.mdev",
    }))).toBe(true);
  });

  test("a legacy default-lane iOS binding may use default and nightly Macs", () => {
    const legacyIos = binding({
      platform: "ios",
      tag: "default",
      clientNamespace: "legacy",
    });
    const defaultMac = binding({
      platform: "mac",
      tag: "default",
      clientNamespace: "mac:com.cmuxterm.app",
    });
    const nightlyMac = binding({
      platform: "mac",
      tag: "nightly",
      clientNamespace: "mac:com.cmuxterm.app.nightly",
    });
    const featureMac = binding({
      platform: "mac",
      tag: "feature-b",
      clientNamespace: "mac:com.cmuxterm.app.debug.feature-b",
    });

    expect(canIOSBindingUseMac(legacyIos, defaultMac)).toBe(true);
    expect(canIOSBindingUseMac(legacyIos, nightlyMac)).toBe(true);
    expect(canIOSBindingUseMac(legacyIos, featureMac)).toBe(false);
  });

  test("the legacy fallback stays on the default lane", () => {
    const taggedLegacyIos = binding({
      platform: "ios",
      tag: "feature-a",
      clientNamespace: "legacy",
    });
    const nightlyMac = binding({
      platform: "mac",
      tag: "nightly",
      clientNamespace: "mac:com.cmuxterm.app.nightly",
    });
    const sameLaneMac = binding({
      platform: "mac",
      tag: "feature-a",
      clientNamespace: "mac:com.cmuxterm.app.debug.feature-a",
    });

    expect(canIOSBindingUseMac(taggedLegacyIos, nightlyMac)).toBe(false);
    expect(canIOSBindingUseMac(taggedLegacyIos, sameLaneMac)).toBe(true);
  });

  test("the legacy fallback does not broaden Mac forgetting", () => {
    const legacyIos = binding({
      platform: "ios",
      tag: "default",
      clientNamespace: "legacy",
    });
    const defaultMac = binding({
      platform: "mac",
      tag: "default",
      clientNamespace: "mac:com.cmuxterm.app",
    });
    const nightlyMac = binding({
      platform: "mac",
      tag: "nightly",
      clientNamespace: "mac:com.cmuxterm.app.nightly",
    });

    expect(canIOSBindingForgetMac(legacyIos, defaultMac)).toBe(true);
    expect(canIOSBindingForgetMac(legacyIos, nightlyMac)).toBe(false);
  });
});

describe("Iroh trust broker registration", () => {
  test("registers a valid endpoint proof and reports the relay credential unavailable", async () => {
    const fixture = makeFixture();
    const request = await fixture.signedRegistration();
    const result = await Effect.runPromise(fixture.broker.register(USER_A, request, NOW)) as {
      revision: number;
      binding: { endpoint_id: string };
      relay: { status: string };
      discovery_complete: boolean;
      discovery: {
        revision: number;
        bindings: Array<{ binding_id: string }>;
      };
    };
    expect(result.binding.endpoint_id).toBe(fixture.endpointId);
    expect(result.relay.status).toBe("unavailable");
    expect(result.discovery.revision).toBe(result.revision);
    expect(result.discovery_complete).toBe(true);
    expect(result.discovery.bindings.map((binding) => binding.binding_id))
      .toEqual([fixture.repository.bindings[0]?.id]);
    expect(fixture.repository.bindings).toHaveLength(1);
    expect(fixture.repository.bindings[0]?.pathHints).toEqual([{
      kind: "direct_address",
      value: "8.8.8.8:4433",
      source: "native",
      privacy_scope: "public_internet",
      observed_at: "2026-07-09T19:55:00.000Z",
      expires_at: "2026-07-09T20:45:00.000Z",
    }]);
  });

  test("persists and publishes signed family-specific direct ports to the same account", async () => {
    const fixture = makeFixture({
      registrationDirectPorts: { ipv4: 49_152, ipv6: 49_153 },
    });
    const registered = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    )) as { binding: { direct_ports?: TestDirectPorts } };

    expect(registered.binding.direct_ports).toEqual({ ipv4: 49_152, ipv6: 49_153 });
    expect(fixture.repository.bindings[0]).toMatchObject({
      directPortV4: 49_152,
      directPortV6: 49_153,
    });

    const sameAccount = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      bindings: Array<{ direct_ports?: TestDirectPorts }>;
    };
    expect(sameAccount.bindings[0]?.direct_ports).toEqual({ ipv4: 49_152, ipv6: 49_153 });

    const otherAccount = await Effect.runPromise(fixture.broker.discover(USER_B, NOW)) as {
      bindings: Array<{ direct_ports?: TestDirectPorts }>;
    };
    expect(otherAccount.bindings).toEqual([]);
  });

  test("updates or clears direct ports on a fresh signed registration", async () => {
    const fixture = makeFixture({ registrationDirectPorts: { ipv4: 49_152 } });
    await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    ));

    const ipv6Only = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration("mac", { ipv6: 49_153 }),
      new Date(NOW.getTime() + 1_000),
    )) as { binding: { direct_ports?: TestDirectPorts } };
    expect(ipv6Only.binding.direct_ports).toEqual({ ipv6: 49_153 });
    expect(fixture.repository.bindings[0]).toMatchObject({
      directPortV4: null,
      directPortV6: 49_153,
    });

    const legacyRefresh = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration("mac", null),
      new Date(NOW.getTime() + 2_000),
    )) as { binding: Record<string, unknown> };
    expect("direct_ports" in legacyRefresh.binding).toBe(false);
    expect(fixture.repository.bindings[0]).toMatchObject({
      directPortV4: null,
      directPortV6: null,
    });
  });

  test("preserves account-private routes while filtering unsafe registration hints", async () => {
    const publicDirectHint: IrohRegistrationPayload["pathHints"][number] = {
      kind: "direct_address",
      value: "8.8.4.4:4433",
      source: "native",
      privacy_scope: "public_internet",
      observed_at: "2026-07-09T19:55:00.000Z",
      expires_at: "2026-07-09T20:45:00.000Z",
    };
    const customRelayURL = "https://relay.example.net/";
    const fixture = makeFixture({
      relayPreference: {
        mode: "custom",
        selectedManagedRelayIds: [],
        customRelays: [{
          id: "private-relay",
          provider: "private",
          region: "home",
          url: customRelayURL,
          authMode: "none",
        }],
      },
      registrationPathHints: [
        publicDirectHint,
        relayHint(customRelayURL),
        relayHint("https://substitution.example.net/"),
        {
          kind: "direct_address",
          value: "10.0.0.2:4433",
          source: "lan",
          privacy_scope: "local_network",
          observed_at: "2026-07-09T19:55:00.000Z",
          expires_at: "2026-07-09T20:45:00.000Z",
          network_profile: { source: "lan", profile_id: "local" },
        },
      ],
    });

    await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    ));

    expect(fixture.repository.bindings[0]?.pathHints).toEqual([
      publicDirectHint,
      relayHint(customRelayURL),
    ]);
  });

  test("reports not_requested when refreshing the same binding", async () => {
    const fixture = makeFixture();
    await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    ));

    const refreshed = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      new Date(NOW.getTime() + 1_000),
    )) as { relay: { status: string } };

    expect(refreshed.relay.status).toBe("not_requested");
  });

  test("marks a truncated registration discovery page incomplete", async () => {
    const fixture = makeFixture();
    for (let index = 1; index <= 128; index += 1) {
      fixture.repository.bindings.push(binding({
        id: `123e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        userId: USER_A,
        deviceUuid: `223e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        appInstanceId: `323e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        endpointId: index.toString(16).padStart(64, "0"),
        platform: "ios",
      }));
    }

    const result = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    )) as {
      discovery_complete: boolean;
      discovery: { bindings: unknown[]; next_cursor: string | null };
    };

    expect(result.discovery.bindings).toHaveLength(128);
    expect(result.discovery.next_cursor).not.toBeNull();
    expect(result.discovery_complete).toBe(false);
  });

  test("returns only the requested complete scope with registration", async () => {
    const fixture = makeFixture();
    const eligibleMac = binding({
      id: "123e4567-e89b-42d3-a456-426614174020",
      platform: "mac",
      tag: "stable",
      pairingEnabled: true,
    });
    const irrelevantMac = binding({
      id: "123e4567-e89b-42d3-a456-426614174021",
      platform: "mac",
      tag: "other",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(eligibleMac, irrelevantMac);
    const discoveryScope = {
      local_binding: {
        device_id: fixture.deviceId,
        app_instance_id: fixture.appInstanceId,
        tag: "stable",
        platform: "ios",
      },
      peer_bindings: {
        platform: "mac",
        tags: ["Stable"],
        pairing_enabled: true,
      },
    };
    const normalizedDiscoveryScope = {
      ...discoveryScope,
      peer_bindings: {
        ...discoveryScope.peer_bindings,
        tags: ["stable"],
      },
    };

    const result = await Effect.runPromise(fixture.broker.register(
      USER_A,
      {
        ...await fixture.signedRegistration("ios"),
        discoveryScope,
      },
      NOW,
    )) as {
      discovery_complete: boolean;
      discovery_scope_complete: boolean;
      discovery_scope: unknown;
      discovery: { bindings: Array<{ binding_id: string }> };
    };

    expect(result.discovery_complete).toBe(false);
    expect(result.discovery_scope_complete).toBe(true);
    expect(result.discovery_scope).toEqual(normalizedDiscoveryScope);
    expect(result.discovery.bindings.map((row) => row.binding_id)).toEqual([
      eligibleMac.id,
      fixture.repository.bindings.find((row) =>
        row.deviceUuid === fixture.deviceId
        && row.appInstanceId === fixture.appInstanceId
        && row.platform === "ios")?.id,
    ].sort());
  });

  test("rejects a mismatched registration scope before consuming its challenge", async () => {
    const fixture = makeFixture();
    const signed = await fixture.signedRegistration("ios");
    await expectEffectFailure(
      fixture.broker.register(USER_A, {
        ...signed,
        discoveryScope: {
          local_binding: {
            device_id: fixture.deviceId,
            app_instance_id: randomUUID(),
            tag: "stable",
            platform: "ios",
          },
          peer_bindings: { platform: "mac" },
        },
      }, NOW),
      "IrohInvalidInputError",
    );

    const retried = await Effect.runPromise(
      fixture.broker.register(USER_A, signed, NOW),
    ) as { binding: { endpoint_id: string } };
    expect(retried.binding.endpoint_id).toBe(fixture.endpointId);
  });

  test("rejects the wrong key and a changed payload", async () => {
    const wrongKeyFixture = makeFixture();
    const wrongRequest = await wrongKeyFixture.signedRegistration();
    const otherKey = generateKeyPairSync("ed25519");
    wrongRequest.signature = sign(
      null,
      registrationTranscript({
        challengeId: wrongRequest.challengeId,
        nonce: wrongRequest.nonce,
        payloadSha256: sha256(Buffer.from(wrongRequest.payload, "base64url")),
      }),
      otherKey.privateKey,
    ).toString("base64url");
    await expectEffectFailure(
      wrongKeyFixture.broker.register(USER_A, wrongRequest, NOW),
      "IrohForbiddenError",
    );

    const changedFixture = makeFixture();
    const changedRequest = await changedFixture.signedRegistration();
    const changed = JSON.parse(Buffer.from(changedRequest.payload, "base64url").toString()) as Record<string, unknown>;
    changed.tag = "redirected";
    changedRequest.payload = Buffer.from(JSON.stringify(changed)).toString("base64url");
    await expectEffectFailure(
      changedFixture.broker.register(USER_A, changedRequest, NOW),
      "IrohForbiddenError",
    );
  });

  test("rejects expired and replayed challenges", async () => {
    const expired = makeFixture();
    await expectEffectFailure(
      expired.broker.register(
        USER_A,
        await expired.signedRegistration(),
        new Date(NOW.getTime() + 6 * 60 * 1_000),
      ),
      "IrohForbiddenError",
    );

    const replay = makeFixture();
    const request = await replay.signedRegistration();
    await Effect.runPromise(replay.broker.register(USER_A, request, NOW));
    await expectEffectFailure(replay.broker.register(USER_A, request, NOW), "IrohConflictError");
  });

  test("re-keys the slot onto a fresh binding id when the endpoint rotates", async () => {
    const fixture = makeFixture();
    await Effect.runPromise(fixture.broker.register(USER_A, await fixture.signedRegistration(), NOW));
    const slotId = fixture.repository.bindings[0]!.id;
    // A rotated endpoint and a bumped generation reuse the same (user, device,
    // tag) slot, but the new incarnation lands on a BRAND NEW binding id: the old
    // row is soft-revoked ("slot_reincarnated") so a host that denied the old id
    // can't strand the resurrected slot, and no operator revoke is demanded.
    const replacement = makeFixture({
      repository: fixture.repository,
      appInstanceId: fixture.appInstanceId,
      deviceId: fixture.deviceId,
      identityGeneration: 2,
    });
    await Effect.runPromise(replacement.broker.register(USER_A, await replacement.signedRegistration(), NOW));
    const active = fixture.repository.bindings.filter((row) => !row.revokedAt);
    expect(active).toHaveLength(1);
    expect(active[0]!.id).not.toBe(slotId);
    expect(active[0]!.endpointId).toBe(replacement.endpointId);
    expect(active[0]!.identityGeneration).toBe(2);
    const retired = fixture.repository.bindings.find((row) => row.id === slotId);
    expect(retired?.revokedAt).toEqual(NOW);
    expect(retired?.revokedReason).toBe("slot_reincarnated");
  });

  test("keeps the same device and tag in separate app namespace slots", async () => {
    const repository = new MemoryRepository();
    const deviceId = randomUUID();
    const internal = makeFixture({
      repository,
      deviceId,
      registrationClientNamespace: "dev.cmux.app.internal",
    });
    await Effect.runPromise(internal.broker.register(
      USER_A,
      await internal.signedRegistration(),
      NOW,
      "dev.cmux.app.internal",
    ));
    const internalBindingId = repository.bindings[0]!.id;

    const beta = makeFixture({
      repository,
      deviceId,
      registrationClientNamespace: "dev.cmux.app.beta",
    });
    await Effect.runPromise(beta.broker.register(
      USER_A,
      await beta.signedRegistration(),
      NOW,
      "dev.cmux.app.beta",
    ));

    const active = repository.bindings.filter((row) => !row.revokedAt);
    expect(active).toHaveLength(2);
    expect(active.map((row) => row.clientNamespace).sort()).toEqual([
      "dev.cmux.app.beta",
      "dev.cmux.app.internal",
    ]);
    expect(repository.bindings.find((row) => row.id === internalBindingId)?.revokedAt).toBeNull();
  });

  test("adopts the matching legacy endpoint into its exact app namespace", async () => {
    const fixture = makeFixture();
    const legacy = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration("mac", undefined, "legacy"),
      NOW,
      "legacy",
    )) as { binding: { binding_id: string } };
    const adopted = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration("mac", undefined, "mac:stable"),
      NOW,
      "mac:stable",
    )) as { binding: { binding_id: string } };

    expect(adopted.binding.binding_id).toBe(legacy.binding.binding_id);
    expect(fixture.repository.bindings).toHaveLength(1);
    expect(fixture.repository.bindings[0]?.clientNamespace).toBe("mac:stable");
  });

  test("adopts a tag-only Mac binding into its exact bundle namespace", async () => {
    const fixture = makeFixture();
    const tagOnly = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration("mac", undefined, "mac:stable"),
      NOW,
      "mac:stable",
    )) as { binding: { binding_id: string } };
    const adopted = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(
        "mac",
        undefined,
        "mac:com.cmuxterm.app",
      ),
      NOW,
      "mac:com.cmuxterm.app",
    )) as { binding: { binding_id: string } };

    expect(adopted.binding.binding_id).toBe(tagOnly.binding.binding_id);
    expect(fixture.repository.bindings).toHaveLength(1);
    expect(fixture.repository.bindings[0]?.clientNamespace)
      .toBe("mac:com.cmuxterm.app");
  });
});

describe("Iroh discovery and grants", () => {
  test("reduces a 341-binding account to the three bindings iOS can use", async () => {
    const fixture = makeFixture();
    const local = binding({
      id: "123e4567-e89b-42d3-a456-426614174001",
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      tag: "stable",
      platform: "ios",
    });
    const stableMac = binding({
      id: "123e4567-e89b-42d3-a456-426614174002",
      tag: "default",
      platform: "mac",
      pairingEnabled: true,
    });
    const nightlyMac = binding({
      id: "123e4567-e89b-42d3-a456-426614174003",
      tag: "nightly",
      platform: "mac",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(local, stableMac, nightlyMac);
    for (let index = 4; index <= 341; index += 1) {
      fixture.repository.bindings.push(binding({
        id: `123e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        tag: index % 2 === 0 ? "other" : "default",
        platform: index % 2 === 0 ? "mac" : "ios",
        pairingEnabled: false,
      }));
    }
    const scope = {
      localBinding: {
        deviceId: fixture.deviceId,
        appInstanceId: fixture.appInstanceId,
        tag: "stable",
        platform: "ios" as const,
      },
      peerBindings: {
        platform: "mac" as const,
        tags: ["default", "nightly"],
        pairingEnabled: true,
      },
    };

    const full = await Effect.runPromise(
      fixture.broker.discoverComplete(USER_A, NOW),
    ) as { bindings: unknown[] };
    const scoped = await Effect.runPromise(
      fixture.broker.discoverScoped(USER_A, scope, NOW),
    ) as { bindings: Array<{ binding_id: string }> };
    const fullBytes = Buffer.byteLength(JSON.stringify(full));
    const scopedBytes = Buffer.byteLength(JSON.stringify(scoped));

    expect(full.bindings).toHaveLength(341);
    expect(scoped.bindings.map((row) => row.binding_id)).toEqual([
      local.id,
      stableMac.id,
      nightlyMac.id,
    ]);
    expect(scopedBytes).toBeLessThan(fullBytes / 20);
  });

  test("publishes one monotonic account revision across registration and revocation", async () => {
    const fixture = makeFixture();
    const first = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    )) as { revision: number; binding: { binding_id: string } };
    expect(first.revision).toBe(1);

    const firstSnapshot = await Effect.runPromise(
      fixture.broker.discover(USER_A, NOW),
    ) as { revision: number };
    expect(firstSnapshot.revision).toBe(1);

    const refreshed = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      new Date(NOW.getTime() + 1_000),
    )) as { revision: number };
    expect(refreshed.revision).toBe(2);

    const revoked = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      { bindingId: first.binding.binding_id },
      new Date(NOW.getTime() + 2_000),
    )) as { revision: number };
    expect(revoked.revision).toBe(3);

    const retried = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      { bindingId: first.binding.binding_id },
      new Date(NOW.getTime() + 3_000),
    )) as { revision: number };
    expect(retried.revision).toBe(3);
  });

  test("paginates more than 256 active bindings without a total-count cap", async () => {
    const fixture = makeFixture();
    for (let index = 1; index <= 300; index += 1) {
      fixture.repository.bindings.push(binding({
        id: `123e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        userId: USER_A,
        deviceUuid: `223e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        appInstanceId: `323e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        endpointId: index.toString(16).padStart(64, "0"),
      }));
    }

    const pageCounts: number[] = [];
    const bindingIds = new Set<string>();
    let cursor: string | undefined;
    do {
      const page = await Effect.runPromise(fixture.broker.discover(
        USER_A,
        NOW,
        { pageSize: "128", ...(cursor ? { cursor } : {}) },
      )) as {
        bindings: Array<{ binding_id: string }>;
        next_cursor: string | null;
      };
      pageCounts.push(page.bindings.length);
      page.bindings.forEach((record) => bindingIds.add(record.binding_id));
      cursor = page.next_cursor ?? undefined;
    } while (cursor);

    expect(pageCounts).toEqual([128, 128, 44]);
    expect(bindingIds.size).toBe(300);
  });

  test("keeps the legacy no-query discovery response at 256 bindings", async () => {
    const fixture = makeFixture();
    for (let index = 1; index <= 300; index += 1) {
      fixture.repository.bindings.push(binding({
        id: `123e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        userId: USER_A,
        deviceUuid: `223e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        appInstanceId: `323e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        endpointId: index.toString(16).padStart(64, "0"),
      }));
    }

    const legacy = await Effect.runPromise(
      fixture.broker.discover(USER_A, NOW),
    ) as { bindings: Array<{ binding_id: string }>; next_cursor?: string };

    expect(legacy.bindings).toHaveLength(256);
    expect(legacy.next_cursor).toBeUndefined();
  });

  test("returns every active binding in one complete connectivity snapshot", async () => {
    const fixture = makeFixture();
    for (let index = 1; index <= 300; index += 1) {
      fixture.repository.bindings.push(binding({
        id: `123e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        userId: USER_A,
        deviceUuid: `223e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        appInstanceId: `323e4567-e89b-42d3-a456-${String(index).padStart(12, "0")}`,
        endpointId: index.toString(16).padStart(64, "0"),
      }));
    }

    const complete = await Effect.runPromise(
      fixture.broker.discoverComplete(USER_A, NOW),
    ) as { bindings: Array<{ binding_id: string }> };

    expect(complete.bindings).toHaveLength(300);
    expect(new Set(complete.bindings.map((record) => record.binding_id)).size).toBe(300);
  });

  test("makes owned binding revocation retry-safe without rotating LAN state twice", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A });
    fixture.repository.bindings.push(active);

    const first = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      { bindingId: active.id },
      NOW,
    ));
    const firstRevokedAt = active.revokedAt;
    expect(first).toEqual({
      revoked: true,
      revision: 1,
      lan_rendezvous_rotated: true,
    });
    expect(firstRevokedAt).toEqual(NOW);
    const firstDiscovery = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      lan_rendezvous: { generation: number };
    };
    expect(firstDiscovery.lan_rendezvous.generation).toBe(2);

    const retry = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      { bindingId: active.id },
      new Date(NOW.getTime() + 60_000),
    ));
    expect(retry).toEqual(first);
    expect(active.revokedAt).toEqual(firstRevokedAt);
    const retryDiscovery = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      lan_rendezvous: { generation: number };
    };
    expect(retryDiscovery.lan_rendezvous.generation).toBe(2);

    await expectEffectFailure(
      fixture.broker.revoke(USER_B, { bindingId: active.id }, NOW),
      "IrohNotFoundError",
    );
    await expectEffectFailure(
      fixture.broker.revoke(USER_A, { bindingId: randomUUID() }, NOW),
      "IrohNotFoundError",
    );
  });

  test("reconciles an older same-namespace binding through stale cleanup", async () => {
    const fixture = makeFixture();
    const current = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "current",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const stale = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: randomUUID(),
      clientNamespace: current.clientNamespace,
      tag: "older",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const otherNamespace = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: randomUUID(),
      clientNamespace: "dev.cmux.app.beta",
      tag: "older",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    fixture.repository.bindings.push(current, stale, otherNamespace);
    expect(canBindingRevokeStale(current, stale)).toBe(true);
    const body = { bindingId: stale.id, intent: "revoke_stale" } as const;

    const result = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      current.clientNamespace,
      fixture.bindingProof(
        current.id,
        "DELETE",
        "api/devices/iroh",
        body,
      ),
    ));

    expect(result).toEqual({
      revoked: true,
      revision: 1,
      lan_rendezvous_rotated: true,
    });
    expect(stale.revokedAt).toEqual(NOW);
    await expectEffectFailure(
      fixture.broker.revoke(
        USER_A,
        { bindingId: otherNamespace.id, intent: "revoke_stale" },
        NOW,
        current.clientNamespace,
        fixture.bindingProof(
          current.id,
          "DELETE",
          "api/devices/iroh",
          { bindingId: otherNamespace.id, intent: "revoke_stale" },
        ),
      ),
      "IrohNotFoundError",
    );
  });

  test("a namespaced client can drain its migrated legacy revocation", async () => {
    const fixture = makeFixture({
      registrationClientNamespace: "dev.cmux.app.internal",
    });
    const current = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "stable",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const legacy = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      platform: "ios",
      clientNamespace: "legacy",
      tag: "stable",
    });
    fixture.repository.bindings.push(current, legacy);
    const body = { bindingId: legacy.id };

    const result = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      "dev.cmux.app.internal",
      fixture.bindingProof(
        current.id,
        "DELETE",
        "api/devices/iroh",
        body,
      ),
    ));

    expect(result).toEqual({
      revoked: true,
      revision: 1,
      lan_rendezvous_rotated: true,
    });
    expect(legacy.revokedAt).toEqual(NOW);
  });

  test("a namespaced self-revocation retry authenticates with its soft-revoked binding", async () => {
    const fixture = makeFixture({
      registrationClientNamespace: "dev.cmux.app.internal",
    });
    const current = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "stable",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    fixture.repository.bindings.push(current);
    const body = { bindingId: current.id };
    const proof = fixture.bindingProof(
      current.id,
      "DELETE",
      "api/devices/iroh",
      body,
    );

    const first = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      current.clientNamespace,
      proof,
    ));
    const retried = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      current.clientNamespace,
      proof,
    ));

    expect(first).toEqual({
      revoked: true,
      revision: 1,
      lan_rendezvous_rotated: true,
    });
    expect(retried).toEqual(first);
  });

  test("a soft-revoked proof cannot revoke another live binding", async () => {
    const fixture = makeFixture({
      registrationClientNamespace: "dev.cmux.app.internal",
    });
    const retired = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "stable",
      platform: "ios",
      endpointId: fixture.endpointId,
      revokedAt: NOW,
    });
    const live = binding({
      userId: USER_A,
      clientNamespace: "dev.cmux.app.internal",
      platform: "ios",
    });
    fixture.repository.bindings.push(retired, live);
    const body = { bindingId: live.id };

    await expectEffectFailure(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      retired.clientNamespace,
      fixture.bindingProof(
        retired.id,
        "DELETE",
        "api/devices/iroh",
        body,
      ),
    ), "IrohNotFoundError");
    expect(live.revokedAt).toBeNull();
  });

  test("a reincarnated slot can finish an already-completed revocation", async () => {
    const fixture = makeFixture({
      registrationClientNamespace: "dev.cmux.app.internal",
    });
    const current = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: fixture.appInstanceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "stable",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const retiredAt = new Date(NOW.getTime() - 60_000);
    const retired = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      appInstanceId: randomUUID(),
      clientNamespace: "dev.cmux.app.internal",
      tag: "stable",
      platform: "ios",
      revokedAt: retiredAt,
    });
    fixture.repository.bindings.push(current, retired);
    const body = { bindingId: retired.id };

    const result = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      "dev.cmux.app.internal",
      fixture.bindingProof(
        current.id,
        "DELETE",
        "api/devices/iroh",
        body,
      ),
    ));

    expect(result).toEqual({
      revoked: true,
      revision: 0,
      lan_rendezvous_rotated: true,
    });
    expect(retired.revokedAt).toEqual(retiredAt);
  });

  test("a binding proof cannot claim another app namespace", async () => {
    const fixture = makeFixture();
    const current = binding({
      userId: USER_A,
      clientNamespace: "dev.cmux.app.internal",
      endpointId: fixture.endpointId,
    });
    fixture.repository.bindings.push(current);

    await expectEffectFailure(
      fixture.broker.discover(
        USER_A,
        NOW,
        undefined,
        "dev.cmux.app.beta",
        fixture.bindingProof(
          current.id,
          "GET",
          "api/devices/iroh",
          undefined,
        ),
      ),
      "IrohNotFoundError",
    );
  });

  test("an iOS binding can forget only its same-build Mac", async () => {
    const fixture = makeFixture();
    const ios = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "stable",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const mac = binding({
      userId: USER_A,
      deviceUuid: randomUUID(),
      clientNamespace: "mac:stable",
      tag: "stable",
      platform: "mac",
    });
    const siblingMac = binding({
      userId: USER_A,
      deviceUuid: randomUUID(),
      clientNamespace: "mac:demo",
      tag: "demo",
      platform: "mac",
    });
    fixture.repository.bindings.push(ios, mac, siblingMac);
    const body = { bindingId: mac.id, intent: "forget_mac" };

    const result = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      ios.clientNamespace,
      fixture.bindingProof(
        ios.id,
        "DELETE",
        "api/devices/iroh",
        body,
      ),
    ));

    expect(result).toEqual({
      revoked: true,
      revision: 1,
      lan_rendezvous_rotated: true,
    });
    expect(mac.revokedAt).toEqual(NOW);
    const siblingBody = {
      bindingId: siblingMac.id,
      intent: "forget_mac",
    };
    await expectEffectFailure(
      fixture.broker.revoke(
        USER_A,
        siblingBody,
        NOW,
        ios.clientNamespace,
        fixture.bindingProof(
          ios.id,
          "DELETE",
          "api/devices/iroh",
          siblingBody,
        ),
      ),
      "IrohNotFoundError",
    );
    expect(siblingMac.revokedAt).toBeNull();
  });

  test("an official iOS binding can forget Stable and Nightly Macs", async () => {
    const fixture = makeFixture();
    const ios = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      clientNamespace: "dev.cmux.app.internal",
      tag: "default",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const nightlyMac = binding({
      userId: USER_A,
      deviceUuid: randomUUID(),
      clientNamespace: "mac:nightly",
      tag: "nightly",
      platform: "mac",
    });
    fixture.repository.bindings.push(ios, nightlyMac);
    const body = { bindingId: nightlyMac.id, intent: "forget_mac" };

    const result = await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      body,
      NOW,
      ios.clientNamespace,
      fixture.bindingProof(
        ios.id,
        "DELETE",
        "api/devices/iroh",
        body,
      ),
    ));

    expect(result).toEqual({
      revoked: true,
      revision: 1,
      lan_rendezvous_rotated: true,
    });
    expect(nightlyMac.revokedAt).toEqual(NOW);
  });

  test("never exposes another user through shared team context", async () => {
    const fixture = makeFixture();
    await Effect.runPromise(fixture.broker.register(USER_A, await fixture.signedRegistration(), NOW));
    const discovered = await Effect.runPromise(fixture.broker.discover(USER_B, NOW)) as {
      bindings: unknown[];
    };
    expect(discovered.bindings).toEqual([]);
  });

  test("publishes only an exact account-saved custom relay and removes it after deletion", async () => {
    const customRelay = {
      id: "private-relay",
      provider: "private",
      region: "home",
      url: "https://relay.example.net/",
      authMode: "none" as const,
    };
    const fixture = makeFixture({
      relayPreference: {
        mode: "custom",
        selectedManagedRelayIds: [],
        customRelays: [customRelay],
      },
      registrationPathHints: [
        relayHint(customRelay.url),
        relayHint("https://substitution.example.net/"),
      ],
    });

    await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    ));
    expect(fixture.repository.bindings[0]?.pathHints).toEqual([
      relayHint(customRelay.url),
    ]);

    fixture.setRelayPreference({
      mode: "automatic",
      selectedManagedRelayIds: [],
      customRelays: [],
    });
    const discovered = await Effect.runPromise(
      fixture.broker.discover(USER_A, NOW),
    ) as { bindings: Array<{ path_hints: unknown[] }> };
    expect(discovered.bindings[0]?.path_hints).toEqual([]);
  });

  test("returns the relay fleet and authenticated current/previous public keys", async () => {
    const fixture = makeFixture();
    fixture.repository.bindings.push(binding({
      userId: USER_A,
      pathHints: [{
        kind: "direct_address",
        value: "10.0.0.2:4433",
        source: "lan",
        privacy_scope: "local_network",
        observed_at: "2026-07-09T18:00:00.000Z",
        expires_at: "2026-07-09T19:00:00.000Z",
        network_profile: { source: "lan", profile_id: "local" },
      }],
    }));
    const discovered = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      relay_fleet: string[];
      bindings: Array<{ path_hints: unknown[] }>;
      grant_verification_keys: {
        current_kid: string;
        keys: Array<{ kid: string; spki_der_base64: string }>;
      };
    };
    expect(discovered.relay_fleet).toEqual([...MANAGED_RELAY_URLS]);
    expect(discovered.bindings[0]!.path_hints).toEqual([]);
    expect(fixture.repository.bindings[0]!.pathHints).toEqual([]);
    expect(discovered.grant_verification_keys.current_kid).toBe("current");
    expect(discovered.grant_verification_keys.keys.map((key) => key.kid)).toEqual([
      "current",
      "previous",
    ]);
    expect(JSON.stringify(discovered.grant_verification_keys)).not.toContain("PRIVATE KEY");
  });

  test("defensively withholds unexpired direct hints from discovery", async () => {
    const fixture = makeFixture();
    fixture.repository.bindings.push(binding({
      userId: USER_A,
      pathHints: [{
        kind: "direct_address",
        value: "10.0.0.2:4433",
        source: "lan",
        privacy_scope: "local_network",
        observed_at: "2026-07-09T19:55:00.000Z",
        expires_at: "2026-07-09T20:30:00.000Z",
        network_profile: { source: "lan", profile_id: "local" },
      }],
    }));

    const discovered = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      bindings: Array<{ path_hints: unknown[] }>;
    };
    expect(discovered.bindings[0]?.path_hints).toEqual([]);
  });

  test("serves the fleet-reported attach route ahead of client-published hints", async () => {
    const attachedURL = MANAGED_RELAY_URLS[0]!;
    const otherManagedURL = MANAGED_RELAY_URLS[1]!;
    const fixture = makeFixture();
    fixture.repository.bindings.push(binding({
      userId: USER_A,
      // The client republish also advertised the same relay plus another one.
      pathHints: [relayHint(attachedURL), relayHint(otherManagedURL)],
      relayAttachedUrl: attachedURL,
      relayAttachReportedAt: new Date(NOW.getTime() - 60_000),
    }));

    const discovered = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      bindings: Array<{ path_hints: Array<Record<string, unknown>> }>;
    };
    const hints = discovered.bindings[0]!.path_hints;
    // Server-observed hint first, the duplicate client hint dropped, the
    // remaining client hint kept as fallback.
    expect(hints.map((hint) => hint.value)).toEqual([attachedURL, otherManagedURL]);
    expect(hints[0]).toMatchObject({
      kind: "relay_url",
      source: "native",
      privacy_scope: "public_internet",
      observed_at: NOW.toISOString(),
    });
    expect(new Date(String(hints[0]!.expires_at)).getTime())
      .toBeGreaterThan(NOW.getTime());
  });

  test("ages out an attach route with no fresh evidence (lost detach report)", async () => {
    const fixture = makeFixture();
    fixture.repository.bindings.push(binding({
      userId: USER_A,
      pathHints: [],
      relayAttachedUrl: MANAGED_RELAY_URLS[0]!,
      // Both evidence channels are stale: the relay died without a detach
      // report and the Mac stopped renewing its registration.
      relayAttachReportedAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1_000),
      lastSeenAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1_000),
    }));

    const discovered = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      bindings: Array<{ path_hints: unknown[] }>;
    };
    expect(discovered.bindings[0]?.path_hints).toEqual([]);
  });

  test("a fresh attach report keeps the route while the binding lease is stale", async () => {
    const fixture = makeFixture();
    fixture.repository.bindings.push(binding({
      userId: USER_A,
      pathHints: [],
      relayAttachedUrl: MANAGED_RELAY_URLS[0]!,
      relayAttachReportedAt: new Date(NOW.getTime() - 5 * 60 * 1_000),
      // Broker unreachable from the Mac (cache-first world) while the relay
      // path works: the attach report alone corroborates the route.
      lastSeenAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1_000),
    }));

    const discovered = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      bindings: Array<{ path_hints: Array<Record<string, unknown>> }>;
    };
    expect(discovered.bindings[0]?.path_hints.map((hint) => hint.value))
      .toEqual([MANAGED_RELAY_URLS[0]!]);
  });

  test("withholds a fleet-reported custom relay the account no longer saves", async () => {
    const fixture = makeFixture();
    fixture.repository.bindings.push(binding({
      userId: USER_A,
      pathHints: [],
      relayAttachedUrl: "https://relay.example.net/",
      relayAttachReportedAt: new Date(NOW.getTime() - 60_000),
    }));

    const discovered = await Effect.runPromise(fixture.broker.discover(USER_A, NOW)) as {
      bindings: Array<{ path_hints: unknown[] }>;
    };
    expect(discovered.bindings[0]?.path_hints).toEqual([]);
  });

  test("does not combine a pre-revocation binding with a post-revocation LAN generation", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A });
    fixture.repository.bindings.push(active);
    let releaseSnapshot: (() => void) | undefined;
    const snapshotCanRead = new Promise<void>((resolve) => {
      releaseSnapshot = resolve;
    });
    let didBeginSnapshot: (() => void) | undefined;
    const snapshotStarted = new Promise<void>((resolve) => {
      didBeginSnapshot = resolve;
    });
    fixture.repository.beforeDiscoverySnapshot = async () => {
      didBeginSnapshot?.();
      await snapshotCanRead;
    };

    const discovery = Effect.runPromise(fixture.broker.discover(USER_A, NOW));
    await snapshotStarted;
    await Effect.runPromise(fixture.broker.revoke(USER_A, { bindingId: active.id }, NOW));
    releaseSnapshot?.();
    const result = await discovery as {
      bindings: unknown[];
      lan_rendezvous: { generation: number };
    };

    expect(result.bindings).toEqual([]);
    expect(result.lan_rendezvous.generation).toBe(2);
  });

  test("pair grants require two same-user bindings and a pairable Mac", async () => {
    const fixture = makeFixture();
    const initiator = binding({ userId: USER_A, platform: "ios", pairingEnabled: false });
    const acceptor = binding({ userId: USER_A, platform: "mac", pairingEnabled: true });
    fixture.repository.bindings.push(initiator, acceptor);
    const result = await Effect.runPromise(fixture.broker.issuePairGrant(USER_A, {
      initiatorBindingId: initiator.id,
      acceptorBindingId: acceptor.id,
    }, NOW)) as { grant: string };
    expect(result.grant.split(".")).toHaveLength(3);
    expect(fixture.repository.pairGrantAudits).toHaveLength(1);
    expect(JSON.stringify(fixture.repository.pairGrantAudits[0])).not.toContain(result.grant);

    acceptor.userId = USER_B;
    await expectEffectFailure(fixture.broker.issuePairGrant(USER_A, {
      initiatorBindingId: initiator.id,
      acceptorBindingId: acceptor.id,
    }, NOW), "IrohNotFoundError");
  });

  test("pair grants require an iOS initiator and revalidate both peers at commit", async () => {
    const wrongPlatform = makeFixture();
    const macInitiator = binding({ userId: USER_A, platform: "mac" });
    const macAcceptor = binding({ userId: USER_A, platform: "mac", pairingEnabled: true });
    wrongPlatform.repository.bindings.push(macInitiator, macAcceptor);
    await expectEffectFailure(wrongPlatform.broker.issuePairGrant(USER_A, {
      initiatorBindingId: macInitiator.id,
      acceptorBindingId: macAcceptor.id,
    }, NOW), "IrohForbiddenError");

    const raced = makeFixture();
    const iosInitiator = binding({ userId: USER_A, platform: "ios" });
    const pairableMac = binding({ userId: USER_A, platform: "mac", pairingEnabled: true });
    raced.repository.bindings.push(iosInitiator, pairableMac);
    raced.repository.beforeRecordPairGrant = () => {
      pairableMac.revokedAt = NOW;
    };
    await expectEffectFailure(raced.broker.issuePairGrant(USER_A, {
      initiatorBindingId: iosInitiator.id,
      acceptorBindingId: pairableMac.id,
    }, NOW), "IrohNotFoundError");
    expect(raced.repository.pairGrantAudits).toHaveLength(0);
  });

  test("pair grants require two distinct physical devices", async () => {
    const fixture = makeFixture();
    const deviceUuid = randomUUID();
    const iosInitiator = binding({
      userId: USER_A,
      deviceUuid,
      platform: "ios",
    });
    const macAcceptor = binding({
      userId: USER_A,
      deviceUuid,
      platform: "mac",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(iosInitiator, macAcceptor);

    await expectEffectFailure(fixture.broker.issuePairGrant(USER_A, {
      initiatorBindingId: iosInitiator.id,
      acceptorBindingId: macAcceptor.id,
    }, NOW), "IrohForbiddenError");
    expect(fixture.repository.pairGrantAudits).toHaveLength(0);
  });

  test("pair grants accept another tagged DEV Mac", async () => {
    const fixture = makeFixture();
    const initiator = binding({
      userId: USER_A,
      clientNamespace: "dev.cmux.ios.feature-a",
      tag: "feature-a",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const acceptor = binding({
      userId: USER_A,
      clientNamespace: "mac:com.cmuxterm.app.debug.feature-b",
      tag: "feature-b",
      platform: "mac",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(initiator, acceptor);
    const body = {
      initiatorBindingId: initiator.id,
      acceptorBindingId: acceptor.id,
    };

    const result = await Effect.runPromise(fixture.broker.issuePairGrant(
      USER_A,
      body,
      NOW,
      initiator.clientNamespace,
      fixture.bindingProof(
        initiator.id,
        "POST",
        "api/devices/iroh/pair-grants",
        body,
      ),
    )) as { grant: string };

    expect(result.grant.split(".")).toHaveLength(3);
    expect(fixture.repository.pairGrantAudits).toHaveLength(1);
  });

  test("an official iOS binding can pair with a Nightly Mac", async () => {
    const fixture = makeFixture();
    const initiator = binding({
      userId: USER_A,
      clientNamespace: "dev.cmux.app.internal",
      tag: "default",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const acceptor = binding({
      userId: USER_A,
      clientNamespace: "mac:nightly",
      tag: "nightly",
      platform: "mac",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(initiator, acceptor);
    const body = {
      initiatorBindingId: initiator.id,
      acceptorBindingId: acceptor.id,
    };

    const result = await Effect.runPromise(fixture.broker.issuePairGrant(
      USER_A,
      body,
      NOW,
      initiator.clientNamespace,
      fixture.bindingProof(
        initiator.id,
        "POST",
        "api/devices/iroh/pair-grants",
        body,
      ),
    )) as { grant: string };

    expect(result.grant.split(".")).toHaveLength(3);
    expect(fixture.repository.pairGrantAudits).toHaveLength(1);
  });

  test("a pre-namespace legacy iOS binding can pair with a Nightly Mac", async () => {
    const fixture = makeFixture();
    const initiator = binding({
      userId: USER_A,
      clientNamespace: "legacy",
      tag: "default",
      platform: "ios",
    });
    const acceptor = binding({
      userId: USER_A,
      clientNamespace: "mac:com.cmuxterm.app.nightly",
      tag: "nightly",
      platform: "mac",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(initiator, acceptor);

    // Old Beta builds cannot send X-Cmux-App-Namespace or a binding request
    // proof; the absence of both is the legacy migration signal.
    const result = await Effect.runPromise(fixture.broker.issuePairGrant(USER_A, {
      initiatorBindingId: initiator.id,
      acceptorBindingId: acceptor.id,
    }, NOW)) as { grant: string };

    expect(result.grant.split(".")).toHaveLength(3);
    expect(fixture.repository.pairGrantAudits).toHaveLength(1);
  });

  test("a legacy iOS binding outside the default lane keeps exact lane matching", async () => {
    const fixture = makeFixture();
    const initiator = binding({
      userId: USER_A,
      clientNamespace: "legacy",
      tag: "feature-a",
      platform: "ios",
    });
    const acceptor = binding({
      userId: USER_A,
      clientNamespace: "mac:com.cmuxterm.app.nightly",
      tag: "nightly",
      platform: "mac",
      pairingEnabled: true,
    });
    fixture.repository.bindings.push(initiator, acceptor);

    await expectEffectFailure(fixture.broker.issuePairGrant(USER_A, {
      initiatorBindingId: initiator.id,
      acceptorBindingId: acceptor.id,
    }, NOW), "IrohForbiddenError");
    expect(fixture.repository.pairGrantAudits).toHaveLength(0);
  });

  test("a proofed legacy iOS binding discovers nightly Macs but not feature lanes", async () => {
    const fixture = makeFixture();
    const ios = binding({
      userId: USER_A,
      deviceUuid: fixture.deviceId,
      clientNamespace: "legacy",
      tag: "default",
      platform: "ios",
      endpointId: fixture.endpointId,
    });
    const nightlyMac = binding({
      userId: USER_A,
      clientNamespace: "mac:com.cmuxterm.app.nightly",
      tag: "nightly",
      platform: "mac",
    });
    const featureMac = binding({
      userId: USER_A,
      clientNamespace: "mac:feature-b",
      tag: "feature-b",
      platform: "mac",
    });
    fixture.repository.bindings.push(ios, nightlyMac, featureMac);

    const discovered = await Effect.runPromise(fixture.broker.discover(
      USER_A,
      NOW,
      undefined,
      "legacy",
      fixture.bindingProof(
        ios.id,
        "GET",
        "api/devices/iroh",
        undefined,
      ),
    )) as { bindings: Array<{ binding_id: string }> };

    const ids = discovered.bindings.map((row) => row.binding_id);
    expect(ids).toContain(ios.id);
    expect(ids).toContain(nightlyMac.id);
    expect(ids).not.toContain(featureMac.id);
  });

  test("a namespaced app cannot discover or mutate a sibling app binding", async () => {
    const fixture = makeFixture();
    const internal = binding({
      platform: "ios",
      clientNamespace: "dev.cmux.app.internal",
    });
    const beta = binding({
      platform: "ios",
      clientNamespace: "dev.cmux.app.beta",
      endpointId: fixture.endpointId,
    });
    const mac = binding({
      platform: "mac",
      clientNamespace: "mac:stable",
      endpointId: fixture.endpointId,
    });
    fixture.repository.bindings.push(internal, beta, mac);

    const discovered = await Effect.runPromise(
      fixture.broker.discover(
        USER_A,
        NOW,
        undefined,
        "dev.cmux.app.beta",
        fixture.bindingProof(
          beta.id,
          "GET",
          "api/devices/iroh",
          undefined,
        ),
      ),
    ) as { bindings: Array<{ binding_id: string }> };
    expect(discovered.bindings.map((row) => row.binding_id)).toEqual([
      beta.id,
      mac.id,
    ].sort());

    const macDiscovered = await Effect.runPromise(
      fixture.broker.discover(
        USER_A,
        NOW,
        undefined,
        "mac:stable",
        fixture.bindingProof(
          mac.id,
          "GET",
          "api/devices/iroh",
          undefined,
        ),
      ),
    ) as { bindings: Array<{ binding_id: string }> };
    expect(macDiscovered.bindings.map((row) => row.binding_id)).toEqual([
      internal.id,
      beta.id,
      mac.id,
    ].sort());

    const legacyDiscovered = await Effect.runPromise(
      fixture.broker.discover(USER_A, NOW),
    ) as { bindings: Array<{ binding_id: string }> };
    expect(legacyDiscovered.bindings.map((row) => row.binding_id)).toEqual([
      internal.id,
      beta.id,
      mac.id,
    ].sort());

    const revokeBody = { bindingId: internal.id };
    await expectEffectFailure(fixture.broker.revoke(
      USER_A,
      revokeBody,
      NOW,
      "dev.cmux.app.beta",
      fixture.bindingProof(
        beta.id,
        "DELETE",
        "api/devices/iroh",
        revokeBody,
      ),
    ), "IrohNotFoundError");
    await expectEffectFailure(fixture.broker.revoke(
      USER_A,
      { bindingId: internal.id },
      NOW,
    ), "IrohNotFoundError");
    const bindingBody = { bindingId: internal.id };
    await expectEffectFailure(fixture.broker.issueEndpointAttestation(
      USER_A,
      bindingBody,
      NOW,
      "dev.cmux.app.beta",
      fixture.bindingProof(
        beta.id,
        "POST",
        "api/devices/iroh/endpoint-attestations",
        bindingBody,
      ),
    ), "IrohNotFoundError");
    const pairBody = {
      initiatorBindingId: internal.id,
      acceptorBindingId: mac.id,
    };
    await expectEffectFailure(fixture.broker.issuePairGrant(
      USER_A,
      pairBody,
      NOW,
      "dev.cmux.app.beta",
      fixture.bindingProof(
        beta.id,
        "POST",
        "api/devices/iroh/pair-grants",
        pairBody,
      ),
    ), "IrohNotFoundError");

    expect(internal.revokedAt).toBeNull();
    expect(fixture.repository.pairGrantAudits).toHaveLength(0);
  });

  test("tagged DEV discovery exposes every tagged DEV Mac binding", async () => {
    const fixture = makeFixture();
    const iosA = binding({
      platform: "ios",
      clientNamespace: "dev.cmux.ios.feature-a",
      tag: "feature-a",
      endpointId: fixture.endpointId,
    });
    const macA = binding({
      platform: "mac",
      clientNamespace: "mac:com.cmuxterm.app.debug.feature-a",
      tag: "feature-a",
    });
    const macB = binding({
      platform: "mac",
      clientNamespace: "mac:com.cmuxterm.app.debug.feature-b",
      tag: "feature-b",
    });
    fixture.repository.bindings.push(iosA, macA, macB);

    const discovered = await Effect.runPromise(fixture.broker.discover(
      USER_A,
      NOW,
      undefined,
      iosA.clientNamespace,
      fixture.bindingProof(
        iosA.id,
        "GET",
        "api/devices/iroh",
        undefined,
      ),
    )) as { bindings: Array<{ binding_id: string }> };

    expect(discovered.bindings.map((row) => row.binding_id)).toEqual([
      iosA.id,
      macA.id,
      macB.id,
    ].sort());
  });

  test("issues a short-lived opaque same-account attestation only for an owned active binding", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A, platform: "ios", identityGeneration: 4 });
    fixture.repository.bindings.push(active);
    const result = await Effect.runPromise(fixture.broker.issueEndpointAttestation(USER_A, {
      bindingId: active.id,
    }, NOW)) as {
      attestation_version: number;
      attestation: string;
      expires_at: string;
      grant_verification_keys: { current_kid: string };
    };
    expect(result.attestation_version).toBe(1);
    expect(result.grant_verification_keys.current_kid).toBe("current");
    expect(new Date(result.expires_at).getTime() - NOW.getTime()).toBe(24 * 60 * 60 * 1_000);
    const payload = JSON.parse(Buffer.from(result.attestation.split(".")[1]!, "base64url").toString()) as {
      sub: string;
    };
    expect(payload.sub).toHaveLength(43);
    expect(JSON.stringify(payload)).not.toContain(USER_A);

    const keys = parseVerificationKeys(fixture.config.grantVerificationKeysJson);
    expect(verifyEndpointAttestation(result.attestation, keys.publicKeys, {
      bindingId: active.id,
      deviceId: active.deviceUuid,
      endpointId: active.endpointId,
      identityGeneration: active.identityGeneration,
      platform: "ios",
      nowSeconds: Math.floor(NOW.getTime() / 1_000),
    }).sub).toBe(payload.sub);

    await expectEffectFailure(fixture.broker.issueEndpointAttestation(USER_B, {
      bindingId: active.id,
    }, NOW), "IrohNotFoundError");
    active.revokedAt = NOW;
    await expectEffectFailure(fixture.broker.issueEndpointAttestation(USER_A, {
      bindingId: active.id,
    }, NOW), "IrohNotFoundError");
  });

  test("does not return an attestation when its exact binding is revoked during signing", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A, platform: "ios" });
    fixture.repository.bindings.push(active);
    fixture.repository.beforeFinalizeEndpointAttestation = () => {
      active.revokedAt = NOW;
    };

    await expectEffectFailure(fixture.broker.issueEndpointAttestation(USER_A, {
      bindingId: active.id,
    }, NOW), "IrohNotFoundError");
  });

  test("fails closed when verification or opaque-subject signing material is unavailable", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A, platform: "ios" });
    fixture.repository.bindings.push(active);
    const noVerificationKeys = makeIrohTrustBroker(fixture.repository, {
      ...fixture.config,
      grantVerificationKeysJson: undefined,
    });
    await expectEffectFailure(noVerificationKeys.discover(USER_A, NOW), "IrohConfigurationError");

    const noAccountSubject = makeIrohTrustBroker(fixture.repository, {
      ...fixture.config,
      accountSubjectSecretBase64: undefined,
    });
    await expectEffectFailure(noAccountSubject.issueEndpointAttestation(USER_A, {
      bindingId: active.id,
    }, NOW), "IrohConfigurationError");
  });
});

describe("Iroh endpoint records", () => {
  const RECORD_PATH = "api/devices/iroh/endpoint-record";

  function recordFor(endpointIdHex: string, payloadBytes = 200): string {
    // A stand-in for a pkarr SignedPacket: the signing public key leads the
    // serialized bytes; the broker never verifies the signature (readers
    // do), so the remainder only needs to satisfy the size bounds.
    const record = Buffer.concat([
      Buffer.from(endpointIdHex, "hex"),
      Buffer.alloc(payloadBytes, 0xab),
    ]);
    return record.toString("base64");
  }

  async function registeredFixture() {
    const fixture = makeFixture();
    const registered = await Effect.runPromise(fixture.broker.register(
      USER_A,
      await fixture.signedRegistration(),
      NOW,
    )) as { binding: { binding_id: string } };
    return { fixture, bindingId: registered.binding.binding_id };
  }

  test("publishes a record and serves it through discovery", async () => {
    const { fixture, bindingId } = await registeredFixture();
    const record = recordFor(fixture.endpointId);
    const body = { bindingId, record };

    const published = await Effect.runPromise(fixture.broker.publishEndpointRecord(
      USER_A,
      body,
      NOW,
      "legacy",
      fixture.bindingProof(bindingId, "POST", RECORD_PATH, body),
    ));
    expect(published).toEqual({ published: true });

    const snapshot = await Effect.runPromise(
      fixture.broker.discover(USER_A, NOW),
    ) as { bindings: ReadonlyArray<Record<string, unknown>> };
    expect(snapshot.bindings[0]?.endpoint_record).toBe(record);
  });

  test("requires the binding-request proof", async () => {
    const { fixture, bindingId } = await registeredFixture();
    const body = { bindingId, record: recordFor(fixture.endpointId) };

    await expectEffectFailure(
      fixture.broker.publishEndpointRecord(USER_A, body, NOW, "legacy"),
      "IrohForbiddenError",
    );
  });

  test("rejects a record whose key does not match the caller's endpoint", async () => {
    const { fixture, bindingId } = await registeredFixture();
    const foreignKey = randomUUID().replaceAll("-", "").repeat(2);
    const body = { bindingId, record: recordFor(foreignKey) };

    await expectEffectFailure(
      fixture.broker.publishEndpointRecord(
        USER_A,
        body,
        NOW,
        "legacy",
        fixture.bindingProof(bindingId, "POST", RECORD_PATH, body),
      ),
      "IrohForbiddenError",
    );

    const snapshot = await Effect.runPromise(
      fixture.broker.discover(USER_A, NOW),
    ) as { bindings: ReadonlyArray<Record<string, unknown>> };
    expect(snapshot.bindings[0]?.endpoint_record).toBeUndefined();
  });

  test("rejects a proof from a different binding", async () => {
    const { fixture, bindingId } = await registeredFixture();
    const body = { bindingId, record: recordFor(fixture.endpointId) };

    await expectEffectFailure(
      fixture.broker.publishEndpointRecord(
        USER_A,
        body,
        NOW,
        "legacy",
        fixture.bindingProof(randomUUID(), "POST", RECORD_PATH, body),
      ),
      "IrohNotFoundError",
    );
  });

  test("rejects malformed and oversized records", async () => {
    const { fixture, bindingId } = await registeredFixture();

    for (const record of [
      "not base64!!",
      Buffer.alloc(32, 1).toString("base64"),
      Buffer.alloc(4_000, 1).toString("base64"),
    ]) {
      const body = { bindingId, record };
      await expectEffectFailure(
        fixture.broker.publishEndpointRecord(
          USER_A,
          body,
          NOW,
          "legacy",
          fixture.bindingProof(bindingId, "POST", RECORD_PATH, body),
        ),
        "IrohInvalidInputError",
      );
    }
  });

  test("revocation wipes the stored record", async () => {
    const { fixture, bindingId } = await registeredFixture();
    const body = { bindingId, record: recordFor(fixture.endpointId) };
    await Effect.runPromise(fixture.broker.publishEndpointRecord(
      USER_A,
      body,
      NOW,
      "legacy",
      fixture.bindingProof(bindingId, "POST", RECORD_PATH, body),
    ));

    await Effect.runPromise(fixture.broker.revoke(
      USER_A,
      { bindingId },
      new Date(NOW.getTime() + 1_000),
    ));

    const row = fixture.repository.bindings.find((binding) => binding.id === bindingId);
    expect(row?.revokedAt).not.toBeNull();
    expect(row?.endpointRecord).toBeNull();
  });
});

type MutableBinding = IrohBindingRecord & {
  userId: string;
  directPortV4: number | null;
  directPortV6: number | null;
};

// Mirrors the live repository's SQL discovery-scope filter for the in-memory
// fixture (the production filter lives in repository.ts SQL, not TypeScript).
function bindingMatchesDiscoveryScope(
  binding: {
    readonly deviceUuid: string;
    readonly appInstanceId: string;
    readonly tag: string;
    readonly platform: string;
    readonly pairingEnabled: boolean;
  },
  scope: IrohDiscoveryScope,
): boolean {
  const local = scope.localBinding;
  if (
    binding.deviceUuid === local.deviceId
    && binding.appInstanceId === local.appInstanceId
    && binding.tag === local.tag
    && binding.platform === local.platform
  ) {
    return true;
  }
  const peers = scope.peerBindings;
  return binding.platform === peers.platform
    && (
      peers.tags === undefined
      || peers.tags.includes(binding.tag.toLowerCase())
    )
    && (
      peers.pairingEnabled === undefined
      || binding.pairingEnabled === peers.pairingEnabled
    );
}

class MemoryRepository implements IrohRepositoryShape {
  readonly challenges: IrohChallengeRecord[] = [];
  readonly bindings: MutableBinding[] = [];
  readonly pairGrantAudits: unknown[] = [];
  private lanGenerations = new Map<string, number>();
  private routeRevisions = new Map<string, number>();
  beforeDiscoverySnapshot: (() => Promise<void>) | undefined;
  beforeRecordPairGrant: (() => void) | undefined;
  beforeFinalizeEndpointAttestation: (() => void) | undefined;

  issueChallenge(input: Parameters<IrohRepositoryShape["issueChallenge"]>[0]) {
    const challenge: IrohChallengeRecord = {
      id: randomUUID(),
      userId: input.userId,
      deviceUuid: input.deviceUuid,
      appInstanceId: input.appInstanceId,
      clientNamespace: input.clientNamespace ?? "legacy",
      tag: input.tag,
      endpointId: input.endpointId,
      identityGeneration: input.identityGeneration,
      payloadSha256: input.payloadSha256,
      nonceHash: input.nonceHash,
      createdAt: input.now,
      expiresAt: input.expiresAt,
      consumedAt: null,
    };
    this.challenges.push(challenge);
    return Effect.succeed(challenge);
  }

  findChallenge(userId: string, challengeId: string) {
    return Effect.succeed(this.challenges.find((row) => row.userId === userId && row.id === challengeId) ?? null);
  }

  consumeChallengeAndRegister(input: Parameters<IrohRepositoryShape["consumeChallengeAndRegister"]>[0]) {
    const challenge = this.challenges.find((row) => row.id === input.challengeId && row.userId === input.userId);
    if (!challenge) return Effect.fail(new IrohNotFoundError({ resource: "challenge" }));
    if (challenge.consumedAt) return Effect.fail(new IrohConflictError({ code: "challenge_replayed" }));
    if (challenge.expiresAt <= input.now) return Effect.fail(new IrohForbiddenError({ code: "challenge_expired" }));
    if (challenge.nonceHash !== input.nonceHash) return Effect.fail(new IrohForbiddenError({ code: "invalid_challenge_nonce" }));
    const directPorts = (input.payload as IrohRegistrationPayload & {
      directPorts?: TestDirectPorts;
    }).directPorts;
    // The slot is keyed on (user, namespace, device, tag). A reinstall,
    // sign-out/in, or key rotation inside one app reuses that slot.
    const exactExisting = this.bindings.find((row) =>
      row.userId === input.userId &&
      row.clientNamespace === input.payload.clientNamespace &&
      row.deviceUuid === input.payload.deviceId &&
      row.tag === input.payload.tag &&
      !row.revokedAt);
    const adoptableNamespaces = input.payload.platform === "mac"
        && input.payload.clientNamespace.startsWith("mac:")
      ? new Set(["legacy", `mac:${input.payload.tag}`])
      : new Set(["legacy"]);
    const legacyExisting = input.payload.clientNamespace === "legacy"
      ? undefined
      : this.bindings.find((row) =>
        row.userId === input.userId &&
        adoptableNamespaces.has(row.clientNamespace) &&
        row.deviceUuid === input.payload.deviceId &&
        row.tag === input.payload.tag &&
        row.endpointId === input.payload.endpointId &&
        row.platform === input.payload.platform &&
        !row.revokedAt);
    if (legacyExisting) {
      legacyExisting.clientNamespace = input.payload.clientNamespace;
    }
    const existing = exactExisting ?? legacyExisting;
    if (existing && challenge.createdAt < existing.registeredAt) {
      return Effect.fail(new IrohConflictError({ code: "challenge_superseded" }));
    }
    // The endpoint id is a global identity: no OTHER live binding may claim it.
    // Self is excluded so a slot can rotate its own key.
    if (this.bindings.some((row) =>
      row.endpointId === input.payload.endpointId &&
      !row.revokedAt &&
      row !== existing)) {
      return Effect.fail(new IrohConflictError({ code: "endpoint_already_bound" }));
    }
    // A heartbeat/refresh: every signed grant-identity field is unchanged
    // (endpoint id, platform, identity generation), so update in place and keep
    // the binding id stable. Any divergence falls through to reincarnation.
    if (
      existing &&
      existing.endpointId === input.payload.endpointId &&
      existing.platform === input.payload.platform &&
      existing.identityGeneration === input.payload.identityGeneration
    ) {
      challenge.consumedAt = input.now;
      existing.appInstanceId = input.payload.appInstanceId;
      existing.platform = input.payload.platform;
      existing.identityGeneration = input.payload.identityGeneration;
      existing.displayName = input.payload.displayName ?? null;
      existing.pairingEnabled = input.payload.pairingEnabled;
      existing.capabilities = [...input.payload.capabilities];
      existing.directPortV4 = directPorts?.ipv4 ?? null;
      existing.directPortV6 = directPorts?.ipv6 ?? null;
      existing.pathHints = [...input.payload.pathHints];
      existing.lastSeenAt = input.now;
      existing.registeredAt = challenge.createdAt;
      existing.updatedAt = input.now;
      return Effect.succeed({
        binding: existing,
        created: false,
        accountRevision: this.advanceRouteRevision(input.userId),
      });
    }
    // A new incarnation (rotated endpoint, or any changed signed identity field):
    // retire the old row (soft-revoke, never delete) and mint a fresh binding id so
    // a peer host that denied the old id can't strand the resurrected slot. In the
    // real repository the retired row's live pair grants are revoked and the LAN
    // discovery generation rotates; this fake does not model the grant table,
    // but does mirror the generation bump and staleness gate.
    if (existing) {
      existing.revokedAt = input.now;
      existing.revokedReason = "slot_reincarnated";
      existing.directPortV4 = null;
      existing.directPortV6 = null;
      existing.pathHints = [];
      existing.updatedAt = input.now;
      this.lanGenerations.set(
        input.userId,
        (this.lanGenerations.get(input.userId) ?? 1) + 1,
      );
    }
    const inserted = binding({
      userId: input.userId,
      deviceUuid: input.payload.deviceId,
      appInstanceId: input.payload.appInstanceId,
      clientNamespace: input.payload.clientNamespace,
      tag: input.payload.tag,
      platform: input.payload.platform,
      displayName: input.payload.displayName ?? null,
      endpointId: input.payload.endpointId,
      identityGeneration: input.payload.identityGeneration,
      pairingEnabled: input.payload.pairingEnabled,
      capabilities: [...input.payload.capabilities],
      directPortV4: directPorts?.ipv4 ?? null,
      directPortV6: directPorts?.ipv6 ?? null,
      pathHints: [...input.payload.pathHints],
      registeredAt: challenge.createdAt,
      updatedAt: input.now,
      lastSeenAt: input.now,
    });
    challenge.consumedAt = input.now;
    this.bindings.push(inserted);
    if (!existing) {
      this.lanGenerations.set(
        input.userId,
        (this.lanGenerations.get(input.userId) ?? 0) + 1,
      );
    }
    return Effect.succeed({
      binding: inserted,
      created: true,
      accountRevision: this.advanceRouteRevision(input.userId),
    });
  }

  discoveryPage(input: Parameters<IrohRepositoryShape["discoveryPage"]>[0]) {
    return Effect.promise(async () => {
      await this.beforeDiscoverySnapshot?.();
      const generation = this.lanGenerations.get(input.userId) ?? 1;
      if (input.cursor && input.cursor.generation !== generation) {
        throw new IrohConflictError({ code: "discovery_cursor_stale" });
      }
      const clientNamespace = input.clientNamespace ?? "legacy";
      const caller = input.callerBindingId && input.callerPlatform
        ? this.bindings.find((row) =>
          row.id === input.callerBindingId
          && row.userId === input.userId
          && row.platform === input.callerPlatform
          && row.clientNamespace === clientNamespace
          && !row.revokedAt)
        : undefined;
      const rows = this.bindings
        .filter((row) =>
          row.userId === input.userId &&
          !row.revokedAt &&
          (!input.cursor || row.id > input.cursor.afterBindingId) &&
          (caller
            ? row.id === caller.id || (
              caller.platform === "ios"
                ? canIOSBindingUseMac(caller, row)
                : canIOSBindingUseMac(row, caller)
            )
            : clientNamespace === "legacy"
              || row.clientNamespace === clientNamespace))
        .sort((left, right) => left.id.localeCompare(right.id));
      const bindings = rows.slice(0, input.pageSize);
      const last = bindings.at(-1);
      return {
        bindings,
        lanDiscoveryGeneration: generation,
        accountRevision: this.routeRevisions.get(input.userId) ?? 0,
        nextCursor: rows.length > input.pageSize && last
          ? { generation, afterBindingId: last.id }
          : null,
      };
    });
  }

  discoverySnapshot(input: Parameters<IrohRepositoryShape["discoverySnapshot"]>[0]) {
    return Effect.promise(async () => {
      await this.beforeDiscoverySnapshot?.();
      const clientNamespace = input.clientNamespace ?? "legacy";
      const candidateBindings = this.bindings.filter((row) =>
        row.userId === input.userId &&
        !row.revokedAt &&
        (input.callerBindingId && input.callerPlatform
          ? row.id === input.callerBindingId
            || row.platform === (input.callerPlatform === "mac" ? "ios" : "mac")
          : clientNamespace === "legacy"
            || row.clientNamespace === clientNamespace));
      const caller = input.callerBindingId && input.callerPlatform
        ? candidateBindings.find((row) =>
          row.id === input.callerBindingId
          && row.platform === input.callerPlatform
          && row.clientNamespace === clientNamespace)
        : undefined;
      const visibleBindings = input.callerBindingId && input.callerPlatform
        ? caller
          ? candidateBindings.filter((row) =>
            row.id === caller.id
            || (
              caller.platform === "ios"
                ? canIOSBindingUseMac(caller, row)
                : canIOSBindingUseMac(row, caller)
            ))
          : []
        : candidateBindings;
      return {
        bindings: visibleBindings
          .filter((row) => !input.scope || bindingMatchesDiscoveryScope(row, input.scope))
          .sort((left, right) => left.id.localeCompare(right.id)),
        lanDiscoveryGeneration: this.lanGenerations.get(input.userId) ?? 1,
        accountRevision: this.routeRevisions.get(input.userId) ?? 0,
      };
    });
  }

  findActiveBindings(userId: string, bindingIds: readonly string[]) {
    return Effect.succeed(this.bindings.filter((row) =>
      row.userId === userId && bindingIds.includes(row.id) && !row.revokedAt));
  }

  findBindingForRevocationProof(userId: string, bindingId: string) {
    return Effect.succeed(this.bindings.find((row) =>
      row.userId === userId && row.id === bindingId) ?? null);
  }

  findActiveBindingByEndpoint(userId: string, endpointId: string) {
    return Effect.succeed(this.bindings.find((row) =>
      row.userId === userId && row.endpointId === endpointId && !row.revokedAt) ?? null);
  }

  publishEndpointRecord(
    input: Parameters<IrohRepositoryShape["publishEndpointRecord"]>[0],
  ) {
    const bindingRow = this.bindings.find((row) =>
      row.id === input.bindingId
      && row.userId === input.userId
      && row.endpointId === input.endpointId
      && !row.revokedAt);
    if (!bindingRow) return Effect.succeed({ published: false });
    bindingRow.endpointRecord = input.record;
    bindingRow.endpointRecordUpdatedAt = input.now;
    bindingRow.updatedAt = input.now;
    return Effect.succeed({ published: true });
  }

  revokeBinding(input: Parameters<IrohRepositoryShape["revokeBinding"]>[0]) {
    const row = this.bindings.find((candidate) =>
      candidate.id === input.bindingId && candidate.userId === input.userId);
    const unchanged = (revoked: boolean) => Effect.succeed({
      revoked,
      accountRevision: this.routeRevisions.get(input.userId) ?? 0,
    });
    if (!row) return unchanged(false);
    if (input.authorizedBindingId) {
      const authorized = this.bindings.find((candidate) =>
        candidate.id === input.authorizedBindingId
        && candidate.userId === input.userId);
      if (
        authorized?.revokedAt
        && !(authorized.id === row.id && row.revokedAt)
      ) {
        return unchanged(false);
      }
      if (input.intent === "forget_mac") {
        if (!authorized || !canIOSBindingForgetMac(authorized, row)) {
          return unchanged(false);
        }
        if (row.revokedAt) return unchanged(true);
      } else if (input.intent === "revoke_stale") {
        if (!authorized || !canBindingRevokeStale(authorized, row)) {
          return unchanged(false);
        }
        if (row.revokedAt) return unchanged(true);
      } else {
        const sameDurableSlot = authorized
          && authorized.deviceUuid === row.deviceUuid
          && authorized.tag === row.tag
          && authorized.platform === row.platform
          && (
            authorized.clientNamespace === row.clientNamespace
            || row.clientNamespace === "legacy"
          );
        if (
          row.revokedAt
          && authorized
          && (authorized.id === row.id || sameDurableSlot)
        ) {
          return unchanged(true);
        }
        const sameOwnedSlot = sameDurableSlot
          && authorized?.appInstanceId === row.appInstanceId;
        if (!authorized || (authorized.id !== row.id && !sameOwnedSlot)) {
          return unchanged(false);
        }
      }
    } else if (input.intent === "forget_mac") {
      return unchanged(false);
    } else if (
      (input.clientNamespace ?? "legacy") !== "legacy"
      || row.clientNamespace !== "legacy"
    ) {
      return unchanged(false);
    }
    if (row.revokedAt) return unchanged(true);
    row.revokedAt = input.now;
    row.revokedReason = "user_requested";
    row.endpointRecord = null;
    row.endpointRecordUpdatedAt = null;
    this.lanGenerations.set(input.userId, (this.lanGenerations.get(input.userId) ?? 1) + 1);
    return Effect.succeed({
      revoked: true,
      accountRevision: this.advanceRouteRevision(input.userId),
    });
  }

  pruneExpiredState(input: Parameters<IrohRepositoryShape["pruneExpiredState"]>[0]) {
    let changed = false;
    for (const row of this.bindings.filter((candidate) => candidate.userId === input.userId)) {
      const retained = row.pathHints.filter((hint) => {
        const expiry = (hint as { expires_at?: unknown }).expires_at;
        return typeof expiry === "string" && new Date(expiry) > input.now;
      });
      changed = changed || retained.length !== row.pathHints.length;
      row.pathHints = retained;
    }
    if (changed) this.advanceRouteRevision(input.userId);
    return Effect.void;
  }

  private advanceRouteRevision(userId: string): number {
    const revision = (this.routeRevisions.get(userId) ?? 0) + 1;
    this.routeRevisions.set(userId, revision);
    return revision;
  }

  pruneExpiredStateGlobally(input: Parameters<IrohRepositoryShape["pruneExpiredStateGlobally"]>[0]) {
    for (const row of this.bindings) {
      row.pathHints = row.revokedAt
        ? []
        : row.pathHints.filter((hint) => {
          const expiry = (hint as { expires_at?: unknown }).expires_at;
          return typeof expiry === "string" && new Date(expiry) > input.now;
        });
    }
    return Effect.succeed({
      rowsProcessed: 0,
      batches: 0,
      backlog: false,
      budgetExhausted: null,
      byCategory: {
        revokedHints: 0,
        expiredHints: 0,
        expiredChallenges: 0,
        consumedChallenges: 0,
        relayAudits: 0,
        pairGrantAudits: 0,
        revokedBindings: 0,
      },
    });
  }

  recordPairGrant(input: Parameters<IrohRepositoryShape["recordPairGrant"]>[0]) {
    this.beforeRecordPairGrant?.();
    const initiator = this.bindings.find((row) =>
      row.id === input.initiator.bindingId && row.userId === input.userId && !row.revokedAt);
    const acceptor = this.bindings.find((row) =>
      row.id === input.acceptor.bindingId && row.userId === input.userId && !row.revokedAt);
    if (!initiator || !acceptor) return Effect.fail(new IrohNotFoundError({ resource: "binding" }));
    if (initiator.platform !== "ios" || acceptor.platform !== "mac" || !acceptor.pairingEnabled) {
      return Effect.fail(new IrohForbiddenError({ code: "target_not_pairable" }));
    }
    this.pairGrantAudits.push(input);
    return Effect.void;
  }

  finalizeEndpointAttestation(input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly deviceId: string;
    readonly endpointId: string;
    readonly identityGeneration: number;
    readonly platform: "mac" | "ios";
  }) {
    this.beforeFinalizeEndpointAttestation?.();
    const active = this.bindings.find((row) =>
      row.id === input.bindingId &&
      row.userId === input.userId &&
      !row.revokedAt);
    if (!active) return Effect.fail(new IrohNotFoundError({ resource: "binding" }));
    if (
      active.deviceUuid !== input.deviceId ||
      active.endpointId !== input.endpointId ||
      active.identityGeneration !== input.identityGeneration ||
      active.platform !== input.platform
    ) {
      return Effect.fail(new IrohConflictError({ code: "binding_changed_during_attestation" }));
    }
    return Effect.void;
  }
}

function makeFixture(options: {
  repository?: MemoryRepository;
  appInstanceId?: string;
  deviceId?: string;
  identityGeneration?: number;
  relayPreference?: RelayPreference;
  registrationPathHints?: IrohRegistrationPayload["pathHints"];
  registrationDirectPorts?: TestDirectPorts;
  registrationClientNamespace?: string;
  developmentBindingLimits?: {
    account: number;
    device: number;
  };
} = {}) {
  const endpointKeys = generateKeyPairSync("ed25519");
  const grantKeys = generateKeyPairSync("ed25519");
  const previousKeys = generateKeyPairSync("ed25519");
  const endpointPublicDer = endpointKeys.publicKey.export({ format: "der", type: "spki" });
  const endpointId = Buffer.from(endpointPublicDer).subarray(-32).toString("hex");
  const repository = options.repository ?? new MemoryRepository();
  const appInstanceId = options.appInstanceId ?? randomUUID();
  const deviceId = options.deviceId ?? randomUUID();
  const identityGeneration = options.identityGeneration ?? 1;
  const config: IrohTrustBrokerConfigShape = {
    lanDiscoverySecretBase64: Buffer.alloc(32, 7).toString("base64"),
    accountSubjectSecretBase64: Buffer.alloc(32, 8).toString("base64"),
    grantSigningPrivateKeyPem: grantKeys.privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    grantSigningKid: "current",
    grantVerificationKeysJson: JSON.stringify({
      version: 1,
      current_kid: "current",
      keys: [
        {
          kid: "current",
          alg: "EdDSA",
          spki_der_base64: grantKeys.publicKey.export({ format: "der", type: "spki" }).toString("base64"),
        },
        {
          kid: "previous",
          alg: "EdDSA",
          spki_der_base64: previousKeys.publicKey.export({ format: "der", type: "spki" }).toString("base64"),
        },
      ],
    }),
  };
  let relayPreference = options.relayPreference ?? {
    mode: "automatic" as const,
    selectedManagedRelayIds: [],
    customRelays: [],
  };
  const broker = makeIrohTrustBroker(repository, config, {
    getPreference: () => Effect.succeed({ preference: relayPreference, revision: 0 }),
  });

  return {
    repository,
    broker,
    config,
    endpointId,
    appInstanceId,
    deviceId,
    identityGeneration,
    bindingProof(
      bindingId: string,
      method: string,
      path: string,
      body: unknown,
    ): IrohBindingRequestProof {
      const bodyBytes = body === undefined
        ? Buffer.alloc(0)
        : Buffer.from(JSON.stringify(body));
      const proof = {
        bindingId,
        method,
        path,
        timestampSeconds: Math.floor(NOW.getTime() / 1_000),
        bodySha256: sha256(bodyBytes),
      };
      return {
        ...proof,
        signature: sign(
          null,
          bindingRequestTranscript(proof),
          endpointKeys.privateKey,
        ).toString("base64url"),
      };
    },
    setRelayPreference(next: RelayPreference) {
      relayPreference = next;
    },
    async signedRegistration(
      platform: "mac" | "ios" = "mac",
      directPorts: TestDirectPorts | null | undefined = options.registrationDirectPorts,
      clientNamespace: string =
        options.registrationClientNamespace ?? "legacy",
    ) {
      const payload: IrohRegistrationPayload & { directPorts?: TestDirectPorts } = {
        route_contract_version: 1,
        deviceId,
        appInstanceId,
        clientNamespace,
        tag: "stable",
        platform,
        displayName: "Test Mac",
        endpointId,
        identityGeneration,
        pairingEnabled: true,
        capabilities: ["terminal", "artifacts"],
        ...(directPorts ? { directPorts } : {}),
        pathHints: options.registrationPathHints ?? [{
          kind: "direct_address",
          value: "8.8.8.8:4433",
          source: "native",
          privacy_scope: "public_internet",
          observed_at: "2026-07-09T19:55:00.000Z",
          expires_at: "2026-07-09T20:45:00.000Z",
        }],
      };
      const payloadBytes = Buffer.from(JSON.stringify(payload));
      const challenge = await Effect.runPromise(broker.issueChallenge(USER_A, {
        deviceId,
        appInstanceId,
        clientNamespace: payload.clientNamespace,
        tag: payload.tag,
        endpointId,
        identityGeneration,
        payloadSha256: sha256(payloadBytes),
      }, NOW, payload.clientNamespace)) as { challenge_id: string; nonce: string };
      return {
        challengeId: challenge.challenge_id,
        nonce: challenge.nonce,
        payload: payloadBytes.toString("base64url"),
        signature: sign(null, registrationTranscript({
          challengeId: challenge.challenge_id,
          nonce: challenge.nonce,
          payloadSha256: sha256(payloadBytes),
        }), endpointKeys.privateKey).toString("base64url"),
      };
    },
  };
}

function relayHint(value: string): IrohRegistrationPayload["pathHints"][number] {
  return {
    kind: "relay_url",
    value,
    source: "native",
    privacy_scope: "public_internet",
    observed_at: "2026-07-09T19:55:00.000Z",
    expires_at: "2026-07-09T20:45:00.000Z",
  };
}

function binding(overrides: Partial<MutableBinding> = {}): MutableBinding {
  const now = NOW;
  return {
    id: randomUUID(),
    userId: USER_A,
    deviceUuid: randomUUID(),
    appInstanceId: randomUUID(),
    clientNamespace: "legacy",
    tag: "stable",
    platform: "mac",
    displayName: null,
    endpointId: randomUUID().replaceAll("-", "").repeat(2),
    identityGeneration: 1,
    pairingEnabled: true,
    capabilities: [],
    directPortV4: null,
    directPortV6: null,
    pathHints: [],
    pathHintsNextExpiry: null,
    relayAttachedUrl: null,
    relayAttachReportedAt: null,
    endpointRecord: null,
    endpointRecordUpdatedAt: null,
    deviceLimitOverrideUsed: false,
    lastSeenAt: now,
    registeredAt: now,
    updatedAt: now,
    revokedAt: null,
    revokedReason: null,
    ...overrides,
  };
}

async function expectEffectFailure(
  effect: Effect.Effect<unknown, unknown>,
  expectedTag: string,
): Promise<void> {
  const exit = await Effect.runPromiseExit(effect);
  expect(exit._tag).toBe("Failure");
  if (exit._tag !== "Failure") return;
  expect(String(exit.cause)).toContain(expectedTag);
}
