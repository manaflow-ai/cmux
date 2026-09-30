import { createHash, randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import type { ProviderId } from "./drivers";
import { trace } from "@opentelemetry/api";
import { setSpanAttributes } from "../telemetry";
import { vmNetworkNamespace, vmNetworkSlugPrefix, vmPrivateNetworkEnabled, type VmRuntimeEnv } from "./config";

export { vmNetworkNamespace };
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
import { listTeamMemberIdsWithTimeout, type VmTeamDirectory } from "./teamDirectory";
import { isProviderTunnelNetworkOverlap } from "./providerErrors";
import { retryAfterNetworkReclaim } from "./networkCapacity";
import type { ProviderNetwork, ProviderTunnel } from "./drivers";

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
  readonly networks: ReadonlyArray<{
    readonly id: string;
    readonly cidr: string | null;
    readonly cidrV6: string | null;
    readonly scope: "user" | "team";
  }>;
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
  // The final Base64 sextet may be a digit. For a 32-byte value it is one of
  // the 16 characters whose low four bits are zero, including 0, 4, and 8.
  // Decode and re-encode as the canonical check instead of duplicating that
  // alphabet subset in a fragile regular expression.
  if (!/^[A-Za-z0-9+/]{43}=$/.test(trimmed)) return false;
  const decoded = Buffer.from(trimmed, "base64");
  return decoded.length === 32 && decoded.toString("base64") === trimmed;
}

function namespacedPrefix(kind: "net" | "team-net" | "wg", env: VmRuntimeEnv): string {
  return vmNetworkSlugPrefix(kind, vmNetworkNamespace(env));
}

/**
 * The provider-side slug for an account's network.
 *
 * Hashed rather than derived from the user id directly: cmux's provider account
 * is shared by every cmux user, so slugs are visible to whoever reads that
 * account's resource list, and a raw Stack Auth user id there would be an
 * avoidable identifier leak. The hash is stable, so the same account always
 * resolves to the same network without a lookup. See {@link vmNetworkNamespace}
 * for the deployment prefix.
 */
export function networkSlugForUser(userId: string, env: VmRuntimeEnv = process.env): string {
  return `${namespacedPrefix("net", env)}-${accountHash("network", userId)}`;
}

/**
 * The pool new production user networks take their IPv4 range from, and the
 * size of each range.
 *
 * A /20 holds 4,094 members against the platform default's 254; the network
 * that failed held 255 (85 machines and 170 tunnel attachments). The pool
 * sits inside 10.0.0.0/8, which every tunnel routes, and above the band the
 * platform derives its /24s from (10.16-10.95 so far), so a user's own /20
 * does not overlap the platform-derived team networks their tunnel also
 * attaches. Different users may share a range: provider address reservations
 * are scoped to one network, and one tunnel only ever attaches its owner's
 * network plus team networks.
 */
const USER_NETWORK_POOL_BASE = (10 << 24) + (192 << 16);
const USER_NETWORK_POOL_SLOTS = 1024;
const USER_NETWORK_RANGE_SIZE = 4096;

/** The IPv4 /20 a production user's network is created with. */
export function userNetworkCidr(userId: string): string {
  const slot = Number.parseInt(accountHash("network-cidr", userId).slice(0, 8), 16) % USER_NETWORK_POOL_SLOTS;
  const base = USER_NETWORK_POOL_BASE + slot * USER_NETWORK_RANGE_SIZE;
  return `${[24, 16, 8, 0].map((shift) => (base >>> shift) & 255).join(".")}/20`;
}

/**
 * The provider-side slug for a team's network. Hashed for the same reason as
 * the account slug. Because it is derived from the team id, the provider's
 * network list is the only record of team networks: finding one is a read by
 * this slug, and no cmux table tracks them or their tunnel attachments.
 */
export function networkSlugForTeam(teamId: string, env: VmRuntimeEnv = process.env): string {
  return `${namespacedPrefix("team-net", env)}-${accountHash("team-network", teamId)}`;
}

/** The provider-side slug for one of an account's computers. Same reasoning as the network slug. */
export function tunnelSlugForDevice(
  userId: string,
  deviceFingerprint: string,
  tunnelPurpose: "terminal" | "browser" = "browser",
  env: VmRuntimeEnv = process.env,
): string {
  return `${namespacedPrefix("wg", env)}-${accountHash("tunnel", `${userId}\0${deviceFingerprint}\0${tunnelPurpose}`)}`;
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
  readonly getNetwork?: NonNullable<VmProviderGatewayShape["getNetwork"]>;
};

type PrivateNetworkingGateway = PrivateNetworkGateway & {
  readonly createTunnel: NonNullable<VmProviderGatewayShape["createTunnel"]>;
  readonly getTunnel: NonNullable<VmProviderGatewayShape["getTunnel"]>;
  readonly rotateTunnelKey: NonNullable<VmProviderGatewayShape["rotateTunnelKey"]>;
  readonly deleteTunnel: NonNullable<VmProviderGatewayShape["deleteTunnel"]>;
  readonly attachTunnelNetwork?: NonNullable<VmProviderGatewayShape["attachTunnelNetwork"]>;
  readonly detachTunnelNetwork?: NonNullable<VmProviderGatewayShape["detachTunnelNetwork"]>;
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
  const { ensureNetwork, getNetwork } = gateway;
  if (!ensureNetwork) return null;
  return { ensureNetwork, getNetwork };
}

function privateNetworkingGateway(gateway: VmProviderGatewayShape, provider: ProviderId): PrivateNetworkingGateway | null {
  const network = privateNetworkGateway(gateway, provider);
  const { createTunnel, getTunnel, rotateTunnelKey, deleteTunnel } = gateway;
  if (!network || !createTunnel || !getTunnel || !rotateTunnelKey || !deleteTunnel) return null;
  const { ensureNetwork, getNetwork } = network;
  return { ensureNetwork, getNetwork, createTunnel, getTunnel, rotateTunnelKey, deleteTunnel, attachTunnelNetwork: gateway.attachTunnelNetwork, detachTunnelNetwork: gateway.detachTunnelNetwork };
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

/** A team's network as the provider reports it. See {@link networkSlugForTeam}. */
export type TeamNetwork = {
  readonly providerNetworkId: string;
  readonly slug: string;
  readonly cidr: string | null;
  readonly cidrV6: string | null;
};

function teamNetworkFromProvider(network: ProviderNetwork, slug: string): TeamNetwork {
  return { providerNetworkId: network.id, slug: network.slug ?? slug, cidr: network.cidr, cidrV6: network.cidrV6 };
}

type TeamNetworkResolution = {
  readonly network: TeamNetwork | null;
  readonly fallbackReason: "no_capability" | "solo_team" | "not_member" | "directory_error" | "directory_timeout" | null;
};

function resolveTeamNetwork(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamDirectory?: VmTeamDirectory;
  readonly directoryTimeoutMs?: number;
  readonly provider: ProviderId;
  readonly providers: PrivateNetworkGateway;
}): Effect.Effect<TeamNetworkResolution, import("./errors").VmProviderOperationError> {
  return Effect.gen(function* () {
    if (!input.billingTeamId || input.billingTeamId === input.userId) return { network: null, fallbackReason: "solo_team" as const };
    const getNetwork = input.providers.getNetwork;
    if (!input.teamDirectory || !getNetwork) return { network: null, fallbackReason: "no_capability" as const };
    // Membership is checked before the provider read, and on reuse as well as
    // on create, so a caller who left the team never lands on its network.
    const result = yield* listTeamMemberIdsWithTimeout(input.teamDirectory, input.billingTeamId, input.directoryTimeoutMs);
    if ("error" in result) return { network: null, fallbackReason: result.error === "timeout" ? "directory_timeout" as const : "directory_error" as const };
    if (result.memberIds === null) return { network: null, fallbackReason: "directory_error" as const };
    if (!result.memberIds.includes(input.userId)) return { network: null, fallbackReason: "not_member" as const };
    const slug = networkSlugForTeam(input.billingTeamId);
    const existing = yield* getNetwork(input.provider, slug);
    if (existing) return { network: teamNetworkFromProvider(existing, slug), fallbackReason: null };
    if (result.memberIds.length <= 1) return { network: null, fallbackReason: "solo_team" as const };
    // No members-reach-each-other rule: each team VM admits the team network
    // itself, so tunnels reach team VMs but not each other's Macs.
    const network = yield* input.providers.ensureNetwork(input.provider, {
      slug,
      displayName: slug,
      membersRule: false,
    });
    return { network: teamNetworkFromProvider(network, slug), fallbackReason: null };
  });
}

/**
 * The network a new machine joins: the billing team's network when the client
 * routes team networks and the caller is a current member, otherwise the
 * account's own network, provisioned on first use.
 *
 * Fails closed when private networking is unavailable. Cloud machines must not
 * be created with public ingress as a degraded path.
 */
export function resolveOwnerNetwork(input: {
  readonly userId: string;
  readonly provider: ProviderId;
  readonly billingTeamId?: string | null;
  readonly teamDirectory?: VmTeamDirectory;
  readonly directoryTimeoutMs?: number;
}): Effect.Effect<
  (CloudVmNetworkRow | TeamNetwork) & { readonly memberIngress: boolean; readonly scope: "user" | "team" },
  VmDatabaseError | VmPrivateNetworkUnavailableError | import("./errors").VmProviderOperationError,
  VmRepository | VmProviderGateway
> {
  return Effect.gen(function* () {
    const { providers, repo } = yield* requireOwnerNetworkComposition(input.provider);
    const teamResolution = yield* resolveTeamNetwork({ ...input, providers });
    const span = trace.getActiveSpan();
    if (span) setSpanAttributes(span, teamResolution.network
      ? { "cmux.vm.network.scope": "team", "cmux.vm.network.team_fallback": false }
      : { "cmux.vm.network.scope": "user", "cmux.vm.network.team_fallback": teamResolution.fallbackReason ?? "no_capability" });
    if (teamResolution.network) return { ...teamResolution.network, memberIngress: true, scope: "team" as const };
    const network = yield* resolveUserNetwork(input, providers, repo);
    return { ...network, memberIngress: false, scope: "user" as const };
  });
}

/** The account's own network, which every tunnel enrolls into as its home. */
export function requireOwnerNetwork(input: {
  readonly userId: string;
  readonly provider: ProviderId;
}): Effect.Effect<
  CloudVmNetworkRow,
  VmDatabaseError | VmPrivateNetworkUnavailableError | import("./errors").VmProviderOperationError,
  VmRepository | VmProviderGateway
> {
  return Effect.gen(function* () {
    const { providers, repo } = yield* requireOwnerNetworkComposition(input.provider);
    return yield* resolveUserNetwork(input, providers, repo);
  });
}

function requireOwnerNetworkComposition(provider: ProviderId) {
  return Effect.gen(function* () {
    const providers = privateNetworkGateway(yield* VmProviderGateway, provider);
    const repo = privateNetworkRepo(yield* VmRepository);
    const reason = privateNetworkUnavailableReason(provider, !!providers);
    if (!providers || !repo || reason) {
      return yield* Effect.fail(new VmPrivateNetworkUnavailableError({
        provider,
        reason: reason ?? "the VM repository composition has no private-network state",
      }));
    }
    return { providers, repo };
  });
}

function resolveUserNetwork(
  input: { readonly userId: string; readonly provider: ProviderId },
  providers: PrivateNetworkGateway,
  repo: PrivateNetworkRepo,
) {
  return Effect.gen(function* () {
    const existing = yield* repo.findNetwork(input.userId, input.provider);
    if (existing) return existing;

    const slug = networkSlugForUser(input.userId);
    // Production networks get a /20 (see userNetworkCidr). A namespaced
    // deployment keeps the platform's account-unique /24: a Mac that runs a
    // production and a dev build routes both networks at once, and two
    // networks derived from the same user would otherwise overlap.
    const cidr = vmNetworkNamespace() === null ? userNetworkCidr(input.userId) : undefined;
    const network = yield* providers.ensureNetwork(input.provider, {
      slug,
      displayName: "cmux machines",
      ...(cidr ? { cidr } : {}),
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
  readonly teamIds?: readonly string[];
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

      const reclaim = { provider: input.provider, networkId: network.providerNetworkId };
      if (existing) {
        // Reading re-attaches a detached tunnel, which needs a free address.
        const live = yield* retryAfterNetworkReclaim(reclaim, providers.getTunnel(
          input.provider,
          existing.providerTunnelId,
          network.providerNetworkId,
        ));
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
          const teamNetworks = yield* reconcileTunnelTeamNetworks({ providers, tunnel: current, provider: input.provider, homeNetworkId: network.providerNetworkId, teamIds: teamNetworkCandidates(input) });
          return describeTunnel(current, row, network, { created: false, rotated }, teamNetworks);
        }
        // The control plane has a row for a tunnel the provider no longer has.
        yield* repo.revokeTunnel(existing.id);
      }

      const created = yield* retryAfterNetworkReclaim(reclaim, providers.createTunnel(input.provider, {
        slug: tunnelSlugForDevice(input.userId, input.deviceFingerprint, input.tunnelPurpose),
        displayName: input.deviceName?.trim() || "cmux computer",
        clientPublicKey,
        networkId: network.providerNetworkId,
      }));
      const row = yield* repo.insertTunnel({
        userId: input.userId,
        networkId: network.id,
        provider: input.provider,
        providerTunnelId: created.tunnel.id,
        accessGrantId: accessGrant.id,
        deviceFingerprint: input.deviceFingerprint,
        tunnelPurpose: input.tunnelPurpose,
        deviceName: input.deviceName ?? null,
        clientPublicKey: created.tunnel.clientPublicKey,
        addressV4: created.tunnel.addressV4,
        addressV6: created.tunnel.addressV6,
      });
      const teamNetworks = yield* reconcileTunnelTeamNetworks({ providers, tunnel: created.tunnel, provider: input.provider, homeNetworkId: network.providerNetworkId, teamIds: teamNetworkCandidates(input) });
      return describeTunnel(created.tunnel, row, network, { created: true, rotated: created.rotated }, teamNetworks);
    }));
  });
}

/** This computer's tunnel as it currently stands, without enrolling one. */
export function readVmTunnel(input: {
  readonly userId: string;
  readonly provider: ProviderId;
  readonly deviceFingerprint: string;
  readonly tunnelPurpose: "terminal" | "browser";
  readonly teamIds?: readonly string[];
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
    const teamNetworks = yield* reconcileTunnelTeamNetworks({ providers, tunnel: live, provider: input.provider, homeNetworkId: network.providerNetworkId, teamIds: teamNetworkCandidates(input) });
    return describeTunnel(live, existing, network, { created: false, rotated: false }, teamNetworks);
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

export function privateNetworkErrorDescription(error: unknown): string {
  const parts: string[] = [];
  const seen = new Set<unknown>();
  let current: unknown = error;
  for (let depth = 0; depth < 8 && current && !seen.has(current); depth += 1) {
    seen.add(current);
    if (typeof current !== "object") {
      if (typeof current === "string" && current.trim()) parts.push(current.trim());
      break;
    }
    const record = current as {
      readonly message?: unknown;
      readonly cause?: unknown;
      readonly code?: unknown;
      readonly status?: unknown;
      readonly statusCode?: unknown;
      readonly body?: { readonly code?: unknown };
      readonly response?: { readonly status?: unknown };
    };
    const status = [record.status, record.statusCode, record.response?.status].find((value): value is number => typeof value === "number");
    const code = typeof record.code === "string" || typeof record.code === "number"
      ? String(record.code)
      : typeof record.body?.code === "string" || typeof record.body?.code === "number"
        ? String(record.body.code)
        : undefined;
    const message = typeof record.message === "string" ? record.message.trim() : "";
    const detail = [status === undefined ? undefined : `status=${status}`, code ? `code=${code}` : undefined, message || undefined]
      .filter((value): value is string => value !== undefined)
      .join(" ");
    if (detail) parts.push(detail.slice(0, 300));
    current = record.cause;
  }
  return (parts.join(" <- ") || "unknown provider failure").slice(0, 1_000);
}

/** The caller's teams whose networks a tunnel should join; the personal team has none. */
function teamNetworkCandidates(input: { readonly userId: string; readonly teamIds?: readonly string[] }): readonly string[] | undefined {
  return input.teamIds?.filter((teamId) => teamId !== input.userId);
}

/**
 * Attach the tunnel to the network of every team the caller belongs to, and
 * detach it from team networks the caller has left. The provider's attachment
 * list is the record: a tunnel is attached exactly when Freestyle says so, and
 * deleting a tunnel removes its attachments with it.
 *
 * A failed attach is logged and skipped so enrollment never fails on it. When a
 * team network lookup fails, stale attachments are kept, because the failed
 * lookup might have been a network the caller still belongs to.
 */
function reconcileTunnelTeamNetworks(input: {
  readonly providers: PrivateNetworkingGateway;
  readonly tunnel: ProviderTunnel;
  readonly provider: ProviderId;
  readonly homeNetworkId: string;
  readonly teamIds?: readonly string[];
}): Effect.Effect<TeamNetwork[], never> {
  return Effect.gen(function* () {
    const { getNetwork, attachTunnelNetwork } = input.providers;
    if (!input.teamIds || !getNetwork || !attachTunnelNetwork) return [];
    const lookups = yield* Effect.forEach(input.teamIds, (teamId) => {
      const slug = networkSlugForTeam(teamId);
      return getNetwork(input.provider, slug).pipe(
        Effect.map((network) => network ? teamNetworkFromProvider(network, slug) : null),
        Effect.either,
      );
    }, { concurrency: 4 });
    const lookupFailed = lookups.some((lookup) => lookup._tag === "Left");
    const desired = lookups.flatMap((lookup) => lookup._tag === "Right" && lookup.right ? [lookup.right] : []);
    const live = new Set((input.tunnel.attachments ?? []).map((attachment) => attachment.networkId));
    const attached: TeamNetwork[] = [];
    for (const network of desired) {
      if (live.has(network.providerNetworkId)) {
        attached.push(network);
        continue;
      }
      const ok = yield* attachTunnelNetwork(input.provider, input.tunnel.id, network.providerNetworkId).pipe(
        Effect.as(true),
        Effect.catchAll((error) => Effect.logWarning("Cloud team tunnel attachment skipped", {
          networkId: network.providerNetworkId,
          overlap: isProviderTunnelNetworkOverlap(error),
          errorDescription: privateNetworkErrorDescription(error),
          error,
        }).pipe(Effect.as(false))),
      );
      if (ok) attached.push(network);
    }
    const detach = input.providers.detachTunnelNetwork;
    if (lookupFailed || !detach) return attached;
    // Only the home network and team networks are ever attached, so any other
    // attachment belongs to a team the caller has left.
    const keep = new Set([input.homeNetworkId, ...desired.map((network) => network.providerNetworkId)]);
    for (const networkId of live) {
      if (keep.has(networkId)) continue;
      yield* detach(input.provider, input.tunnel.id, networkId).pipe(
        Effect.catchAll((error) => Effect.logWarning("Cloud stale team tunnel attachment cleanup skipped", {
          networkId,
          errorDescription: privateNetworkErrorDescription(error),
          error,
        })),
      );
    }
    return attached;
  });
}

function describeTunnel(
  tunnel: import("./drivers").ProviderTunnel,
  row: CloudVmTunnelRow,
  network: CloudVmNetworkRow,
  flags: { readonly created: boolean; readonly rotated: boolean },
  teamNetworks: readonly TeamNetwork[] = [],
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
    networks: [
      { id: network.providerNetworkId, cidr: network.cidr, cidrV6: network.cidrV6, scope: "user" as const },
      ...teamNetworks.map((team) => ({ id: team.providerNetworkId, cidr: team.cidr, cidrV6: team.cidrV6, scope: "team" as const })),
    ],
    created: flags.created,
    rotated: flags.rotated,
  };
}
