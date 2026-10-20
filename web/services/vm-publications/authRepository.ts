import { and, asc, count, desc, eq, gt, inArray, isNotNull, isNull, lte, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { Database } from "../../db/effect";
import { tracePublicationAuthEffect } from "./requestTelemetry";
import { cloudVmPublications, cloudVmDomains, cloudVms, cloudVmPublicationSessions, cloudVmPublicationAuthTransactions, cloudVmPublicationAuthCodes, cloudVmPublicationEmailGrants, accountDeletionTombstones } from "../../db/schema";
import { accountDeletionAdvisoryLockKey, accountDeletionUserHash, isBlockingAccountDeletionTombstone } from "../account/deletionLock";
import { PublicationDatabaseError, PublicationNotFoundError, PublicationConflictError, PublicationAuthArtifactError, PublicationAccountDeletionBlockedError, AUTH_ARTIFACT_SWEEP_LIMIT, AUTH_TRANSACTION_ABANDONED_AFTER_MS, MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION, type CloudVmPublicationRepositoryShape } from "./repository";

export type PublicationAuthRepositoryShape = Pick<CloudVmPublicationRepositoryShape, "hasEmailGrant"|"findActivePublicationForRequest"|"findRequestContext"|"createAuthTransaction"|"findPendingAuthTransaction"|"issueAuthCode"|"consumeAuthCodeAndCreateSession"|"findValidSession"|"revokePublicationSessions">;
export class PublicationAuthRepository extends Context.Tag("cmux/PublicationAuthRepository")<PublicationAuthRepository, PublicationAuthRepositoryShape>() {}
type AuthTx=Parameters<Parameters<Context.Tag.Service<Database>["transaction"]>[0]>[0];
type RepositoryError=PublicationDatabaseError|PublicationNotFoundError|PublicationConflictError|PublicationAuthArtifactError|PublicationAccountDeletionBlockedError;
function repositoryEffect<A,E>(operation:string, run:()=>Effect.Effect<A,E>):Effect.Effect<A,RepositoryError>{return tracePublicationAuthEffect(`database.${operation}`, Effect.suspend(run)).pipe(Effect.mapError(cause=>cause instanceof PublicationNotFoundError || cause instanceof PublicationConflictError || cause instanceof PublicationAuthArtifactError || cause instanceof PublicationAccountDeletionBlockedError ? cause : new PublicationDatabaseError({operation,cause})));}
function databaseEffect<A,E>(operation:string, run:()=>Effect.Effect<A,E>):Effect.Effect<A,PublicationDatabaseError>{return tracePublicationAuthEffect(`database.${operation}`, Effect.suspend(run)).pipe(Effect.mapError(cause=>new PublicationDatabaseError({operation,cause})));}
function normalizedHostname(value: string): string { return value.trim().toLowerCase().replace(/\.$/u, ""); }
function assertAccountDeletionUserMutationAllowed(tx:AuthTx,userId:string){return Effect.gen(function*(){
 yield* tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`);
 const userIdHash=accountDeletionUserHash(userId);
 const [deletion]=yield*tx.select({userIdHash:accountDeletionTombstones.userIdHash,status:accountDeletionTombstones.status,updatedAt:accountDeletionTombstones.updatedAt}).from(accountDeletionTombstones).where(eq(accountDeletionTombstones.userIdHash,userIdHash)).limit(1);
 if(deletion?.userIdHash===userIdHash && isBlockingAccountDeletionTombstone(deletion))return yield*Effect.fail(new PublicationAccountDeletionBlockedError({userId}));
});}
function sweepAuthTransactions(tx: AuthTx, publicationId: string, now: Date) {
    return Effect.gen(function* () {
        yield* tx
            .delete(cloudVmPublicationAuthTransactions)
            .where(inArray(cloudVmPublicationAuthTransactions.transactionHash, tx
            .select({ hash: cloudVmPublicationAuthTransactions.transactionHash })
            .from(cloudVmPublicationAuthTransactions)
            .where(and(eq(cloudVmPublicationAuthTransactions.publicationId, publicationId), lte(cloudVmPublicationAuthTransactions.expiresAt, now)))
            .orderBy(asc(cloudVmPublicationAuthTransactions.expiresAt))
            .limit(AUTH_ARTIFACT_SWEEP_LIMIT)));
        const pendingWhere = and(eq(cloudVmPublicationAuthTransactions.publicationId, publicationId), gt(cloudVmPublicationAuthTransactions.expiresAt, now), isNull(cloudVmPublicationAuthTransactions.consumedAt));
        const countPending = () => Effect.gen(function* () {
            const [pending] = yield* tx
                .select({ total: count() })
                .from(cloudVmPublicationAuthTransactions)
                .where(pendingWhere);
            return pending?.total ?? 0;
        });
        if ((yield* countPending()) < MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION)
            return;
        yield* tx
            .delete(cloudVmPublicationAuthTransactions)
            .where(and(pendingWhere, lte(cloudVmPublicationAuthTransactions.createdAt, new Date(now.getTime() - AUTH_TRANSACTION_ABANDONED_AFTER_MS))));
        if ((yield* countPending()) >= MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION) {
            return yield* Effect.fail(new PublicationConflictError({ reason: "auth_transaction_limit" }));
        }
    });
}

function sweepPublicationSessions(tx: AuthTx, publicationId: string, now: Date) {
    return Effect.gen(function* () {
        yield* tx
            .delete(cloudVmPublicationSessions)
            .where(inArray(cloudVmPublicationSessions.tokenHash, tx
            .select({ hash: cloudVmPublicationSessions.tokenHash })
            .from(cloudVmPublicationSessions)
            .where(and(eq(cloudVmPublicationSessions.publicationId, publicationId), or(lte(cloudVmPublicationSessions.expiresAt, now), isNotNull(cloudVmPublicationSessions.revokedAt))))
            .orderBy(asc(cloudVmPublicationSessions.expiresAt))
            .limit(AUTH_ARTIFACT_SWEEP_LIMIT)));
    });
}
export const makePublicationAuthRepository=Effect.gen(function*(){
const db=yield* Database;
return {
hasEmailGrant: (input) => databaseEffect("hasEmailGrant", () => Effect.gen(function* () {
    const [grant] = yield* db.select({ id: cloudVmPublicationEmailGrants.id }).from(cloudVmPublicationEmailGrants).where(and(eq(cloudVmPublicationEmailGrants.publicationId, input.publicationId), eq(cloudVmPublicationEmailGrants.email, input.email), or(isNull(cloudVmPublicationEmailGrants.expiresAt), gt(cloudVmPublicationEmailGrants.expiresAt, input.now)))).limit(1);
    return !!grant;
})),
findActivePublicationForRequest: (input) => databaseEffect("findActivePublicationForRequest", () => Effect.gen(function* () {
    const [target] = yield* db.select({
        publication: cloudVmPublications,
        domain: cloudVmDomains,
        vm: cloudVms,
    })
        .from(cloudVmPublications)
        .leftJoin(cloudVmDomains, eq(cloudVmPublications.domainId, cloudVmDomains.id))
        .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
        .where(and(eq(cloudVmPublications.providerTlsRuleId, input.providerTlsRuleId), eq(cloudVmPublications.state, "active"), isNull(cloudVmPublications.disabledAt), inArray(cloudVms.status, ["running", "paused"])))
        .limit(1);
    return target ?? null;
})),
findRequestContext: (input) => databaseEffect("findRequestContext", () => Effect.gen(function* () {
    const [context] = yield* db.select({
        publication: cloudVmPublications,
        domain: cloudVmDomains,
        vm: cloudVms,
        session: cloudVmPublicationSessions,
    })
        .from(cloudVmPublications)
        .leftJoin(cloudVmDomains, eq(cloudVmPublications.domainId, cloudVmDomains.id))
        .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
        // Invalid sessions remain a missing session on a valid publication;
        // they must not hide the publication or bypass its current policy.
        .leftJoin(cloudVmPublicationSessions, and(input.sessionTokenHash === null
        ? sql `false`
        : eq(cloudVmPublicationSessions.tokenHash, input.sessionTokenHash), eq(cloudVmPublicationSessions.publicationId, cloudVmPublications.id), eq(cloudVmPublicationSessions.routingRevision, cloudVmPublications.routingRevision), gt(cloudVmPublicationSessions.expiresAt, input.now), isNull(cloudVmPublicationSessions.revokedAt)))
        .where(and(eq(cloudVmPublications.providerTlsRuleId, input.providerTlsRuleId), eq(cloudVmPublications.state, "active"), isNull(cloudVmPublications.disabledAt), inArray(cloudVms.status, ["running", "paused"])))
        .limit(1);
    return context ?? null;
})),
createAuthTransaction: (input) => repositoryEffect("createAuthTransaction", () => Effect.gen(function* () {
    return yield* db.transaction((tx) => Effect.gen(function* () {
        const [target] = yield* tx
            .select({
            publication: cloudVmPublications,
            domain: cloudVmDomains,
        })
            .from(cloudVmPublications)
            .leftJoin(cloudVmDomains, eq(cloudVmPublications.domainId, cloudVmDomains.id))
        .where(and(eq(cloudVmPublications.id, input.publicationId), eq(cloudVmPublications.state, "active"), isNull(cloudVmPublications.disabledAt)))
            .for("update", { of: cloudVmPublications })
            .limit(1);
        if (!target)
            return yield* Effect.fail(new PublicationNotFoundError({ resource: "publication" }));
        if (target.publication.hostname !== normalizedHostname(input.hostname)) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_host_mismatch",
            }));
        }
        yield* sweepAuthTransactions(tx, target.publication.id, input.now);
        const [transaction] = yield* tx
            .insert(cloudVmPublicationAuthTransactions)
            .values({
            transactionHash: input.transactionHash,
            publicationId: target.publication.id,
            routingRevision: target.publication.routingRevision,
            pkceChallenge: input.pkceChallenge,
            stateHash: input.stateHash,
            hostname: target.publication.hostname,
            returnPath: input.returnPath,
            createdAt: input.now,
            expiresAt: input.expiresAt,
        })
            .returning();
        if (!transaction)
            return yield* Effect.fail(new Error("auth transaction insert returned no row"));
        return transaction;
    }));
})),
findPendingAuthTransaction: (input) => databaseEffect("findPendingAuthTransaction", () => Effect.gen(function* () {
    const [target] = yield* db.select({
        transaction: cloudVmPublicationAuthTransactions,
        publication: cloudVmPublications,
        domain: cloudVmDomains,
        vm: cloudVms,
    })
        .from(cloudVmPublicationAuthTransactions)
        .innerJoin(cloudVmPublications, eq(cloudVmPublicationAuthTransactions.publicationId, cloudVmPublications.id))
        .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
        .leftJoin(cloudVmDomains, eq(cloudVmPublications.domainId, cloudVmDomains.id))
        .where(and(eq(cloudVmPublicationAuthTransactions.transactionHash, input.transactionHash), gt(cloudVmPublicationAuthTransactions.expiresAt, input.now), isNull(cloudVmPublicationAuthTransactions.consumedAt), eq(cloudVmPublicationAuthTransactions.routingRevision, cloudVmPublications.routingRevision), eq(cloudVmPublicationAuthTransactions.hostname, cloudVmPublications.hostname), eq(cloudVmPublications.state, "active"), isNull(cloudVmPublications.disabledAt)))
        .limit(1);
    return target ?? null;
})),
issueAuthCode: (input) => repositoryEffect("issueAuthCode", () => Effect.gen(function* () {
    return yield* db.transaction((tx) => Effect.gen(function* () {
        {
            yield* assertAccountDeletionUserMutationAllowed(tx, input.userId);
        }
        const [transactionHint] = yield* tx
            .select()
            .from(cloudVmPublicationAuthTransactions)
            .where(eq(cloudVmPublicationAuthTransactions.transactionHash, input.transactionHash))
            .limit(1);
        if (!transactionHint) {
            return yield* Effect.fail(new PublicationAuthArtifactError({ reason: "transaction_invalid" }));
        }
        const [lockedPublication] = yield* tx
            .select()
            .from(cloudVmPublications)
            .where(eq(cloudVmPublications.id, transactionHint.publicationId))
            .for("update")
            .limit(1);
        const [transaction] = yield* tx
            .select()
            .from(cloudVmPublicationAuthTransactions)
            .where(eq(cloudVmPublicationAuthTransactions.transactionHash, input.transactionHash))
            .for("update")
            .limit(1);
        if (!transaction) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_invalid",
            }));
        }
        if (transaction.consumedAt) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_replayed",
            }));
        }
        if (transaction.expiresAt <= input.now) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_expired",
            }));
        }
        if (transaction.stateHash !== input.stateHash) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_state_mismatch",
            }));
        }
        const publication = lockedPublication;
        if (!publication ||
            publication.state !== "active" ||
            publication.disabledAt ||
            publication.routingRevision !== transaction.routingRevision) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "publication_revision_changed",
            }));
        }
        const [code] = yield* tx
            .insert(cloudVmPublicationAuthCodes)
            .values({
            codeHash: input.codeHash,
            transactionHash: transaction.transactionHash,
            publicationId: publication.id,
            userId: input.userId,
            routingRevision: publication.routingRevision,
            createdAt: input.now,
            expiresAt: input.expiresAt,
        })
            .returning();
        if (!code)
            return yield* Effect.fail(new Error("authorization code insert returned no row"));
        yield* tx
            .update(cloudVmPublicationAuthTransactions)
            .set({ consumedAt: input.now })
            .where(and(eq(cloudVmPublicationAuthTransactions.transactionHash, transaction.transactionHash), isNull(cloudVmPublicationAuthTransactions.consumedAt)));
        return {
            code,
            transaction: { ...transaction, consumedAt: input.now },
        };
    }));
})),
consumeAuthCodeAndCreateSession: (input) => repositoryEffect("consumeAuthCodeAndCreateSession", () => Effect.gen(function* () {
    return yield* db.transaction((tx) => Effect.gen(function* () {
        const [candidate] = yield* tx
            .select({ userId: cloudVmPublicationAuthCodes.userId })
            .from(cloudVmPublicationAuthCodes)
            .where(and(eq(cloudVmPublicationAuthCodes.codeHash, input.codeHash), eq(cloudVmPublicationAuthCodes.transactionHash, input.transactionHash)))
            .limit(1);
        if (!candidate) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "authorization_code_invalid",
            }));
        }
        {
            yield* assertAccountDeletionUserMutationAllowed(tx, candidate.userId);
        }
        const [code] = yield* tx
            .select()
            .from(cloudVmPublicationAuthCodes)
            .where(and(eq(cloudVmPublicationAuthCodes.codeHash, input.codeHash), eq(cloudVmPublicationAuthCodes.transactionHash, input.transactionHash)))
            .for("update")
            .limit(1);
        if (!code) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "authorization_code_invalid",
            }));
        }
        if (code.consumedAt) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "authorization_code_replayed",
            }));
        }
        if (code.expiresAt <= input.now) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "authorization_code_expired",
            }));
        }
        const [transaction] = yield* tx
            .select()
            .from(cloudVmPublicationAuthTransactions)
            .where(eq(cloudVmPublicationAuthTransactions.transactionHash, code.transactionHash))
            .limit(1);
        if (!transaction || !transaction.consumedAt) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_invalid",
            }));
        }
        if (transaction.stateHash !== input.stateHash) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_state_mismatch",
            }));
        }
        if (transaction.pkceChallenge !== input.pkceChallenge) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_pkce_mismatch",
            }));
        }
        if (transaction.hostname !== normalizedHostname(input.hostname)) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_host_mismatch",
            }));
        }
        const [target] = yield* tx
            .select({
            publication: cloudVmPublications,
            domain: cloudVmDomains,
        })
            .from(cloudVmPublications)
            .leftJoin(cloudVmDomains, eq(cloudVmPublications.domainId, cloudVmDomains.id))
            .where(eq(cloudVmPublications.id, code.publicationId))
            .for("update", { of: cloudVmPublications })
            .limit(1);
        if (!target ||
            target.publication.state !== "active" ||
            target.publication.disabledAt ||
            target.publication.routingRevision !== code.routingRevision ||
            target.publication.routingRevision !== transaction.routingRevision) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "publication_revision_changed",
            }));
        }
        if (target.publication.hostname !== transaction.hostname) {
            return yield* Effect.fail(new PublicationAuthArtifactError({
                reason: "transaction_host_mismatch",
            }));
        }
        yield* sweepPublicationSessions(tx, target.publication.id, input.now);
        const [session] = yield* tx
            .insert(cloudVmPublicationSessions)
            .values({
            tokenHash: input.sessionTokenHash,
            publicationId: target.publication.id,
            userId: code.userId,
            routingRevision: target.publication.routingRevision,
            createdAt: input.now,
            expiresAt: input.sessionExpiresAt,
        })
            .returning();
        if (!session)
            return yield* Effect.fail(new Error("publication session insert returned no row"));
        yield* tx
            .update(cloudVmPublicationAuthCodes)
            .set({ consumedAt: input.now })
            .where(and(eq(cloudVmPublicationAuthCodes.codeHash, code.codeHash), isNull(cloudVmPublicationAuthCodes.consumedAt)));
        return {
            session,
            publication: target.publication,
            returnPath: transaction.returnPath,
        };
    }));
})),
findValidSession: (input) => databaseEffect("findValidSession", () => Effect.gen(function* () {
    const [principal] = yield* db.select({
        session: cloudVmPublicationSessions,
        publication: cloudVmPublications,
        domain: cloudVmDomains,
    })
        .from(cloudVmPublicationSessions)
        .innerJoin(cloudVmPublications, eq(cloudVmPublicationSessions.publicationId, cloudVmPublications.id))
        .leftJoin(cloudVmDomains, eq(cloudVmPublications.domainId, cloudVmDomains.id))
        .where(and(eq(cloudVmPublicationSessions.tokenHash, input.tokenHash), eq(cloudVmPublicationSessions.publicationId, input.publicationId), gt(cloudVmPublicationSessions.expiresAt, input.now), isNull(cloudVmPublicationSessions.revokedAt), eq(cloudVmPublicationSessions.routingRevision, cloudVmPublications.routingRevision), eq(cloudVmPublications.state, "active"), isNull(cloudVmPublications.disabledAt), eq(cloudVmPublications.hostname, normalizedHostname(input.hostname))))
        .limit(1);
    return principal ?? null;
})),
revokePublicationSessions: (input) => databaseEffect("revokePublicationSessions", () => Effect.gen(function* () {
    const revoked = yield* db.update(cloudVmPublicationSessions)
        .set({ revokedAt: input.now })
        .where(and(eq(cloudVmPublicationSessions.publicationId, input.publicationId), isNull(cloudVmPublicationSessions.revokedAt)))
        .returning({ tokenHash: cloudVmPublicationSessions.tokenHash });
    return revoked.length;
}))
} satisfies PublicationAuthRepositoryShape;
});
export const PublicationAuthRepositoryLive=Layer.effect(PublicationAuthRepository,makePublicationAuthRepository);
