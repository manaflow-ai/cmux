import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import * as Effect from "effect/Effect";
import {
  deviceLimitOverrideAllowed,
  type IrohTrustBrokerConfigShape,
} from "../services/iroh/config";
import {
  parseVerificationKeys,
  registrationTranscript,
  verifyEndpointAttestation,
} from "../services/iroh/crypto";
import {
  IrohConflictError,
  IrohForbiddenError,
  IrohNotFoundError,
  IrohQuotaExceededError,
  IrohRelayMintError,
} from "../services/iroh/errors";
import {
  IROH_RELAY_TOKEN_LIFETIME_SECONDS,
  MANAGED_RELAY_URLS,
  sha256,
  type IrohRegistrationPayload,
} from "../services/iroh/model";
import type {
  IrohBindingRecord,
  IrohChallengeRecord,
  IrohRepositoryShape,
} from "../services/iroh/repository";
import type { IrohRelayMinterShape } from "../services/iroh/relayMinter";
import { makeIrohTrustBroker } from "../services/iroh/trustBroker";
import type { RelayPreference } from "../services/relay/model";

const NOW = new Date("2026-07-09T20:00:00.000Z");
const USER_A = "user-a";
const USER_B = "user-b";

describe("Iroh trust broker registration", () => {
  test("registers a valid endpoint proof and mints relay credentials after commit", async () => {
    const fixture = makeFixture();
    const request = await fixture.signedRegistration();
    const result = await Effect.runPromise(fixture.broker.register(USER_A, request, NOW)) as {
      binding: { endpoint_id: string };
      relay: { status: string; token: string };
    };
    expect(result.binding.endpoint_id).toBe(fixture.endpointId);
    expect(result.relay.status).toBe("issued");
    expect(fixture.repository.bindings).toHaveLength(1);
    expect(fixture.repository.bindings[0]?.pathHints).toEqual([{
      kind: "direct_address",
      value: "8.8.8.8:4433",
      source: "native",
      privacy_scope: "public_internet",
      observed_at: "2026-07-09T19:55:00.000Z",
      expires_at: "2026-07-09T20:45:00.000Z",
    }]);
    expect(fixture.minter.calls).toBe(1);
  });

  test("relay failure cannot roll back an authenticated registration", async () => {
    const fixture = makeFixture({ minterFailure: true });
    const result = await Effect.runPromise(
      fixture.broker.register(USER_A, await fixture.signedRegistration(), NOW),
    ) as { relay: { status: string } };
    expect(result.relay.status).toBe("unavailable");
    expect(fixture.repository.bindings).toHaveLength(1);
  });

  test("does not mint another relay token when refreshing the same binding", async () => {
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
    expect(fixture.minter.calls).toBe(1);
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

  test("requires revocation/reapproval for endpoint or generation replacement", async () => {
    const fixture = makeFixture();
    await Effect.runPromise(fixture.broker.register(USER_A, await fixture.signedRegistration(), NOW));
    const replacement = makeFixture({
      repository: fixture.repository,
      appInstanceId: fixture.appInstanceId,
      deviceId: fixture.deviceId,
      identityGeneration: 2,
    });
    await expectEffectFailure(
      replacement.broker.register(USER_A, await replacement.signedRegistration(), NOW),
      "IrohConflictError",
    );
    expect(fixture.repository.bindings).toHaveLength(1);
    expect(fixture.repository.bindings[0]!.endpointId).toBe(fixture.endpointId);
  });
});

describe("Iroh discovery and grants", () => {
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
    expect(first).toEqual({ revoked: true, lan_rendezvous_rotated: true });
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
    const noVerificationKeys = makeIrohTrustBroker(fixture.repository, fixture.minter, {
      ...fixture.config,
      grantVerificationKeysJson: undefined,
    });
    await expectEffectFailure(noVerificationKeys.discover(USER_A, NOW), "IrohConfigurationError");

    const noAccountSubject = makeIrohTrustBroker(fixture.repository, fixture.minter, {
      ...fixture.config,
      accountSubjectSecretBase64: undefined,
    });
    await expectEffectFailure(noAccountSubject.issueEndpointAttestation(USER_A, {
      bindingId: active.id,
    }, NOW), "IrohConfigurationError");
  });
});

describe("Iroh relay quotas", () => {
  test("never calls the minter for an unregistered or revoked binding", async () => {
    const fixture = makeFixture();
    await expectEffectFailure(
      fixture.broker.issueRelayToken(USER_A, { bindingId: randomUUID() }, NOW),
      "IrohNotFoundError",
    );
    const revoked = binding({ userId: USER_A, revokedAt: NOW });
    fixture.repository.bindings.push(revoked);
    await expectEffectFailure(
      fixture.broker.issueRelayToken(USER_A, { bindingId: revoked.id }, NOW),
      "IrohNotFoundError",
    );
    expect(fixture.minter.calls).toBe(0);
  });

  test("enforces three endpoint mints per ten minutes before provider work", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A });
    fixture.repository.bindings.push(active);
    for (let index = 0; index < 3; index += 1) {
      await Effect.runPromise(fixture.broker.issueRelayToken(
        USER_A,
        { bindingId: active.id },
        new Date(NOW.getTime() + index * 1_000),
      ));
    }
    await expectEffectFailure(
      fixture.broker.issueRelayToken(USER_A, { bindingId: active.id }, new Date(NOW.getTime() + 4_000)),
      "IrohQuotaExceededError",
    );
    expect(fixture.minter.calls).toBe(3);
  });

  test("does not return a relay credential when the binding is revoked during mint", async () => {
    const fixture = makeFixture();
    const active = binding({ userId: USER_A });
    fixture.repository.bindings.push(active);
    fixture.minter.afterMint = () => {
      active.revokedAt = NOW;
    };

    await expectEffectFailure(
      fixture.broker.issueRelayToken(USER_A, { bindingId: active.id }, NOW),
      "IrohNotFoundError",
    );
    expect(fixture.repository.relayIssuances[0]?.status).toBe("failed");
  });
});

describe("developer binding override", () => {
  const base: IrohTrustBrokerConfigShape = {
    relayMinterInsecureLoopbackOptIn: false,
    deviceLimitOverrideEnabled: true,
    deviceLimitOverrideUserIds: new Set([USER_A]),
    deviceLimitOverrideEnvironments: new Set(["preview"]),
    deploymentEnvironment: "preview",
    isVercelDeployment: true,
  };

  test("requires both an explicit authenticated user and explicit environment", () => {
    expect(deviceLimitOverrideAllowed(base, USER_A)).toBe(true);
    expect(deviceLimitOverrideAllowed(base, USER_B)).toBe(false);
    expect(deviceLimitOverrideAllowed({ ...base, deploymentEnvironment: "production" }, USER_A)).toBe(false);
    expect(deviceLimitOverrideAllowed({ ...base, deviceLimitOverrideEnabled: false }, USER_A)).toBe(false);
  });
});

type MutableBinding = IrohBindingRecord & { userId: string };

class MemoryRepository implements IrohRepositoryShape {
  readonly challenges: IrohChallengeRecord[] = [];
  readonly bindings: MutableBinding[] = [];
  readonly pairGrantAudits: unknown[] = [];
  readonly relayIssuances: Array<{
    id: string;
    userId: string;
    bindingId: string;
    requestedAt: Date;
    status: string;
  }> = [];
  private lanGenerations = new Map<string, number>();
  beforeDiscoverySnapshot: (() => Promise<void>) | undefined;
  beforeRecordPairGrant: (() => void) | undefined;
  beforeFinalizeEndpointAttestation: (() => void) | undefined;

  issueChallenge(input: Parameters<IrohRepositoryShape["issueChallenge"]>[0]) {
    const challenge: IrohChallengeRecord = {
      id: randomUUID(),
      userId: input.userId,
      deviceUuid: input.deviceUuid,
      appInstanceId: input.appInstanceId,
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
    const existing = this.bindings.find((row) => row.appInstanceId === input.payload.appInstanceId && !row.revokedAt);
    if (existing) {
      if (
        existing.userId !== input.userId ||
        existing.endpointId !== input.payload.endpointId ||
        existing.identityGeneration !== input.payload.identityGeneration ||
        existing.deviceUuid !== input.payload.deviceId ||
        existing.tag !== input.payload.tag ||
        existing.platform !== input.payload.platform
      ) return Effect.fail(new IrohConflictError({ code: "binding_replacement_requires_revocation" }));
      challenge.consumedAt = input.now;
      existing.pathHints = [...input.payload.pathHints];
      return Effect.succeed({ binding: existing, created: false });
    }
    if (this.bindings.some((row) => row.endpointId === input.payload.endpointId && !row.revokedAt)) {
      return Effect.fail(new IrohConflictError({ code: "endpoint_already_bound" }));
    }
    const activeUser = this.bindings.filter((row) => row.userId === input.userId && !row.revokedAt);
    if (activeUser.length >= 32) return Effect.fail(new IrohQuotaExceededError({ code: "too_many_bindings", retryAfterSeconds: 86_400 }));
    const activeDevice = activeUser.filter((row) => row.deviceUuid === input.payload.deviceId);
    if (activeDevice.length >= 8 && !input.deviceLimitOverrideAllowed) {
      return Effect.fail(new IrohQuotaExceededError({ code: "too_many_device_bindings", retryAfterSeconds: 86_400 }));
    }
    const inserted = binding({
      userId: input.userId,
      deviceUuid: input.payload.deviceId,
      appInstanceId: input.payload.appInstanceId,
      tag: input.payload.tag,
      platform: input.payload.platform,
      displayName: input.payload.displayName ?? null,
      endpointId: input.payload.endpointId,
      identityGeneration: input.payload.identityGeneration,
      pairingEnabled: input.payload.pairingEnabled,
      capabilities: [...input.payload.capabilities],
      pathHints: [...input.payload.pathHints],
      deviceLimitOverrideUsed: activeDevice.length >= 8,
      registeredAt: input.now,
      updatedAt: input.now,
      lastSeenAt: input.now,
    });
    challenge.consumedAt = input.now;
    this.bindings.push(inserted);
    return Effect.succeed({ binding: inserted, created: true });
  }

  discoverySnapshot(input: Parameters<IrohRepositoryShape["discoverySnapshot"]>[0]) {
    return Effect.promise(async () => {
      await this.beforeDiscoverySnapshot?.();
      return {
        bindings: this.bindings.filter((row) => row.userId === input.userId && !row.revokedAt),
        lanDiscoveryGeneration: this.lanGenerations.get(input.userId) ?? 1,
      };
    });
  }

  findActiveBindings(userId: string, bindingIds: readonly string[]) {
    return Effect.succeed(this.bindings.filter((row) =>
      row.userId === userId && bindingIds.includes(row.id) && !row.revokedAt));
  }

  revokeBinding(input: Parameters<IrohRepositoryShape["revokeBinding"]>[0]) {
    const row = this.bindings.find((candidate) =>
      candidate.id === input.bindingId && candidate.userId === input.userId);
    if (!row) return Effect.succeed(false);
    if (row.revokedAt) return Effect.succeed(true);
    row.revokedAt = input.now;
    row.revokedReason = "user_requested";
    this.lanGenerations.set(input.userId, (this.lanGenerations.get(input.userId) ?? 1) + 1);
    return Effect.succeed(true);
  }

  pruneExpiredState(input: Parameters<IrohRepositoryShape["pruneExpiredState"]>[0]) {
    for (const row of this.bindings.filter((candidate) => candidate.userId === input.userId)) {
      row.pathHints = row.pathHints.filter((hint) => {
        const expiry = (hint as { expires_at?: unknown }).expires_at;
        return typeof expiry === "string" && new Date(expiry) > input.now;
      });
    }
    return Effect.void;
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

  reserveRelayIssuance(input: Parameters<IrohRepositoryShape["reserveRelayIssuance"]>[0]) {
    const active = this.bindings.find((row) =>
      row.id === input.bindingId && row.userId === input.userId && !row.revokedAt);
    if (!active) return Effect.fail(new IrohNotFoundError({ resource: "binding" }));
    const recent = this.relayIssuances.filter((row) =>
      row.bindingId === active.id && row.requestedAt > new Date(input.now.getTime() - 10 * 60 * 1_000));
    if (recent.length >= 3) {
      return Effect.fail(new IrohQuotaExceededError({ code: "relay_endpoint_10m_quota", retryAfterSeconds: 600 }));
    }
    const issuanceId = randomUUID();
    this.relayIssuances.push({ id: issuanceId, userId: input.userId, bindingId: active.id, requestedAt: input.now, status: "pending" });
    return Effect.succeed({ issuanceId, binding: active });
  }

  completeRelayIssuance(input: Parameters<IrohRepositoryShape["completeRelayIssuance"]>[0]) {
    const row = this.relayIssuances.find((candidate) => candidate.id === input.issuanceId);
    const active = this.bindings.find((candidate) =>
      candidate.id === input.bindingId &&
      candidate.userId === input.userId &&
      candidate.endpointId === input.endpointId &&
      !candidate.revokedAt);
    if (!row || !active) {
      if (row) row.status = "failed";
      return Effect.succeed(false);
    }
    row.status = "succeeded";
    return Effect.succeed(true);
  }

  failRelayIssuance(input: Parameters<IrohRepositoryShape["failRelayIssuance"]>[0]) {
    const row = this.relayIssuances.find((candidate) => candidate.id === input.issuanceId);
    if (row) row.status = "failed";
    return Effect.void;
  }
}

class FakeMinter implements IrohRelayMinterShape {
  calls = 0;
  afterMint: (() => void) | undefined;
  constructor(private readonly fail: boolean) {}

  mint(input: Parameters<IrohRelayMinterShape["mint"]>[0]) {
    this.calls += 1;
    if (this.fail) return Effect.fail(new IrohRelayMintError({ code: "test_failure" }));
    const result = {
      token: `relay-token-${this.calls}-with-safe-length`,
      expiresAt: new Date(input.now.getTime() + IROH_RELAY_TOKEN_LIFETIME_SECONDS * 1_000),
    };
    this.afterMint?.();
    return Effect.succeed(result);
  }
}

function makeFixture(options: {
  repository?: MemoryRepository;
  minterFailure?: boolean;
  appInstanceId?: string;
  deviceId?: string;
  identityGeneration?: number;
  relayPreference?: RelayPreference;
  registrationPathHints?: IrohRegistrationPayload["pathHints"];
} = {}) {
  const endpointKeys = generateKeyPairSync("ed25519");
  const grantKeys = generateKeyPairSync("ed25519");
  const previousKeys = generateKeyPairSync("ed25519");
  const endpointPublicDer = endpointKeys.publicKey.export({ format: "der", type: "spki" });
  const endpointId = Buffer.from(endpointPublicDer).subarray(-32).toString("hex");
  const repository = options.repository ?? new MemoryRepository();
  const minter = new FakeMinter(options.minterFailure ?? false);
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
    deviceLimitOverrideEnabled: false,
    relayMinterInsecureLoopbackOptIn: false,
    deviceLimitOverrideUserIds: new Set(),
    deviceLimitOverrideEnvironments: new Set(),
    deploymentEnvironment: "test",
    isVercelDeployment: false,
  };
  let relayPreference = options.relayPreference ?? {
    mode: "automatic" as const,
    selectedManagedRelayIds: [],
    customRelays: [],
  };
  const broker = makeIrohTrustBroker(repository, minter, config, {
    getPreference: () => Effect.succeed({ preference: relayPreference, revision: 0 }),
  });

  return {
    repository,
    minter,
    broker,
    config,
    endpointId,
    appInstanceId,
    deviceId,
    identityGeneration,
    setRelayPreference(next: RelayPreference) {
      relayPreference = next;
    },
    async signedRegistration(platform: "mac" | "ios" = "mac") {
      const payload: IrohRegistrationPayload = {
        route_contract_version: 1,
        deviceId,
        appInstanceId,
        tag: "stable",
        platform,
        displayName: "Test Mac",
        endpointId,
        identityGeneration,
        pairingEnabled: true,
        capabilities: ["terminal", "artifacts"],
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
        tag: payload.tag,
        endpointId,
        identityGeneration,
        payloadSha256: sha256(payloadBytes),
      }, NOW)) as { challenge_id: string; nonce: string };
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
    tag: "stable",
    platform: "mac",
    displayName: null,
    endpointId: randomUUID().replaceAll("-", "").repeat(2),
    identityGeneration: 1,
    pairingEnabled: true,
    capabilities: [],
    pathHints: [],
    pathHintsNextExpiry: null,
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
