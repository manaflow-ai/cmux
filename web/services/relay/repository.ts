import { eq, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { cloudDb } from "../../db/client";
import {
  irohRelayCatalogState,
  irohRelayPreferences,
} from "../../db/schema";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../account/deletionLock";
import {
  RelayAccountDeletionBlockedError,
  RelayCatalogIntegrityError,
  RelayCatalogRollbackError,
  RelayConfigurationError,
  RelayDatabaseError,
  RelayPreferenceConflictError,
} from "./errors";
import {
  defaultRelayPreference,
  parseRelayCatalog,
  relayPreferenceSchema,
  type RelayCatalog,
  type RelayPreference,
} from "./model";
import {
  assertSafeRelayCatalogRotation,
  relayCatalogDigest,
} from "./catalog";

export type RelayPreferenceRecord = {
  readonly preference: RelayPreference;
  readonly revision: number;
};

export type RelayCatalogState = {
  readonly sequence: number;
  readonly digest: string;
};

export function assertCatalogAdvance(
  current: RelayCatalogState | undefined,
  configured: RelayCatalogState,
): void {
  if (!current) return;
  if (configured.sequence < current.sequence) {
    throw new RelayCatalogRollbackError({
      configuredSequence: configured.sequence,
      persistedSequence: current.sequence,
      reason: "sequence_regressed",
    });
  }
  if (
    configured.sequence === current.sequence &&
    configured.digest !== current.digest
  ) {
    throw new RelayCatalogRollbackError({
      configuredSequence: configured.sequence,
      persistedSequence: current.sequence,
      reason: "sequence_reused_with_different_catalog",
    });
  }
}

export type RelayRepositoryShape = {
  readonly acceptCatalog: (input: {
    readonly catalog: RelayCatalog;
    readonly nowSeconds: number;
  }) => Effect.Effect<
    void,
    RelayCatalogRollbackError | RelayCatalogIntegrityError | RelayDatabaseError
  >;
  readonly getPreference: (
    accountId: string,
  ) => Effect.Effect<RelayPreferenceRecord, RelayDatabaseError>;
  readonly putPreference: (input: {
    readonly accountId: string;
    readonly expectedRevision?: number;
    readonly preference: RelayPreference;
  }) => Effect.Effect<
    RelayPreferenceRecord,
    RelayAccountDeletionBlockedError | RelayPreferenceConflictError | RelayDatabaseError
  >;
};

export class RelayRepository extends Context.Tag("cmux/RelayRepository")<
  RelayRepository,
  RelayRepositoryShape
>() {}

function typedDbEffect<A, E>(
  operation: string,
  run: () => Promise<A>,
  preserve: (cause: unknown) => cause is E,
): Effect.Effect<A, E | RelayDatabaseError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) =>
      preserve(cause)
        ? cause
        : new RelayDatabaseError({ operation, cause }),
  });
}

function tagged<T extends string>(value: unknown, tag: T): value is { readonly _tag: T } {
  return (value as { _tag?: string } | null)?._tag === tag;
}

function rowPreference(row: {
  readonly mode: "automatic" | "managed" | "custom";
  readonly selectedManagedRelayIds: string[];
  readonly customRelays: unknown;
  readonly revision: number;
}): RelayPreferenceRecord {
  const candidate: unknown = {
    mode: row.mode,
    selectedManagedRelayIds: row.selectedManagedRelayIds,
    customRelays: row.customRelays,
  };
  const parsed = relayPreferenceSchema.safeParse(candidate);
  if (!parsed.success || !Number.isSafeInteger(row.revision) || row.revision < 0) {
    throw new Error("invalid persisted relay preference");
  }
  return { preference: parsed.data, revision: row.revision };
}

export const RelayRepositoryLive = Layer.succeed(RelayRepository, {
  acceptCatalog: ({ catalog, nowSeconds }) =>
    typedDbEffect(
      "acceptCatalog",
      async () => {
        const digest = relayCatalogDigest(catalog);
        await cloudDb().transaction(async (tx) => {
          await tx.execute(
            sql`select pg_advisory_xact_lock(hashtextextended('cmux/iroh-relay-catalog', 0))`,
          );
          const [current] = await tx
            .select()
            .from(irohRelayCatalogState)
            .where(eq(irohRelayCatalogState.id, "managed"))
            .limit(1);
          if (current) {
            assertCatalogAdvance(
              {
                sequence: current.catalogSequence,
                digest: current.catalogDigest,
              },
              { sequence: catalog.sequence, digest },
            );
            if (catalog.sequence === current.catalogSequence) {
              if (current.catalog === null) {
                await tx
                  .update(irohRelayCatalogState)
                  .set({ catalog })
                  .where(eq(irohRelayCatalogState.id, "managed"));
              }
              return;
            }
            if (current.catalog === null) {
              throw new RelayCatalogRollbackError({
                configuredSequence: catalog.sequence,
                persistedSequence: current.catalogSequence,
                reason: "previous_catalog_unavailable",
              });
            }
            const previous = parseRelayCatalog(JSON.stringify(current.catalog));
            if (relayCatalogDigest(previous) !== current.catalogDigest) {
              throw new RelayCatalogIntegrityError({
                reason: "persisted_catalog_digest_mismatch",
              });
            }
            const overlapSeconds = Math.max(
              0,
              nowSeconds - Math.floor(current.updatedAt.getTime() / 1_000),
            );
            try {
              assertSafeRelayCatalogRotation({
                current: previous,
                next: catalog,
                overlapSeconds,
              });
            } catch (cause) {
              if (cause instanceof RelayConfigurationError) {
                throw new RelayCatalogRollbackError({
                  configuredSequence: catalog.sequence,
                  persistedSequence: current.catalogSequence,
                  reason: "unsafe_transition",
                });
              }
              throw cause;
            }
            await tx
              .update(irohRelayCatalogState)
              .set({
                catalogSequence: catalog.sequence,
                catalogDigest: digest,
                catalog,
                updatedAt: new Date(nowSeconds * 1_000),
              })
              .where(eq(irohRelayCatalogState.id, "managed"));
            return;
          }
          await tx.insert(irohRelayCatalogState).values({
            id: "managed",
            catalogSequence: catalog.sequence,
            catalogDigest: digest,
            catalog,
            updatedAt: new Date(nowSeconds * 1_000),
          });
        });
      },
      (cause): cause is RelayCatalogRollbackError | RelayCatalogIntegrityError =>
        tagged(cause, "RelayCatalogRollbackError") ||
        tagged(cause, "RelayCatalogIntegrityError"),
    ),

  getPreference: (accountId) =>
    typedDbEffect(
      "getPreference",
      async () => {
        const [row] = await cloudDb()
          .select()
          .from(irohRelayPreferences)
          .where(eq(irohRelayPreferences.accountId, accountId))
          .limit(1);
        return row ? rowPreference(row) : {
          preference: defaultRelayPreference,
          revision: 0,
        };
      },
      (cause): cause is never => {
        void cause;
        return false;
      },
    ),

  putPreference: ({ accountId, expectedRevision, preference }) =>
    typedDbEffect(
      "putPreference",
      async () => {
        return await cloudDb().transaction(async (tx) => {
          try {
            await assertAccountDeletionUserMutationAllowed(tx, accountId);
          } catch (cause) {
            if (cause instanceof AccountDeletionMutationBlockedError) {
              throw new RelayAccountDeletionBlockedError({
                reason: "account_deletion_in_progress",
              });
            }
            throw cause;
          }
          await tx.execute(
            sql`select pg_advisory_xact_lock(hashtextextended(${`cmux/iroh-relay-preference/${accountId}`}, 0))`,
          );
          const [current] = await tx
            .select()
            .from(irohRelayPreferences)
            .where(eq(irohRelayPreferences.accountId, accountId))
            .limit(1);
          const currentRevision = current?.revision ?? 0;
          if (
            expectedRevision !== undefined &&
            expectedRevision !== currentRevision
          ) {
            throw new RelayPreferenceConflictError({
              expectedRevision,
              currentRevision,
            });
          }
          const revision = currentRevision + 1;
          const values = {
            mode: preference.mode,
            selectedManagedRelayIds: preference.selectedManagedRelayIds,
            customRelays: preference.customRelays,
          };
          const [saved] = await tx
            .insert(irohRelayPreferences)
            .values({
              accountId,
              ...values,
              revision,
              updatedAt: new Date(),
            })
            .onConflictDoUpdate({
              target: irohRelayPreferences.accountId,
              set: {
                ...values,
                revision,
                updatedAt: new Date(),
              },
            })
            .returning();
          if (!saved) throw new Error("relay preference write returned no row");
          return rowPreference(saved);
        });
      },
      (cause): cause is RelayAccountDeletionBlockedError | RelayPreferenceConflictError =>
        tagged(cause, "RelayAccountDeletionBlockedError") ||
        tagged(cause, "RelayPreferenceConflictError"),
    ),
});

export async function runRelayRepositoryEffect<A, E>(
  program: Effect.Effect<A, E, RelayRepository>,
): Promise<A> {
  const result = await Effect.runPromise(
    program.pipe(Effect.provide(RelayRepositoryLive), Effect.either),
  );
  if (result._tag === "Left") throw result.left;
  return result.right;
}
