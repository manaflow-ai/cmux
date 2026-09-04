import { createHash, randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import type { ProviderId } from "./drivers";
import { vmPrivateNetworkEnabled, type VmRuntimeEnv } from "./config";
import {
  VmAccessGrantRevokedError,
  VmAccessGrantMutationBusyError,
  VmPrivateNetworkUnavailableError,
  VmTunnelNotFoundError,
  type VmDatabaseError,
} from "./errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "./providerGateway";
import {
  VmRepository,
  type CloudVmNetworkRow,
  type CloudVmTunnelRow,
  type VmRepositoryShape,
} from "./repository";

/**
 * Private networking: one provider network per cmux account, and one WireGuard
 * tunnel per computer the account signs in from.
 *
 * The shape of the feature is "the user's machines and the user's computers are
 * on one network, and nothing else is". Machines join at create; computers join
 * by enrolling a tunnel here. Because the machines then need no public inbound
 * port, an account with no tunnel up cannot reach its own machines — which is
 * the point, and is why every client is expected to bring a tunnel up before
 * attaching rather than treating it as an optional extra.
 *
 * The private half of a tunnel's keypair is generated on the user's computer
 * and never sent here, so nothing this module stores or returns can be used to
 * impersonate a device.
 */

/** A tunnel's client-facing state: everything needed to bring a WireGuard interface up. */
export type VmTunnelDescriptor = {
  readonly accessGrantId: string;
  readonly tunnelId: string;
  readonly provider: ProviderId;
  readonly deviceFingerprint: string;
  readonly tunnelPurpose: "terminal" | "browser";
  readonly deviceName: string | null;
  /**
   * WireGuard configuration text with a blank `PrivateKey` line. The client
   * fills that line in from its own keystore; the server has never seen the
   * key and cannot reconstruct it.
   */
  readonly clientConfig: string;
  readonly clientPublicKey: string;
  readonly serverPublicKey: string;
  readonly endpointHost: string | null;
  readonly endpointPort: number;
  /** The ranges the client routes through the tunnel (its `AllowedIPs`). */
  readonly routes: readonly string[];
  /** The tunnel's address inside the network — what the account's machines see it as. */
  readonly addressV4: string | null;
  readonly addressV6: string | null;
  readonly network: {
    readonly id: string;
    readonly cidr: string | null;
    readonly cidrV6: string | null;
  };
  /** True when this call created the tunnel rather than reading an existing one. */
  readonly created: boolean;
  /** True when the client's key did not match the record and the tunnel's keys were replaced. */
  readonly rotated: boolean;
};

/**
 * A WireGuard public key as the client sends it: 32 bytes, standard base64,
 * so exactly 44 characters ending in `=`.
 *
 * Validated here rather than at the provider so a typo is a 400 from cmux with
 * a usable message, not an opaque provider rejection halfway through enrolling.
 */
export function isWireGuardPublicKey(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (!/^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw]=$/.test(trimmed)) return false;
  return Buffer.from(trimmed, "base64").length === 32;
}

/**
 * The provider-side slug for an account's network.
 *
 * Hashed rather than derived from the user id directly: cmux's provider account
 * is shared by every cmux user, so slugs are visible to whoever reads that
 * account's resource list, and a raw Stack Auth user id there would be an
 * avoidable identifier leak. The hash is stable, so the same account always
 * resolves to the same network without a lookup.
 */
export function networkSlugForUser(userId: string): string {
  return `cmux-net-${accountHash("network", userId)}`;
}

/** The provider-side slug for one of an account's computers. Same reasoning as the network slug. */
export function tunnelSlugForDevice(
  userId: string,
  deviceFingerprint: string,
  tunnelPurpose: "terminal" | "browser" = "browser",
): string {
  return `cmux-wg-${accountHash("tunnel", `${userId}\0${deviceFingerprint}\0${tunnelPurpose}`)}`;
}

function accountHash(domain: string, value: string): string {
  return createHash("sha256").update(`cmux:${domain}:`).update(value).digest("hex").slice(0, 32);
}

/**
 * Why private networking is unavailable for `provider`, or null when it works.
 *
 * Both reasons are deployment-level rather than per-request: the provider does
 * not implement it, or an operator turned it off. Neither is retryable, so
 * callers surface it and stop instead of backing off.
 */
export function privateNetworkUnavailableReason(
  provider: ProviderId,
  supportsPrivateNetworking: boolean,
  env: VmRuntimeEnv = process.env,
): string | null {
  if (!vmPrivateNetworkEnabled(env)) {
    return "Cloud VM private networking is disabled for this environment";
  }
  if (!supportsPrivateNetworking) {
    return `${provider} does not serve private networks`;
  }
  return null;
}

type PrivateNetworkGateway = {
  readonly ensureNetwork: NonNullable<VmProviderGatewayShape["ensureNetwork"]>;
};

type PrivateNetworkingGateway = PrivateNetworkGateway & {
  readonly createTunnel: NonNullable<VmProviderGatewayShape["createTunnel"]>;
  readonly getTunnel: NonNullable<VmProviderGatewayShape["getTunnel"]>;
  readonly rotateTunnelKey: NonNullable<VmProviderGatewayShape["rotateTunnelKey"]>;
  readonly deleteTunnel: NonNullable<VmProviderGatewayShape["deleteTunnel"]>;
};

type PrivateNetworkRepo = {
  readonly findNetwork: NonNullable<VmRepositoryShape["findNetwork"]>;
  readonly upsertNetwork: NonNullable<VmRepositoryShape["upsertNetwork"]>;
};

type PrivateNetworkingRepo = PrivateNetworkRepo & {
  readonly findTunnel: NonNullable<VmRepositoryShape["findTunnel"]>;
  readonly listUserTunnels: NonNullable<VmRepositoryShape["listUserTunnels"]>;
  readonly insertTunnel: NonNullable<VmRepositoryShape["insertTunnel"]>;
  readonly updateTunnel: NonNullable<VmRepositoryShape["updateTunnel"]>;
  readonly revokeTunnel: NonNullable<VmRepositoryShape["revokeTunnel"]>;
};

type PrivateAccessRepo = PrivateNetworkingRepo & {
  readonly findAccessGrant: NonNullable<VmRepositoryShape["findAccessGrant"]>;
  readonly findBlockingRevokedAccessGrant: NonNullable<VmRepositoryShape["findBlockingRevokedAccessGrant"]>;
  readonly listUserAccessGrants: NonNullable<VmRepositoryShape["listUserAccessGrants"]>;
  readonly upsertAccessGrant: NonNullable<VmRepositoryShape["upsertAccessGrant"]>;
  readonly upsertAccessGrantSession: NonNullable<VmRepositoryShape["upsertAccessGrantSession"]>;
  readonly listAccessGrantSessionIds: NonNullable<VmRepositoryShape["listAccessGrantSessionIds"]>;
  readonly renameAccessGrant: NonNullable<VmRepositoryShape["renameAccessGrant"]>;
  readonly listAccessGrantTunnels: NonNullable<VmRepositoryShape["listAccessGrantTunnels"]>;
  readonly claimAccessGrantMutation: NonNullable<VmRepositoryShape["claimAccessGrantMutation"]>;
  readonly releaseAccessGrantMutation: NonNullable<VmRepositoryShape["releaseAccessGrantMutation"]>;
  readonly revokeAccessGrant: NonNullable<VmRepositoryShape["revokeAccessGrant"]>;
};

/**
 * The gateway/repo members this module needs, or null when the running
 * composition lacks any of them. The members are declared optional only so
 * older test doubles compile; the live layers always provide them, so a null
 * here means "this composition has no private networking", not an error.
 */
function privateNetworkGateway(gateway: VmProviderGatewayShape, provider: ProviderId): PrivateNetworkGateway | null {
  if (!gateway.supportsPrivateNetworking?.(provider)) return null;
  const { ensureNetwork } = gateway;
  if (!ensureNetwork) return null;
  return { ensureNetwork };
}

function privateNetworkingGateway(gateway: VmProviderGatewayShape, provider: ProviderId): PrivateNetworkingGateway | null {
  const network = privateNetworkGateway(gateway, provider);
  const { createTunnel, getTunnel, rotateTunnelKey, deleteTunnel } = gateway;
  if (!network || !createTunnel || !getTunnel || !rotateTunnelKey || !deleteTunnel) return null;
  const { ensureNetwork } = network;
  return { ensureNetwork, createTunnel, getTunnel, rotateTunnelKey, deleteTunnel };
}

function privateNetworkRepo(repo: VmRepositoryShape): PrivateNetworkRepo | null {
  const { findNetwork, upsertNetwork } = repo;
  if (!findNetwork || !upsertNetwork) return null;
  return { findNetwork, upsertNetwork };
}

function privateNetworkingRepo(repo: VmRepositoryShape): PrivateNetworkingRepo | null {
  const network = privateNetworkRepo(repo);
  const { findTunnel, listUserTunnels, insertTunnel, updateTunnel, revokeTunnel } = repo;
  if (!network || !findTunnel || !listUserTunnels || !insertTunnel || !updateTunnel || !revokeTunnel) return null;
  const { findNetwork, upsertNetwork } = network;
  return { findNetwork, upsertNetwork, findTunnel, listUserTunnels, insertTunnel, updateTunnel, revokeTunnel };
}

function privateAccessRepo(repo: VmRepositoryShape): PrivateAccessRepo | null {
  const networking = privateNetworkingRepo(repo);
  const {
    findAccessGrant,
    findBlockingRevokedAccessGrant,
    listUserAccessGrants,
    upsertAccessGrant,
    upsertAccessGrantSession,
    listAccessGrantSessionIds,
    renameAccessGrant,
    listAccessGrantTunnels,
    claimAccessGrantMutation,
    releaseAccessGrantMutation,
    revokeAccessGrant,
  } = repo;
  if (
    !networking || !findAccessGrant || !findBlockingRevokedAccessGrant
    || !listUserAccessGrants || !upsertAccessGrant || !upsertAccessGrantSession
    || !listAccessGrantSessionIds || !renameAccessGrant
    || !listAccessGrantTunnels || !claimAccessGrantMutation
    || !releaseAccessGrantMutation || !revokeAccessGrant
  ) return null;
  return {
    ...networking,
    findAccessGrant,
    findBlockingRevokedAccessGrant,
    listUserAccessGrants,
    upsertAccessGrant,
    upsertAccessGrantSession,
    listAccessGrantSessionIds,
    renameAccessGrant,
    listAccessGrantTunnels,
    claimAccessGrantMutation,
    releaseAccessGrantMutation,
    revokeAccessGrant,
  };
}

// One mutation can read and then rotate or replace a peer. Each Freestyle API
// call has a 60-second deadline, so the fence must cover two serial calls plus
// database work. A crashed request becomes retryable after this bound.
const ACCESS_GRANT_MUTATION_LEASE_MS = 3 * 60_000;

/**
 * Serializes provider peer mutations for one physical Mac across serverless
 * instances. A crashed request releases the fence by expiry; a successful
 * request releases it immediately. We return busy instead of doing an
 * unfenced provider call.
 */
function withAccessGrantMutationLease<A, E, R>(
  repo: PrivateAccessRepo,
  accessGrantId: string,
  operation: Effect.Effect<A, E, R>,
) {
  return Effect.gen(function* () {
    const leaseId = randomUUID();
    const now = new Date();
    const claimed = yield* repo.claimAccessGrantMutation({
      id: accessGrantId,
      leaseId,
      now,
      leaseExpiresAt: new Date(now.getTime() + ACCESS_GRANT_MUTATION_LEASE_MS),
    });
    if (!claimed) {
      return yield* Effect.fail(new VmAccessGrantMutationBusyError({ accessGrantId }));
    }
    return yield* operation.pipe(Effect.ensuring(
      repo.releaseAccessGrantMutation({ id: accessGrantId, leaseId }).pipe(Effect.ignore),
    ));
  });
}

/**
 * The account's network, provisioning it on first use.
 *
 * Fails closed when private networking is unavailable. Cloud machines must not
 * be created with public ingress as a degraded path.
 */
export function resolveOwnerNetwork(input: {
  readonly userId: string;
  readonly provider: ProviderId;
}): Effect.Effect<
  CloudVmNetworkRow,
  VmDatabaseError | VmPrivateNetworkUnavailableError | import("./errors").VmProviderOperationError,
  VmRepository | VmProviderGateway
> {
  return Effect.gen(function* () {
    const gateway = yield* VmProviderGateway;
    const providers = privateNetworkGateway(gateway, input.provider);
    const repo = privateNetworkRepo(yield* VmRepository);
    const reason = privateNetworkUnavailableReason(input.provider, !!providers);
    if (!providers || !repo || reason) {
      return yield* Effect.fail(
        new VmPrivateNetworkUnavailableError({
          provider: input.provider,
          reason: reason ?? "the VM repository composition has no private-network state",
        }),
      );
    }
    const existing = yield* repo.findNetwork(input.userId, input.provider);
    if (existing) return existing;

    const slug = networkSlugForUser(input.userId);
    const network = yield* providers.ensureNetwork(input.provider, {
      slug,
      displayName: "cmux machines",
    });
    // The provider call is idempotent by slug and the upsert is idempotent by
    // (user, provider), so two machines created at once converge on one row
    // and one network rather than racing to provision a second.
    return yield* repo.upsertNetwork({
      userId: input.userId,
      provider: input.provider,
      providerNetworkId: network.id,
      slug: network.slug ?? slug,
      cidr: network.cidr,
      cidrV6: network.cidrV6,
    });
  });
}

/** Compatibility name for callers that need the owner's mandatory network. */
export function requireOwnerNetwork(input: {
  readonly userId: string;
  readonly provider: ProviderId;
}): Effect.Effect<
  CloudVmNetworkRow,
  VmDatabaseError | VmPrivateNetworkUnavailableError | import("./errors").VmProviderOperationError,
  VmRepository | VmProviderGateway
> {
  return Effect.gen(function* () {
    return yield* resolveOwnerNetwork(input);
  });
}

/**
 * Enroll (or re-read) this computer's tunnel into the account's network.
 *
 * Idempotent per device: calling it again with the same public key returns the
 * same tunnel and the same config, which is what lets a client call it on every
 * launch instead of tracking whether it has enrolled before. A *different*
 * public key for a known device means the client lost its private key — a
 * reinstall, a wiped Keychain — so the tunnel's keys are rotated in place,
 * keeping its id and its address inside the network. That address is what the
 * account's machines and any firewall rules know it by, so replacing the
 * tunnel instead of rotating it would silently change the device's identity on
 * the network.
 */
export function enrollVmTunnel(input: {
  readonly userId: string;
  readonly provider: ProviderId;
  readonly deviceId: string;
  readonly deviceFingerprint: string;
  readonly tunnelPurpose: "terminal" | "browser";
  readonly deviceName?: string | null;
  readonly modelIdentifier?: string | null;
  readonly osVersion?: string | null;
  readonly architecture?: string | null;
  readonly cmuxVersion?: string | null;
  readonly cmuxBuild?: string | null;
  readonly cmuxChannel?: string | null;
  readonly stackSessionId?: string | null;
  readonly sessionIssuedAt?: Date | null;
  readonly clientPublicKey: string;
}) {
  return Effect.gen(function* () {
    const providers = yield* requirePrivateNetworkingGateway(input.provider);
    const repo = yield* requirePrivateAccessRepo(input.provider);
    const network = yield* requireOwnerNetwork({ userId: input.userId, provider: input.provider });
    const clientPublicKey = input.clientPublicKey.trim();
    if (input.stackSessionId && input.sessionIssuedAt) {
      const revokedSession = yield* repo.findBlockingRevokedAccessGrant({
        userId: input.userId,
        deviceId: input.deviceId,
        stackSessionId: input.stackSessionId,
        sessionIssuedAt: input.sessionIssuedAt,
      });
      if (revokedSession) {
        return yield* Effect.fail(new VmAccessGrantRevokedError({
          stackSessionId: input.stackSessionId,
        }));
      }
    }
    const accessGrant = yield* repo.upsertAccessGrant({
      userId: input.userId,
      deviceId: input.deviceId,
      reportedName: input.deviceName,
      modelIdentifier: input.modelIdentifier,
      osVersion: input.osVersion,
      architecture: input.architecture,
      cmuxVersion: input.cmuxVersion,
      cmuxBuild: input.cmuxBuild,
      cmuxChannel: input.cmuxChannel,
    });
    return yield* withAccessGrantMutationLease(repo, accessGrant.id, Effect.gen(function* () {
      // Recheck after the lease. A revoke can win between the first session
      // check and the access-grant upsert; an old login must not continue.
      if (input.stackSessionId && input.sessionIssuedAt) {
        const revokedSession = yield* repo.findBlockingRevokedAccessGrant({
          userId: input.userId,
          deviceId: input.deviceId,
          stackSessionId: input.stackSessionId,
          sessionIssuedAt: input.sessionIssuedAt,
        });
        if (revokedSession) {
          return yield* Effect.fail(new VmAccessGrantRevokedError({
            stackSessionId: input.stackSessionId,
          }));
        }
        yield* repo.upsertAccessGrantSession({
          accessGrantId: accessGrant.id,
          userId: input.userId,
          stackSessionId: input.stackSessionId,
          sessionIssuedAt: input.sessionIssuedAt,
        });
      }

      const existing = yield* repo.findTunnel({
        userId: input.userId,
        deviceFingerprint: input.deviceFingerprint,
        tunnelPurpose: input.tunnelPurpose,
      });

      if (existing) {
        const live = yield* providers.getTunnel(
          input.provider,
          existing.providerTunnelId,
          network.providerNetworkId,
        );
        if (live) {
          const rotated = live.clientPublicKey.trim() !== clientPublicKey;
          const current = rotated
            ? yield* providers.rotateTunnelKey(
              input.provider,
              existing.providerTunnelId,
              clientPublicKey,
              network.providerNetworkId,
            )
            : live;
          const row = yield* repo.updateTunnel({
            id: existing.id,
            clientPublicKey: current.clientPublicKey,
            deviceName: input.deviceName ?? existing.deviceName,
            addressV4: current.addressV4,
            addressV6: current.addressV6,
            configIssued: true,
          });
          return describeTunnel(current, row, network, { created: false, rotated });
        }
        // The control plane has a row for a tunnel the provider no longer has.
        yield* repo.revokeTunnel(existing.id);
      }

      const created = yield* providers.createTunnel(input.provider, {
        slug: tunnelSlugForDevice(input.userId, input.deviceFingerprint, input.tunnelPurpose),
        displayName: input.deviceName?.trim() || "cmux computer",
        clientPublicKey,
        networkId: network.providerNetworkId,
      });
      const row = yield* repo.insertTunnel({
        userId: input.userId,
        networkId: network.id,
        provider: input.provider,
        providerTunnelId: created.id,
        accessGrantId: accessGrant.id,
        deviceFingerprint: input.deviceFingerprint,
        tunnelPurpose: input.tunnelPurpose,
        deviceName: input.deviceName ?? null,
        clientPublicKey: created.clientPublicKey,
        addressV4: created.addressV4,
        addressV6: created.addressV6,
      });
      return describeTunnel(created, row, network, { created: true, rotated: false });
    }));
  });
}

/** This computer's tunnel as it currently stands, without enrolling one. */
export function readVmTunnel(input: {
  readonly userId: string;
  readonly provider: ProviderId;
  readonly deviceFingerprint: string;
  readonly tunnelPurpose: "terminal" | "browser";
}) {
  return Effect.gen(function* () {
    const providers = yield* requirePrivateNetworkingGateway(input.provider);
    const repo = yield* requirePrivateNetworkingRepo(input.provider);
    const network = yield* requireOwnerNetwork({ userId: input.userId, provider: input.provider });
    const existing = yield* repo.findTunnel({
      userId: input.userId,
      deviceFingerprint: input.deviceFingerprint,
      tunnelPurpose: input.tunnelPurpose,
    });
    if (!existing) {
      return yield* Effect.fail(
        new VmTunnelNotFoundError({ deviceFingerprint: input.deviceFingerprint }),
      );
    }
    const live = yield* providers.getTunnel(
      input.provider,
      existing.providerTunnelId,
      network.providerNetworkId,
    );
    if (!live) {
      yield* repo.revokeTunnel(existing.id);
      return yield* Effect.fail(
        new VmTunnelNotFoundError({ deviceFingerprint: input.deviceFingerprint }),
      );
    }
    return describeTunnel(live, existing, network, { created: false, rotated: false });
  });
}

/**
 * Unenroll a computer: the provider tunnel is deleted and the row marked
 * revoked. Any client still holding that config loses access immediately, which
 * is what makes this the sign-out and lost-laptop path.
 */
export function revokeVmTunnel(input: {
  readonly userId: string;
  readonly provider: ProviderId;
  readonly deviceFingerprint: string;
  readonly tunnelPurpose: "terminal" | "browser";
}) {
  return Effect.gen(function* () {
    const providers = yield* requirePrivateNetworkingGateway(input.provider);
    const repo = yield* requirePrivateNetworkingRepo(input.provider);
    const existing = yield* repo.findTunnel({
      userId: input.userId,
      deviceFingerprint: input.deviceFingerprint,
      tunnelPurpose: input.tunnelPurpose,
    });
    if (!existing) return { revoked: false } as const;
    // Provider first: a row revoked before the provider call would leave a live
    // tunnel nothing points at, and the config the client holds would keep
    // working with no record that it exists.
    yield* providers.deleteTunnel(input.provider, existing.providerTunnelId);
    const revoked = yield* repo.revokeTunnel(existing.id);
    return { revoked } as const;
  });
}

/** Revoke one Mac and every Freestyle peer owned by its Cloud access grant. */
export function revokeVmAccessGrant(input: {
  readonly userId: string;
  readonly accessGrantId?: string;
  readonly deviceId?: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* requirePrivateAccessRepo("freestyle");
    const grant = yield* repo.findAccessGrant({
      userId: input.userId,
      accessGrantId: input.accessGrantId,
      deviceId: input.deviceId,
    });
    if (!grant) return { revoked: false, stackSessionIds: [] as string[] } as const;
    return yield* withAccessGrantMutationLease(repo, grant.id, Effect.gen(function* () {
      const gateway = yield* VmProviderGateway;
      const stackSessionIds = yield* repo.listAccessGrantSessionIds(grant.id);
      const tunnels = yield* repo.listAccessGrantTunnels(grant.id);
      for (const tunnel of tunnels) {
        if (gateway.deleteTunnel) {
          yield* gateway.deleteTunnel(tunnel.provider, tunnel.providerTunnelId);
        }
        yield* repo.revokeTunnel(tunnel.id);
      }
      const revoked = yield* repo.revokeAccessGrant(grant.id);
      return { revoked, stackSessionIds } as const;
    }));
  });
}

/** Cloud-only Mac records for cmux.com. No iOS or Iroh rows are read. */
export function listVmAccessGrants(input: { readonly userId: string }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const grants = repo.listUserAccessGrants
      ? yield* repo.listUserAccessGrants(input.userId)
      : [];
    const tunnels = repo.listUserTunnels
      ? yield* repo.listUserTunnels(input.userId)
      : [];
    return grants.map((grant) => ({
      id: grant.id,
      deviceId: grant.deviceId,
      name: grant.displayName ?? grant.reportedName ?? "Mac",
      reportedName: grant.reportedName,
      displayName: grant.displayName,
      modelIdentifier: grant.modelIdentifier,
      osVersion: grant.osVersion,
      architecture: grant.architecture,
      cmuxVersion: grant.cmuxVersion,
      cmuxBuild: grant.cmuxBuild,
      cmuxChannel: grant.cmuxChannel,
      createdAt: grant.createdAt.getTime(),
      lastControlPlaneAt: grant.lastControlPlaneAt.getTime(),
      tunnelPurposes: tunnels
        .filter((tunnel) => tunnel.accessGrantId === grant.id)
        .map((tunnel) => tunnel.tunnelPurpose)
        .sort(),
    }));
  });
}

export function renameVmAccessGrant(input: {
  readonly userId: string;
  readonly accessGrantId: string;
  readonly displayName: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* requirePrivateAccessRepo("freestyle");
    return yield* repo.renameAccessGrant({
      id: input.accessGrantId,
      userId: input.userId,
      displayName: input.displayName,
    });
  });
}

/** Every computer currently enrolled on the account, for a "your computers" list. */
export function listVmTunnels(input: { readonly userId: string }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const rows = repo.listUserTunnels ? yield* repo.listUserTunnels(input.userId) : [];
    return rows.map((row) => ({
      tunnelId: row.providerTunnelId,
      accessGrantId: row.accessGrantId,
      provider: row.provider,
      deviceFingerprint: row.deviceFingerprint,
      tunnelPurpose: row.tunnelPurpose,
      deviceName: row.deviceName,
      addressV4: row.addressV4,
      addressV6: row.addressV6,
      createdAt: row.createdAt.getTime(),
      lastConfigIssuedAt: row.lastConfigIssuedAt?.getTime() ?? null,
    }));
  });
}

/**
 * Account-deletion cleanup: delete every provider tunnel and the account's
 * network, then the rows. Failure-tolerant in the same spirit as the rest of
 * the deletion flow — a provider resource that is already gone counts as
 * cleaned, and a network delete that fails because the provider still holds
 * attached machines is retried by the caller's next deletion pass.
 */
export function deletePrivateNetworkingForAccountDeletion(userId: string) {
  return Effect.gen(function* () {
    const repo = privateNetworkingRepo(yield* VmRepository);
    const gateway = yield* VmProviderGateway;
    const repoFull = yield* VmRepository;
    if (!repo || !repoFull.deleteNetwork) return { tunnels: 0, networks: 0 };

    let tunnels = 0;
    const rows = yield* repo.listUserTunnels(userId);
    for (const row of rows) {
      if (gateway.deleteTunnel) {
        yield* gateway.deleteTunnel(row.provider, row.providerTunnelId);
      }
      yield* repo.revokeTunnel(row.id);
      tunnels += 1;
    }

    let networks = 0;
    // One network per provider; Freestyle is the only provider today, and the
    // list stays a list so a future second provider extends it rather than
    // rediscovering this loop.
    const providers: readonly ProviderId[] = ["freestyle"];
    for (const provider of providers) {
      const network = yield* repo.findNetwork(userId, provider);
      if (!network) continue;
      if (gateway.deleteNetwork) {
        // Every machine and tunnel must already be gone or the provider
        // refuses; the caller sequences this after VM destroy for that reason.
        yield* gateway.deleteNetwork(provider, network.providerNetworkId);
      }
      yield* repoFull.deleteNetwork(network.id);
      networks += 1;
    }
    return { tunnels, networks };
  });
}

function requirePrivateNetworkingGateway(provider: ProviderId) {
  return Effect.gen(function* () {
    const gateway = privateNetworkingGateway(yield* VmProviderGateway, provider);
    if (!gateway) {
      return yield* Effect.fail(
        new VmPrivateNetworkUnavailableError({
          provider,
          reason: `${provider} does not serve private networks`,
        }),
      );
    }
    return gateway;
  });
}

function requirePrivateNetworkingRepo(provider: ProviderId) {
  return Effect.gen(function* () {
    const repo = privateNetworkingRepo(yield* VmRepository);
    if (!repo) {
      return yield* Effect.fail(
        new VmPrivateNetworkUnavailableError({
          provider,
          reason: "the VM repository composition has no private-network state",
        }),
      );
    }
    return repo;
  });
}

function requirePrivateAccessRepo(provider: ProviderId) {
  return Effect.gen(function* () {
    const repo = privateAccessRepo(yield* VmRepository);
    if (!repo) {
      return yield* Effect.fail(
        new VmPrivateNetworkUnavailableError({
          provider,
          reason: "the VM repository composition has no Cloud access grant state",
        }),
      );
    }
    return repo;
  });
}

function describeTunnel(
  tunnel: import("./drivers").ProviderTunnel,
  row: CloudVmTunnelRow,
  network: CloudVmNetworkRow,
  flags: { readonly created: boolean; readonly rotated: boolean },
): VmTunnelDescriptor {
  return {
    accessGrantId: row.accessGrantId,
    tunnelId: tunnel.id,
    provider: row.provider,
    deviceFingerprint: row.deviceFingerprint,
    tunnelPurpose: row.tunnelPurpose,
    deviceName: row.deviceName,
    clientConfig: tunnel.clientConfig,
    clientPublicKey: tunnel.clientPublicKey,
    serverPublicKey: tunnel.serverPublicKey,
    endpointHost: tunnel.endpointHost,
    endpointPort: tunnel.endpointPort,
    routes: tunnel.routes,
    addressV4: tunnel.addressV4,
    addressV6: tunnel.addressV6,
    network: {
      id: network.providerNetworkId,
      cidr: network.cidr,
      cidrV6: network.cidrV6,
    },
    created: flags.created,
    rotated: flags.rotated,
  };
}
