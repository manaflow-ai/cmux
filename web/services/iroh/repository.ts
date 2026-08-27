import { and, asc, desc, eq, gt, inArray, isNull, lte, ne, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../account/deletionLock";
import {
  irohAccountSecurityStates,
  irohEndpointBindings,
  irohPairGrantIssuances,
  irohRegistrationChallenges,
  irohRelayTokenIssuances,
} from "../../db/schema";
import {
  IrohConflictError,
  IrohDatabaseError,
  IrohForbiddenError,
  IrohNotFoundError,
} from "./errors";
import type { PairGrantPeer } from "./crypto";
import type { IrohDiscoveryCursor } from "./discoveryPagination";
import {
  nextPathHintExpiry,
  parseIrohPathHint,
  type IrohPathHint,
  type IrohRegistrationPayload,
} from "./model";
import {
  canIOSBindingForgetMac,
  canIOSBindingUseMac,
  canBindingRevokeStale,
} from "./buildCompatibility";
import type { IrohDiscoveryScope } from "./discoveryScope";

export const IROH_RETENTION_BATCH_SIZE = 500;
export const IROH_RETENTION_MAX_ROWS = 10_000;
export const IROH_RETENTION_MAX_DURATION_MS = 8_000;

export type IrohRetentionCategory =
  | "revokedHints"
  | "expiredHints"
  | "expiredChallenges"
  | "consumedChallenges"
  | "relayAudits"
  | "pairGrantAudits"
  | "revokedBindings";

export type IrohRetentionResult = {
  readonly rowsProcessed: number;
  readonly batches: number;
  readonly backlog: boolean;
  readonly budgetExhausted: "rows" | "time" | null;
  readonly byCategory: Readonly<Record<IrohRetentionCategory, number>>;
};

export type IrohBindingRecord = typeof irohEndpointBindings.$inferSelect;
export type IrohChallengeRecord = typeof irohRegistrationChallenges.$inferSelect;
export type IrohRegistrationCommit = {
  readonly binding: IrohBindingRecord;
  readonly created: boolean;
  readonly accountRevision: number;
};
export type IrohRevocationCommit = {
  readonly revoked: boolean;
  readonly accountRevision: number;
};
type CloudDbTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

type RepositoryError =
  | IrohDatabaseError
  | IrohForbiddenError
  | IrohNotFoundError
  | IrohConflictError;

export type IrohRepositoryShape = {
  readonly issueChallenge: (input: {
    readonly userId: string;
    readonly deviceUuid: string;
    readonly appInstanceId: string;
    readonly clientNamespace?: string;
    readonly tag: string;
    readonly endpointId: string;
    readonly identityGeneration: number;
    readonly payloadSha256: string;
    readonly nonceHash: string;
    readonly now: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<IrohChallengeRecord, RepositoryError>;
  readonly findChallenge: (
    userId: string,
    challengeId: string,
  ) => Effect.Effect<IrohChallengeRecord | null, RepositoryError>;
  readonly consumeChallengeAndRegister: (input: {
    readonly userId: string;
    readonly challengeId: string;
    readonly nonceHash: string;
    readonly payload: IrohRegistrationPayload;
    readonly now: Date;
  }) => Effect.Effect<IrohRegistrationCommit, RepositoryError>;
  readonly discoveryPage: (input: {
    readonly userId: string;
    readonly clientNamespace?: string;
    readonly callerBindingId?: string;
    readonly callerPlatform?: "mac" | "ios";
    readonly now: Date;
    readonly pageSize: number;
    readonly cursor?: IrohDiscoveryCursor;
  }) => Effect.Effect<{
    readonly bindings: IrohBindingRecord[];
    readonly lanDiscoveryGeneration: number;
    readonly accountRevision: number;
    readonly nextCursor: IrohDiscoveryCursor | null;
  }, RepositoryError>;
  readonly discoverySnapshot: (input: {
    readonly userId: string;
    readonly clientNamespace?: string;
    readonly callerBindingId?: string;
    readonly callerPlatform?: "mac" | "ios";
    readonly now: Date;
    readonly scope?: IrohDiscoveryScope;
  }) => Effect.Effect<{
    readonly bindings: IrohBindingRecord[];
    readonly lanDiscoveryGeneration: number;
    readonly accountRevision: number;
  }, RepositoryError>;
  readonly findActiveBindings: (
    userId: string,
    bindingIds: readonly string[],
  ) => Effect.Effect<IrohBindingRecord[], RepositoryError>;
  /** Includes a soft-revoked row so an authenticated self-revocation retry can be idempotent. */
  readonly findBindingForRevocationProof: (
    userId: string,
    bindingId: string,
  ) => Effect.Effect<IrohBindingRecord | null, RepositoryError>;
  readonly findActiveBindingByEndpoint: (
    userId: string,
    endpointId: string,
  ) => Effect.Effect<IrohBindingRecord | null, RepositoryError>;
  /** Returns the authoritative revision after revoking the owned binding. */
  readonly revokeBinding: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly clientNamespace?: string;
    readonly authorizedBindingId?: string;
    readonly intent?: "self" | "forget_mac" | "revoke_stale";
    readonly now: Date;
  }) => Effect.Effect<IrohRevocationCommit, RepositoryError>;
  readonly publishEndpointRecord: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly endpointId: string;
    readonly record: string;
    readonly now: Date;
  }) => Effect.Effect<{ readonly published: boolean }, RepositoryError>;
  readonly pruneExpiredState: (input: {
    readonly userId: string;
    readonly now: Date;
  }) => Effect.Effect<void, RepositoryError>;
  readonly pruneExpiredStateGlobally: (input: {
    readonly now: Date;
    readonly maxRows?: number;
    readonly maxDurationMs?: number;
  }) => Effect.Effect<IrohRetentionResult, RepositoryError>;
  readonly finalizeEndpointAttestation: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly deviceId: string;
    readonly endpointId: string;
    readonly identityGeneration: number;
    readonly platform: "mac" | "ios";
  }) => Effect.Effect<void, RepositoryError>;
  readonly recordPairGrant: (input: {
    readonly userId: string;
    readonly jti: string;
    readonly initiator: PairGrantPeer;
    readonly acceptor: PairGrantPeer;
    readonly signingKeyId: string;
    readonly alpn: string;
    readonly scope: string;
    readonly issuedAt: Date;
    readonly notBefore: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<void, RepositoryError>;
};

export class IrohRepository extends Context.Tag("cmux/IrohRepository")<
  IrohRepository,
  IrohRepositoryShape
>() {}

export const IrohRepositoryLive = Layer.succeed(IrohRepository, makeLiveRepository());

function makeLiveRepository(): IrohRepositoryShape {
  return {
    issueChallenge: (input) => repositoryEffect("issue_challenge", async () => {
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:challenge:${input.userId}`}, 0))`);
        // The register gate rejects a challenge whose createdAt is strictly
        // below the slot's registeredAt high-water mark. Both are millisecond
        // wall clocks, so two serialized mints can carry EQUAL timestamps; a
        // delayed older challenge that ties the mark passes the `<` gate and
        // can land after a newer one, reversing the order the gate enforces.
        // Fix at the source: make challenge mint time a strict total order per
        // slot. registeredAt is only ever stamped from a challenge's createdAt
        // (insert, reincarnation, and heartbeat paths alike), so if each new
        // challenge is strictly newer than every prior challenge for its slot,
        // the strict `<` gate is exact. All mints for a user serialize under
        // the per-user challenge advisory lock above, so this read cannot race
        // another mint for the same slot.
        const [priorChallenge] = await tx
          .select({ createdAt: irohRegistrationChallenges.createdAt })
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.userId, input.userId),
            eq(irohRegistrationChallenges.deviceUuid, input.deviceUuid),
            eq(
              irohRegistrationChallenges.clientNamespace,
              input.clientNamespace ?? "legacy",
            ),
            eq(irohRegistrationChallenges.tag, input.tag),
          ))
          .orderBy(desc(irohRegistrationChallenges.createdAt))
          .limit(1);
        const createdAt = priorChallenge && input.now <= priorChallenge.createdAt
          ? new Date(priorChallenge.createdAt.getTime() + 1)
          : input.now;
        const [challenge] = await tx
          .insert(irohRegistrationChallenges)
          .values({
            userId: input.userId,
            deviceUuid: input.deviceUuid,
            appInstanceId: input.appInstanceId,
            clientNamespace: input.clientNamespace ?? "legacy",
            tag: input.tag,
            endpointId: input.endpointId,
            identityGeneration: input.identityGeneration,
            payloadSha256: input.payloadSha256,
            nonceHash: input.nonceHash,
            createdAt,
            expiresAt: input.expiresAt,
          })
          .returning();
        if (!challenge) throw new Error("challenge insert returned no row");
        return challenge;
      });
    }),

    findChallenge: (userId, challengeId) => repositoryEffect("find_challenge", async () => {
      const [challenge] = await cloudDb()
        .select()
        .from(irohRegistrationChallenges)
        .where(and(
          eq(irohRegistrationChallenges.id, challengeId),
          eq(irohRegistrationChallenges.userId, userId),
        ))
        .limit(1);
      return challenge ?? null;
    }),

    consumeChallengeAndRegister: (input) => repositoryEffect("register_binding", async () => {
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        const accountPrivatePathHints = [...input.payload.pathHints];
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:endpoint:${input.payload.endpointId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:slot:${input.userId}:${input.payload.clientNamespace}:${input.payload.deviceId}:${input.payload.tag}`}, 0))`);
        const [challenge] = await tx
          .select()
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.id, input.challengeId),
            eq(irohRegistrationChallenges.userId, input.userId),
          ))
          .for("update")
          .limit(1);
        if (!challenge) throw new IrohNotFoundError({ resource: "challenge" });
        if (challenge.consumedAt) throw new IrohConflictError({ code: "challenge_replayed" });
        if (challenge.expiresAt <= input.now) throw new IrohForbiddenError({ code: "challenge_expired" });
        if (challenge.nonceHash !== input.nonceHash) throw new IrohForbiddenError({ code: "invalid_challenge_nonce" });

        // The binding slot is keyed on (user, client namespace, device, tag).
        // A reinstall, a
        // sign-out/in, or a key rotation reuses the same slot and overwrites it
        // in place (newest authenticated registration wins), preserving the row
        // id so existing pair grants keep resolving. There is no generation gate:
        // a reinstall resets identity_generation to 1, and gating on it would
        // reintroduce the wedge that stranded a computer behind its own past self.
        let [existingSlot] = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            eq(irohEndpointBindings.clientNamespace, input.payload.clientNamespace),
            eq(irohEndpointBindings.deviceUuid, input.payload.deviceId),
            eq(irohEndpointBindings.tag, input.payload.tag),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);

        // Older rows either predate app namespaces or identify a Mac by tag
        // alone. The app's endpoint identity lives in its exact signed Keychain
        // access group, so a registration that proves the same endpoint,
        // device, tag, and platform can atomically adopt only its own row. A
        // sibling bundle cannot read that endpoint secret and cannot claim it.
        if (
          !existingSlot
          && input.payload.clientNamespace !== "legacy"
        ) {
          const adoptableNamespaces = input.payload.platform === "mac"
              && input.payload.clientNamespace.startsWith("mac:")
            ? ["legacy", `mac:${input.payload.tag}`]
            : ["legacy"];
          const [legacySlot] = await tx
            .select()
            .from(irohEndpointBindings)
            .where(and(
              eq(irohEndpointBindings.userId, input.userId),
              inArray(
                irohEndpointBindings.clientNamespace,
                adoptableNamespaces,
              ),
              eq(irohEndpointBindings.deviceUuid, input.payload.deviceId),
              eq(irohEndpointBindings.tag, input.payload.tag),
              eq(irohEndpointBindings.endpointId, input.payload.endpointId),
              eq(irohEndpointBindings.platform, input.payload.platform),
              isNull(irohEndpointBindings.revokedAt),
            ))
            .for("update")
            .limit(1);
          if (legacySlot) {
            const [adoptedSlot] = await tx
              .update(irohEndpointBindings)
              .set({
                clientNamespace: input.payload.clientNamespace,
                updatedAt: input.now,
              })
              .where(and(
                eq(irohEndpointBindings.id, legacySlot.id),
                inArray(
                  irohEndpointBindings.clientNamespace,
                  adoptableNamespaces,
                ),
                isNull(irohEndpointBindings.revokedAt),
              ))
              .returning();
            if (!adoptedSlot) {
              throw new Error("legacy binding adoption returned no row");
            }
            existingSlot = adoptedSlot;
          }
        }

        // Reject a stale challenge minted before the slot's current registration.
        // Challenges resolve under the slot advisory lock, so two registrations
        // for one slot serialize; without this gate an older challenge that lost
        // the race (issued before the row's last registeredAt) could still land
        // second and overwrite — or reincarnate away — the newer incarnation,
        // reintroducing an out-of-order wedge. A live heartbeat's own challenge is
        // always newer than the row it refreshes, so it passes; only a delayed or
        // replayed older challenge trips this. registeredAt is the mint time of
        // the newest challenge that has landed: every applied registration —
        // insert, reincarnation, AND in-place heartbeat — stamps it to its own
        // challenge.createdAt, so it is a monotonic high-water mark. (If a
        // heartbeat left registeredAt frozen at the original insert, two reversed
        // heartbeats would both clear this gate and the older one would clobber
        // the newer refresh.)
        if (existingSlot && challenge.createdAt < existingSlot.registeredAt) {
          throw new IrohConflictError({ code: "challenge_superseded" });
        }

        // The endpoint id is a global cryptographic identity: no OTHER live
        // binding may claim it. Self is excluded so a slot can rotate its own key.
        const [endpointOwner] = await tx
          .select({ id: irohEndpointBindings.id })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.endpointId, input.payload.endpointId),
            isNull(irohEndpointBindings.revokedAt),
            existingSlot ? ne(irohEndpointBindings.id, existingSlot.id) : undefined,
          ))
          .for("update")
          .limit(1);
        if (endpointOwner) throw new IrohConflictError({ code: "endpoint_already_bound" });

        // A heartbeat/refresh of the live incarnation: every field that a peer
        // signs into a PairGrantPeer and exact-matches at admission is unchanged
        // (endpoint id, platform, identity generation). Update in place. The
        // binding id is stable and no peer's admission view of this endpoint
        // changes, so there is no ABA hazard and existing pair grants keep
        // resolving against the same id. If any signed field diverged, we must
        // NOT overwrite it on the live id: a still-valid grant signed against the
        // old field would then mismatch this current binding, and the host would
        // record this id in its permanent denial set — the ABA wedge. Any such
        // divergence falls through to the reincarnation path and mints a fresh id.
        if (
          existingSlot
          && existingSlot.endpointId === input.payload.endpointId
          && existingSlot.platform === input.payload.platform
          && existingSlot.identityGeneration === input.payload.identityGeneration
        ) {
          const [updated] = await tx
            .update(irohEndpointBindings)
            .set({
              appInstanceId: input.payload.appInstanceId,
              platform: input.payload.platform,
              identityGeneration: input.payload.identityGeneration,
              displayName: input.payload.displayName ?? null,
              pairingEnabled: input.payload.pairingEnabled,
              capabilities: [...input.payload.capabilities],
              directPortV4: input.payload.directPorts?.ipv4 ?? null,
              directPortV6: input.payload.directPorts?.ipv6 ?? null,
              pathHints: accountPrivatePathHints,
              pathHintsNextExpiry: nextPathHintExpiry(accountPrivatePathHints),
              lastSeenAt: input.now,
              updatedAt: input.now,
              // Advance the slot's registration high-water mark to this
              // challenge's mint time so a later-landing OLDER heartbeat is
              // rejected by the staleness gate instead of overwriting this
              // refresh. The gate above guarantees challenge.createdAt >=
              // existingSlot.registeredAt, so this only ever moves forward.
              registeredAt: challenge.createdAt,
            })
            .where(eq(irohEndpointBindings.id, existingSlot.id))
            .returning();
          await tx
            .update(irohRegistrationChallenges)
            .set({ consumedAt: input.now })
            .where(eq(irohRegistrationChallenges.id, challenge.id));
          if (!updated) throw new Error("binding update returned no row");
          const accountRevision = await advanceRouteRevision(tx, input.userId, input.now);
          return { binding: updated, created: false, accountRevision };
        }

        // A NEW incarnation on an existing slot: the endpoint key rotated (a
        // reinstall, a sign-out/in, or an explicit key rotation). Reusing the old
        // binding id would let a peer host that already denied the OLD endpoint
        // tuple permanently deny this row too — the ABA wedge that strands a
        // computer behind its own past self, since a host's denial set is keyed
        // on binding id, not endpoint id. So mint a NEW binding id and fully
        // retire the old one through the shared revoke path: it marks the retired
        // binding's pair grants revoked and rotates the account's LAN discovery
        // generation so the displaced install can no longer derive rendezvous
        // aliases. The rotation forces a re-pair regardless — the client's held
        // grant JWS names the now-dead endpoint id and generation, so it can
        // never be admitted against the new incarnation — which is why the old
        // issuance rows are revoked (audit-accurate) rather than reassigned onto
        // the new id.
        if (existingSlot) {
          await revokeActiveBindings(tx, {
            userId: input.userId,
            bindingIds: [existingSlot.id],
            now: input.now,
            reason: "slot_reincarnated",
          });
        }

        const [binding] = await tx
          .insert(irohEndpointBindings)
          .values({
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
            directPortV4: input.payload.directPorts?.ipv4 ?? null,
            directPortV6: input.payload.directPorts?.ipv6 ?? null,
            pathHints: accountPrivatePathHints,
            pathHintsNextExpiry: nextPathHintExpiry(accountPrivatePathHints),
            lastSeenAt: input.now,
            // Seed the slot's registration high-water mark from this challenge's
            // MINT time, not the register-request landing time. Two challenges
            // can be outstanding for a slot that does not exist yet; if an older
            // one lands first and stamps its later landing time here, the
            // staleness gate above would reject a genuinely newer outstanding
            // challenge (its mint time falls below the landing time) and strand
            // the older registration. Mint time keeps registeredAt a true,
            // ordering-consistent high-water mark across insert, reincarnation,
            // and heartbeat alike.
            registeredAt: challenge.createdAt,
            updatedAt: input.now,
          })
          .returning();
        if (!binding) throw new Error("binding insert returned no row");

        // No grant carry-over: iroh_pair_grant_issuances is an audit-only ledger
        // of compact JWS tokens that were returned once and name the OLD binding
        // id, endpoint, and generation. Reassigning the foreign key cannot rewrite
        // a client's held token or carry authorization; it would only make the JTI
        // audit point at a binding it was never signed for. The retired slot's live
        // grants were already marked revoked by revokeActiveBindings above.

        if (!existingSlot) {
          // A new active row changes the set traversed by discovery. Rotate the
          // generation so a cursor cannot combine pages around the insertion.
          // Reincarnation already rotates through revokeActiveBindings above.
          await tx
            .insert(irohAccountSecurityStates)
            .values({
              userId: input.userId,
              lanDiscoveryGeneration: 1,
              createdAt: input.now,
              updatedAt: input.now,
            })
            .onConflictDoUpdate({
              target: irohAccountSecurityStates.userId,
              set: {
                lanDiscoveryGeneration:
                  sql`${irohAccountSecurityStates.lanDiscoveryGeneration} + 1`,
                updatedAt: input.now,
              },
            });
        }
        await tx
          .update(irohRegistrationChallenges)
          .set({ consumedAt: input.now })
          .where(and(
            eq(irohRegistrationChallenges.id, challenge.id),
            isNull(irohRegistrationChallenges.consumedAt),
          ));
        const accountRevision = await advanceRouteRevision(tx, input.userId, input.now);
        return { binding, created: true, accountRevision };
      });
    }),

    discoveryPage: (input) => repositoryEffect("discovery_page", async () => {
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [existingState] = await tx
          .select({
            generation: irohAccountSecurityStates.lanDiscoveryGeneration,
            revision: irohAccountSecurityStates.routeRevision,
          })
          .from(irohAccountSecurityStates)
          .where(eq(irohAccountSecurityStates.userId, input.userId))
          .limit(1);
        const [insertedState] = existingState
          ? []
          : await tx
            .insert(irohAccountSecurityStates)
            .values({
              userId: input.userId,
              lanDiscoveryGeneration: 1,
              routeRevision: 0,
              createdAt: input.now,
              updatedAt: input.now,
            })
            .returning({
              generation: irohAccountSecurityStates.lanDiscoveryGeneration,
              revision: irohAccountSecurityStates.routeRevision,
            });
        const state = existingState ?? insertedState;
        if (!state) throw new Error("account security state returned no row");
        if (input.cursor && input.cursor.generation !== state.generation) {
          throw new IrohConflictError({ code: "discovery_cursor_stale" });
        }
        const clientNamespace = input.clientNamespace ?? "legacy";
        const [caller] = input.callerBindingId && input.callerPlatform
          ? await tx
            .select()
            .from(irohEndpointBindings)
            .where(and(
              eq(irohEndpointBindings.id, input.callerBindingId),
              eq(irohEndpointBindings.userId, input.userId),
              eq(irohEndpointBindings.platform, input.callerPlatform),
              eq(irohEndpointBindings.clientNamespace, clientNamespace),
              isNull(irohEndpointBindings.revokedAt),
            ))
            .limit(1)
          : [];
        const visibleRows: IrohBindingRecord[] = [];
        let scanAfter = input.cursor?.afterBindingId;
        const scanPageSize = Math.max(input.pageSize + 1, 256);
        while (visibleRows.length <= input.pageSize) {
          const rows = await tx
            .select()
            .from(irohEndpointBindings)
            .where(and(
              eq(irohEndpointBindings.userId, input.userId),
              isNull(irohEndpointBindings.revokedAt),
              scanAfter
                ? gt(irohEndpointBindings.id, scanAfter)
                : undefined,
            ))
            .orderBy(asc(irohEndpointBindings.id))
            .limit(scanPageSize);
          for (const binding of rows) {
            const visible = caller
              ? binding.id === caller.id || (
                caller.platform === "ios"
                  ? canIOSBindingUseMac(caller, binding)
                  : canIOSBindingUseMac(binding, caller)
              )
              : clientNamespace === "legacy"
                || binding.clientNamespace === clientNamespace;
            if (visible) visibleRows.push(binding);
            if (visibleRows.length > input.pageSize) break;
          }
          if (visibleRows.length > input.pageSize || rows.length < scanPageSize) break;
          scanAfter = rows.at(-1)?.id;
          if (!scanAfter) break;
        }
        const bindings = visibleRows.slice(0, input.pageSize);
        const last = bindings.at(-1);
        return {
          bindings,
          lanDiscoveryGeneration: state.generation,
          accountRevision: state.revision,
          nextCursor: visibleRows.length > input.pageSize && last
            ? {
              generation: state.generation,
              afterBindingId: last.id,
            }
            : null,
        };
      });
    }),

    discoverySnapshot: (input) => repositoryEffect("discovery_snapshot", async () => {
      return await cloudDb().transaction(async (tx) => {
        const clientNamespace = input.clientNamespace ?? "legacy";
        await assertIrohUserMutationAllowed(tx, input.userId);
        // Registration, revocation, pruning, and this read share one account
        // lock. The complete connectivity snapshot therefore observes one
        // committed binding set and revision, even when public discovery spans
        // several pages.
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [existingState] = await tx
          .select({
            generation: irohAccountSecurityStates.lanDiscoveryGeneration,
            revision: irohAccountSecurityStates.routeRevision,
          })
          .from(irohAccountSecurityStates)
          .where(eq(irohAccountSecurityStates.userId, input.userId))
          .limit(1);
        const [insertedState] = existingState
          ? []
          : await tx
            .insert(irohAccountSecurityStates)
            .values({
              userId: input.userId,
              lanDiscoveryGeneration: 1,
              routeRevision: 0,
              createdAt: input.now,
              updatedAt: input.now,
            })
            .returning({
              generation: irohAccountSecurityStates.lanDiscoveryGeneration,
              revision: irohAccountSecurityStates.routeRevision,
            });
        const state = existingState ?? insertedState;
        if (!state) throw new Error("account security state returned no row");
        const visibility = input.callerBindingId && input.callerPlatform
          ? or(
            eq(irohEndpointBindings.id, input.callerBindingId),
            eq(
              irohEndpointBindings.platform,
              input.callerPlatform === "mac" ? "ios" : "mac",
            ),
          )
          : clientNamespace === "legacy"
            ? undefined
            : eq(irohEndpointBindings.clientNamespace, clientNamespace);
        const bindings = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            visibility,
            isNull(irohEndpointBindings.revokedAt),
            input.scope
              ? or(
                and(
                  eq(
                    irohEndpointBindings.deviceUuid,
                    input.scope.localBinding.deviceId,
                  ),
                  eq(
                    irohEndpointBindings.appInstanceId,
                    input.scope.localBinding.appInstanceId,
                  ),
                  eq(irohEndpointBindings.tag, input.scope.localBinding.tag),
                  eq(
                    irohEndpointBindings.platform,
                    input.scope.localBinding.platform,
                  ),
                ),
                and(
                  eq(
                    irohEndpointBindings.platform,
                    input.scope.peerBindings.platform,
                  ),
                  input.scope.peerBindings.tags
                    ? inArray(
                      sql<string>`lower(${irohEndpointBindings.tag})`,
                      [...input.scope.peerBindings.tags],
                    )
                    : undefined,
                  input.scope.peerBindings.pairingEnabled === undefined
                    ? undefined
                    : eq(
                      irohEndpointBindings.pairingEnabled,
                      input.scope.peerBindings.pairingEnabled,
                    ),
                ),
              )
              : undefined,
          ))
          .orderBy(asc(irohEndpointBindings.id));
        const visibleBindings = input.callerBindingId && input.callerPlatform
          ? (() => {
            const caller = bindings.find((binding) =>
              binding.id === input.callerBindingId
              && binding.platform === input.callerPlatform);
            if (!caller) return [];
            return bindings.filter((binding) =>
              binding.id === caller.id
              || (
                caller.platform === "ios"
                  ? canIOSBindingUseMac(caller, binding)
                  : canIOSBindingUseMac(binding, caller)
              ));
          })()
          : bindings;
        return {
          bindings: visibleBindings,
          lanDiscoveryGeneration: state.generation,
          accountRevision: state.revision,
        };
      });
    }),

    findActiveBindings: (userId, bindingIds) => repositoryEffect("find_bindings", async () => {
      if (bindingIds.length === 0) return [];
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, userId);
        return await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, userId),
            inArray(irohEndpointBindings.id, [...bindingIds]),
            isNull(irohEndpointBindings.revokedAt),
          ));
      });
    }),

    findBindingForRevocationProof: (userId, bindingId) => repositoryEffect(
      "find_binding_for_revocation_proof",
      async () => {
        const [binding] = await cloudDb()
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, userId),
            eq(irohEndpointBindings.id, bindingId),
          ))
          .limit(1);
        return binding ?? null;
      },
    ),

    findActiveBindingByEndpoint: (userId, endpointId) => repositoryEffect(
      "find_binding_by_endpoint",
      async () => {
        const [binding] = await cloudDb()
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, userId),
            eq(irohEndpointBindings.endpointId, endpointId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .limit(1);
        return binding ?? null;
      },
    ),

    // Stores the endpoint's own signed record as an opaque blob on its
    // active binding. No account-revision bump: peers pull records on demand
    // through discovery, and an address change already refreshes hints
    // through registration, so record writes must not add revision churn.
    publishEndpointRecord: (input) => repositoryEffect(
      "publish_endpoint_record",
      async () => {
        return await cloudDb().transaction(async (tx) => {
          await assertIrohUserMutationAllowed(tx, input.userId);
          const [updated] = await tx
            .update(irohEndpointBindings)
            .set({
              endpointRecord: input.record,
              endpointRecordUpdatedAt: input.now,
              updatedAt: input.now,
            })
            .where(and(
              eq(irohEndpointBindings.id, input.bindingId),
              eq(irohEndpointBindings.userId, input.userId),
              eq(irohEndpointBindings.endpointId, input.endpointId),
              isNull(irohEndpointBindings.revokedAt),
            ))
            .returning({ id: irohEndpointBindings.id });
          return { published: updated !== undefined };
        });
      },
    ),

    revokeBinding: (input) => repositoryEffect("revoke_binding", async () => {
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [binding] = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
          ))
          .for("update")
          .limit(1);
        const unchangedRevision = async () =>
          await currentRouteRevision(tx, input.userId, input.now);
        if (!binding) {
          return {
            revoked: false,
            accountRevision: await unchangedRevision(),
          };
        }
        if (input.authorizedBindingId) {
          const [authorized] = await tx
            .select()
            .from(irohEndpointBindings)
            .where(and(
              eq(irohEndpointBindings.id, input.authorizedBindingId),
              eq(irohEndpointBindings.userId, input.userId),
            ))
            .limit(1);
          if (!authorized) {
            return {
              revoked: false,
              accountRevision: await unchangedRevision(),
            };
          }
          if (
            authorized.revokedAt
            && !(authorized.id === binding.id && binding.revokedAt)
          ) {
            return {
              revoked: false,
              accountRevision: await unchangedRevision(),
            };
          }
          if (input.intent === "forget_mac") {
            if (!canIOSBindingForgetMac(authorized, binding)) {
              return {
                revoked: false,
                accountRevision: await unchangedRevision(),
              };
            }
            if (binding.revokedAt) {
              return {
                revoked: true,
                accountRevision: await unchangedRevision(),
              };
            }
          } else if (input.intent === "revoke_stale") {
            if (!canBindingRevokeStale(authorized, binding)) {
              return {
                revoked: false,
                accountRevision: await unchangedRevision(),
              };
            }
            if (binding.revokedAt) {
              return {
                revoked: true,
                accountRevision: await unchangedRevision(),
              };
            }
          } else {
            const sameDurableSlot = authorized.deviceUuid === binding.deviceUuid
              && authorized.tag === binding.tag
              && authorized.platform === binding.platform
              && (
                authorized.clientNamespace === binding.clientNamespace
                || binding.clientNamespace === "legacy"
              );
            if (
              binding.revokedAt
              && (authorized.id === binding.id || sameDurableSlot)
            ) {
              return {
                revoked: true,
                accountRevision: await unchangedRevision(),
              };
            }
            const sameOwnedSlot = sameDurableSlot
              && authorized.appInstanceId === binding.appInstanceId;
            if (authorized.id !== binding.id && !sameOwnedSlot) {
              return {
                revoked: false,
                accountRevision: await unchangedRevision(),
              };
            }
          }
        } else {
          if (input.intent === "forget_mac") {
            return {
              revoked: false,
              accountRevision: await unchangedRevision(),
            };
          }
          // Legacy bindings predate request proofs and namespaces. Preserve the
          // old account-authenticated self-revocation path so an upgraded app can
          // drain a durable revocation queued by its previous version. A
          // namespace-less request still cannot revoke a namespaced binding.
          if (binding.clientNamespace !== "legacy") {
            return {
              revoked: false,
              accountRevision: await unchangedRevision(),
            };
          }
        }
        if (binding.revokedAt) {
          return {
            revoked: true,
            accountRevision: await unchangedRevision(),
          };
        }

        const revoked = await revokeActiveBindings(tx, {
          userId: input.userId,
          bindingIds: [input.bindingId],
          now: input.now,
          reason: "user_requested",
        });
        if (revoked.length === 0) {
          return {
            revoked: false,
            accountRevision: await currentRouteRevision(tx, input.userId, input.now),
          };
        }
        return {
          revoked: true,
          accountRevision: await advanceRouteRevision(tx, input.userId, input.now),
        };
      });
    }),

    pruneExpiredState: (input) => repositoryEffect("prune_expired_state", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const bindings = await tx
          .select({
            id: irohEndpointBindings.id,
            pathHints: irohEndpointBindings.pathHints,
          })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
            lte(irohEndpointBindings.pathHintsNextExpiry, input.now),
          ))
          .limit(IROH_RETENTION_BATCH_SIZE)
          .for("update");
        let routeChanged = false;
        for (const binding of bindings) {
          const retained = retainedStoredHints(binding.pathHints, input.now);
          routeChanged ||= retained.length !== binding.pathHints.length;
          await tx
            .update(irohEndpointBindings)
            .set({
              pathHints: retained,
              pathHintsNextExpiry: nextPathHintExpiry(retained),
              updatedAt: input.now,
            })
            .where(eq(irohEndpointBindings.id, binding.id));
        }
        if (routeChanged) {
          await advanceRouteRevision(tx, input.userId, input.now);
        }

        const challengeRetentionCutoff = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
        const auditRetentionCutoff = new Date(input.now.getTime() - 30 * 24 * 60 * 60 * 1_000);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_registration_challenges
            where user_id = ${input.userId}
              and expires_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
            order by expires_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_registration_challenges
            where user_id = ${input.userId}
              and consumed_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
            order by consumed_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_relay_token_issuances
            where user_id = ${input.userId}
              and requested_at < ${auditRetentionCutoff.toISOString()}::timestamptz
            order by requested_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_relay_token_issuances as issuance
          using candidates
          where issuance.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_pair_grant_issuances
            where user_id = ${input.userId}
              and expires_at < ${auditRetentionCutoff.toISOString()}::timestamptz
            order by expires_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_pair_grant_issuances as issuance
          using candidates
          where issuance.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select binding.id
            from iroh_endpoint_bindings as binding
            where binding.user_id = ${input.userId}
              and binding.revoked_at < ${auditRetentionCutoff.toISOString()}::timestamptz
            and not exists (
              select 1 from iroh_pair_grant_issuances as pair_grant
              where pair_grant.initiator_binding_id = binding.id
                or pair_grant.acceptor_binding_id = binding.id
            )
            and not exists (
              select 1 from iroh_relay_token_issuances as issuance
              where issuance.binding_id = binding.id
            )
            order by binding.revoked_at, binding.id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_endpoint_bindings as binding
          using candidates
          where binding.id = candidates.id
        `);
      });
    }),

    pruneExpiredStateGlobally: (input) => repositoryEffect(
      "prune_expired_state_globally",
      () => drainIrohRetention(input),
    ),

    finalizeEndpointAttestation: (input) => repositoryEffect("finalize_endpoint_attestation", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [binding] = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);
        if (!binding) throw new IrohNotFoundError({ resource: "binding" });
        if (
          binding.deviceUuid !== input.deviceId ||
          binding.endpointId !== input.endpointId ||
          binding.identityGeneration !== input.identityGeneration ||
          binding.platform !== input.platform
        ) {
          throw new IrohConflictError({ code: "binding_changed_during_attestation" });
        }
      });
    }),

    recordPairGrant: (input) => repositoryEffect("record_pair_grant", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:pair-grant:${input.userId}`}, 0))`);
        const peers = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            inArray(irohEndpointBindings.id, [input.initiator.bindingId, input.acceptor.bindingId]),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update");
        const byId = new Map(peers.map((peer) => [peer.id, peer]));
        const initiator = byId.get(input.initiator.bindingId);
        const acceptor = byId.get(input.acceptor.bindingId);
        if (!initiator || !acceptor) throw new IrohNotFoundError({ resource: "binding" });
        if (
          !bindingMatchesGrantPeer(initiator, input.initiator) ||
          !bindingMatchesGrantPeer(acceptor, input.acceptor)
        ) {
          throw new IrohConflictError({ code: "binding_changed_during_grant" });
        }
        if (initiator.deviceUuid === acceptor.deviceUuid) {
          throw new IrohForbiddenError({ code: "pair_grant_same_device" });
        }
        if (initiator.platform !== "ios" || acceptor.platform !== "mac" || !acceptor.pairingEnabled) {
          throw new IrohForbiddenError({ code: "target_not_pairable" });
        }
        await tx.insert(irohPairGrantIssuances).values({
          userId: input.userId,
          jti: input.jti,
          initiatorBindingId: input.initiator.bindingId,
          acceptorBindingId: input.acceptor.bindingId,
          signingKeyId: input.signingKeyId,
          alpn: input.alpn,
          scope: input.scope,
          issuedAt: input.issuedAt,
          notBefore: input.notBefore,
          expiresAt: input.expiresAt,
        });
      });
    }),

  };
}

async function revokeActiveBindings(
  tx: CloudDbTransaction,
  input: {
    readonly userId: string;
    readonly bindingIds: readonly string[];
    readonly now: Date;
    readonly reason:
      | "user_requested"
      | "stale_development_binding"
      | "slot_reincarnated";
  },
): Promise<readonly string[]> {
  if (input.bindingIds.length === 0) return [];
  const revoked = await tx
    .update(irohEndpointBindings)
    .set({
      revokedAt: input.now,
      revokedReason: input.reason,
      directPortV4: null,
      directPortV6: null,
      pathHints: [],
      pathHintsNextExpiry: null,
      relayAttachedUrl: null,
      relayAttachReportedAt: null,
      // The signed record names addresses; revocation wipes it with the
      // same retention posture as path hints and the live relay attach.
      endpointRecord: null,
      endpointRecordUpdatedAt: null,
      updatedAt: input.now,
    })
    .where(and(
      eq(irohEndpointBindings.userId, input.userId),
      inArray(irohEndpointBindings.id, [...input.bindingIds]),
      isNull(irohEndpointBindings.revokedAt),
    ))
    .returning({ id: irohEndpointBindings.id });
  if (revoked.length === 0) return [];
  const revokedIds = revoked.map((binding) => binding.id);
  await tx
    .update(irohPairGrantIssuances)
    .set({ revokedAt: input.now })
    .where(and(
      isNull(irohPairGrantIssuances.revokedAt),
      or(
        inArray(irohPairGrantIssuances.initiatorBindingId, revokedIds),
        inArray(irohPairGrantIssuances.acceptorBindingId, revokedIds),
      ),
    ));
  await tx
    .insert(irohAccountSecurityStates)
    .values({
      userId: input.userId,
      lanDiscoveryGeneration: 2,
      createdAt: input.now,
      updatedAt: input.now,
    })
    .onConflictDoUpdate({
      target: irohAccountSecurityStates.userId,
      set: {
        lanDiscoveryGeneration: sql`${irohAccountSecurityStates.lanDiscoveryGeneration} + 1`,
        updatedAt: input.now,
      },
    });
  return revokedIds;
}

async function advanceRouteRevision(
  tx: CloudDbTransaction,
  userId: string,
  now: Date,
): Promise<number> {
  const [state] = await tx
    .insert(irohAccountSecurityStates)
    .values({
      userId,
      lanDiscoveryGeneration: 1,
      routeRevision: 1,
      createdAt: now,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: irohAccountSecurityStates.userId,
      set: {
        routeRevision: sql`${irohAccountSecurityStates.routeRevision} + 1`,
        updatedAt: now,
      },
    })
    .returning({ revision: irohAccountSecurityStates.routeRevision });
  if (!state) throw new Error("route revision update returned no row");
  return state.revision;
}

async function currentRouteRevision(
  tx: CloudDbTransaction,
  userId: string,
  now: Date,
): Promise<number> {
  const [state] = await tx
    .insert(irohAccountSecurityStates)
    .values({
      userId,
      lanDiscoveryGeneration: 1,
      routeRevision: 0,
      createdAt: now,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: irohAccountSecurityStates.userId,
      set: { updatedAt: sql`${irohAccountSecurityStates.updatedAt}` },
    })
    .returning({ revision: irohAccountSecurityStates.routeRevision });
  if (!state) throw new Error("route revision read returned no row");
  return state.revision;
}

type RetentionBatchOperation = {
  readonly category: IrohRetentionCategory;
  readonly run: (limit: number) => Promise<number>;
};

async function drainIrohRetention(input: {
  readonly now: Date;
  readonly maxRows?: number;
  readonly maxDurationMs?: number;
}): Promise<IrohRetentionResult> {
  const maxRows = retentionBudget(
    input.maxRows,
    IROH_RETENTION_MAX_ROWS,
    100_000,
    "maxRows",
  );
  const maxDurationMs = retentionBudget(
    input.maxDurationMs,
    IROH_RETENTION_MAX_DURATION_MS,
    30_000,
    "maxDurationMs",
  );
  const challengeRetentionCutoff = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
  const auditRetentionCutoff = new Date(input.now.getTime() - 30 * 24 * 60 * 60 * 1_000);
  const nowIso = input.now.toISOString();
  const challengeCutoffIso = challengeRetentionCutoff.toISOString();
  const auditCutoffIso = auditRetentionCutoff.toISOString();
  const operations: readonly RetentionBatchOperation[] = [
    {
      category: "revokedHints",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_endpoint_bindings
          where revoked_at is not null
            and (
              path_hints_next_expiry is not null
              or direct_port_v4 is not null
              or direct_port_v6 is not null
              or relay_attached_url is not null
            )
          order by revoked_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          update iroh_endpoint_bindings as binding
          set path_hints = '[]'::jsonb,
              path_hints_next_expiry = null,
              direct_port_v4 = null,
              direct_port_v6 = null,
              relay_attached_url = null,
              relay_attach_reported_at = null,
              updated_at = ${nowIso}::timestamptz
          from candidates
          where binding.id = candidates.id
          returning binding.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "expiredHints",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_endpoint_bindings
          where revoked_at is null
            and path_hints_next_expiry <= ${nowIso}::timestamptz
          order by path_hints_next_expiry, id
          limit ${limit}
          for update skip locked
        ), retained as (
          select
            binding.id,
            coalesce(
              jsonb_agg(entry.hint order by entry.ordinality) filter (
                where case
                  when jsonb_typeof(entry.hint) = 'object'
                    and jsonb_typeof(entry.hint -> 'expires_at') = 'string'
                    and (entry.hint ->> 'expires_at') ~ '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$'
                  then (entry.hint ->> 'expires_at')::timestamptz > ${nowIso}::timestamptz
                  else false
                end
              ),
              '[]'::jsonb
            ) as path_hints
          from candidates
          join iroh_endpoint_bindings as binding on binding.id = candidates.id
          left join lateral jsonb_array_elements(binding.path_hints)
            with ordinality as entry(hint, ordinality) on true
          group by binding.id
        ), normalized as (
          select
            retained.id,
            retained.path_hints,
            (
              select min((hint ->> 'expires_at')::timestamptz)
              from jsonb_array_elements(retained.path_hints) as hints(hint)
            ) as next_expiry
          from retained
        ), changed as (
          update iroh_endpoint_bindings as binding
          set path_hints = normalized.path_hints,
              path_hints_next_expiry = normalized.next_expiry,
              updated_at = ${nowIso}::timestamptz
          from normalized
          where binding.id = normalized.id
          returning binding.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "expiredChallenges",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_registration_challenges
          where expires_at < ${challengeCutoffIso}::timestamptz
          order by expires_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
          returning challenge.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "consumedChallenges",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_registration_challenges
          where consumed_at < ${challengeCutoffIso}::timestamptz
          order by consumed_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
          returning challenge.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "relayAudits",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_relay_token_issuances
          where requested_at < ${auditCutoffIso}::timestamptz
          order by requested_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_relay_token_issuances as issuance
          using candidates
          where issuance.id = candidates.id
          returning issuance.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "pairGrantAudits",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_pair_grant_issuances
          where expires_at < ${auditCutoffIso}::timestamptz
          order by expires_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_pair_grant_issuances as issuance
          using candidates
          where issuance.id = candidates.id
          returning issuance.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "revokedBindings",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select binding.id
          from iroh_endpoint_bindings as binding
          where binding.revoked_at < ${auditCutoffIso}::timestamptz
            and not exists (
              select 1 from iroh_pair_grant_issuances as pair_grant
              where pair_grant.initiator_binding_id = binding.id
                or pair_grant.acceptor_binding_id = binding.id
            )
            and not exists (
              select 1 from iroh_relay_token_issuances as issuance
              where issuance.binding_id = binding.id
            )
          order by binding.revoked_at, binding.id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_endpoint_bindings as binding
          using candidates
          where binding.id = candidates.id
          returning binding.id
        )
        select count(*)::int as affected from changed
      `)),
    },
  ];
  const byCategory: Record<IrohRetentionCategory, number> = {
    revokedHints: 0,
    expiredHints: 0,
    expiredChallenges: 0,
    consumedChallenges: 0,
    relayAudits: 0,
    pairGrantAudits: 0,
    revokedBindings: 0,
  };
  const deadline = Date.now() + maxDurationMs;
  const activeOperations = [...operations];
  let rowsProcessed = 0;
  let batches = 0;
  let operationIndex = 0;

  while (activeOperations.length > 0 && rowsProcessed < maxRows && Date.now() < deadline) {
    const operation = activeOperations[operationIndex]!;
    const limit = Math.min(IROH_RETENTION_BATCH_SIZE, maxRows - rowsProcessed);
    const affected = await operation.run(limit);
    batches += 1;
    rowsProcessed += affected;
    byCategory[operation.category] += affected;
    if (affected < limit) {
      activeOperations.splice(operationIndex, 1);
      if (operationIndex >= activeOperations.length) operationIndex = 0;
    } else {
      operationIndex = (operationIndex + 1) % activeOperations.length;
    }
  }

  const budgetExhausted = rowsProcessed >= maxRows
    ? "rows"
    : Date.now() >= deadline
      ? "time"
      : null;
  const backlog = budgetExhausted === "time"
    ? true
    : await irohRetentionBacklogExists(input.now, challengeRetentionCutoff, auditRetentionCutoff);
  return { rowsProcessed, batches, backlog, budgetExhausted, byCategory };
}

async function runRetentionBatch(
  execute: (tx: CloudDbTransaction) => Promise<unknown>,
): Promise<number> {
  return await cloudDb().transaction(async (tx) => {
    const result = await execute(tx);
    const [row] = databaseRows(result);
    const affected = Number(row?.affected ?? 0);
    if (!Number.isSafeInteger(affected) || affected < 0 || affected > IROH_RETENTION_BATCH_SIZE) {
      throw new Error("invalid Iroh retention batch result");
    }
    return affected;
  });
}

async function irohRetentionBacklogExists(
  now: Date,
  challengeRetentionCutoff: Date,
  auditRetentionCutoff: Date,
): Promise<boolean> {
  const result = await cloudDb().execute(sql`
    select (
      exists (
        select 1 from iroh_endpoint_bindings
        where revoked_at is not null and path_hints_next_expiry is not null
      ) or exists (
        select 1 from iroh_endpoint_bindings
        where revoked_at is null and path_hints_next_expiry <= ${now.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_registration_challenges
        where expires_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_registration_challenges
        where consumed_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_relay_token_issuances
        where requested_at < ${auditRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_pair_grant_issuances
        where expires_at < ${auditRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1
        from iroh_endpoint_bindings as binding
        where binding.revoked_at < ${auditRetentionCutoff.toISOString()}::timestamptz
          and not exists (
            select 1 from iroh_pair_grant_issuances as pair_grant
            where pair_grant.initiator_binding_id = binding.id
              or pair_grant.acceptor_binding_id = binding.id
          )
          and not exists (
            select 1 from iroh_relay_token_issuances as issuance
            where issuance.binding_id = binding.id
          )
      )
    ) as backlog
  `);
  const [row] = databaseRows(result);
  return row?.backlog === true;
}

function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as readonly Record<string, unknown>[];
  const rows = (result as { readonly rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? rows as readonly Record<string, unknown>[] : [];
}

function retentionBudget(
  value: number | undefined,
  fallback: number,
  maximum: number,
  name: string,
): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved < 1 || resolved > maximum) {
    throw new Error(`invalid Iroh retention ${name}`);
  }
  return resolved;
}

function repositoryEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, RepositoryError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => {
      if (isDomainError(cause)) return cause;
      const conflict = databaseConflict(cause);
      return conflict ?? new IrohDatabaseError({ operation, cause: sanitizedDatabaseCause(cause) });
    },
  });
}

function isDomainError(error: unknown): error is
  | IrohForbiddenError
  | IrohNotFoundError
  | IrohConflictError {
  const tag = (error as { _tag?: unknown } | null)?._tag;
  return tag === "IrohForbiddenError" || tag === "IrohNotFoundError" ||
    tag === "IrohConflictError";
}

function sanitizedDatabaseCause(cause: unknown): unknown {
  const candidate = databaseCause(cause);
  return {
    code: typeof candidate?.code === "string" ? candidate.code : undefined,
    name: typeof candidate?.name === "string" ? candidate.name : undefined,
  };
}

function databaseConflict(cause: unknown): IrohConflictError | null {
  const candidate = databaseCause(cause);
  if (candidate?.code !== "23505") return null;
  if (candidate.constraint === "iroh_endpoint_bindings_active_endpoint_unique") {
    return new IrohConflictError({ code: "endpoint_already_bound" });
  }
  // The slot advisory lock (pg_advisory_xact_lock on iroh:slot:user:device:tag)
  // serializes registrations for one slot, so the partial unique index on
  // (user, client namespace, device, tag) where revoked_at is null is
  // unreachable in practice.
  // Map it defensively anyway: without this branch a slot race would fall
  // through to `return null` and leak a raw IrohDatabaseError as HTTP 500,
  // when the correct signal is a typed 409 telling the client a concurrent
  // newest-wins registration took the slot and it should retry.
  if (candidate.constraint === "iroh_endpoint_bindings_active_slot_unique") {
    return new IrohConflictError({ code: "slot_registration_superseded" });
  }
  return null;
}

function databaseCause(cause: unknown): {
  readonly code?: unknown;
  readonly name?: unknown;
  readonly constraint?: unknown;
} | null {
  let current = cause;
  const seen = new Set<unknown>();
  for (let depth = 0; depth < 5; depth += 1) {
    if (!current || typeof current !== "object" || seen.has(current)) return null;
    seen.add(current);
    const candidate = current as { code?: unknown; name?: unknown; constraint?: unknown; cause?: unknown };
    if (typeof candidate.code === "string") return candidate;
    current = candidate.cause;
  }
  return null;
}

async function assertIrohUserMutationAllowed(
  tx: CloudDbTransaction,
  userId: string,
): Promise<void> {
  try {
    await assertAccountDeletionUserMutationAllowed(tx, userId);
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) {
      throw new IrohConflictError({ code: "account_deletion_in_progress" });
    }
    throw error;
  }
}

function retainedStoredHints(pathHints: readonly unknown[], now: Date): IrohPathHint[] {
  return pathHints.flatMap((hint): IrohPathHint[] => {
    try {
      return [parseIrohPathHint(hint, now)];
    } catch {
      return [];
    }
  });
}

function bindingMatchesGrantPeer(binding: IrohBindingRecord, peer: PairGrantPeer): boolean {
  return binding.id === peer.bindingId &&
    binding.deviceUuid === peer.deviceId &&
    binding.tag === peer.tag &&
    binding.platform === peer.platform &&
    binding.endpointId === peer.endpointId &&
    binding.identityGeneration === peer.identityGeneration;
}
