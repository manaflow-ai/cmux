import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  test,
} from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests, cloudDb } from "../db/client";
import { deleteVmPublicationRowsForAccountDeletion } from "../services/vm-publications/accountDeletion";
import {
  AUTH_ARTIFACT_SWEEP_LIMIT,
  CloudVmPublicationRepository,
  CloudVmPublicationRepositoryLive,
  MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION,
  type CloudVmPublicationRepositoryShape,
  type CloudVmPublicationTarget,
} from "../services/vm-publications/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const NOW = new Date("2026-09-02T19:00:00.000Z");

let sql: Sql | null = null;
let repository: CloudVmPublicationRepositoryShape | null = null;

function requiredSql(): Sql {
  if (!sql) throw new Error("test database not initialized");
  return sql;
}

function requiredRepository(): CloudVmPublicationRepositoryShape {
  if (!repository) throw new Error("publication repository not initialized");
  return repository;
}

async function runRepository<A, E>(effect: Effect.Effect<A, E>): Promise<A> {
  const result = await Effect.runPromise(Effect.either(effect));
  if (result._tag === "Left") throw result.left;
  return result.right;
}

async function expectRepositoryError(
  operation: Promise<unknown>,
  expected: object,
): Promise<void> {
  let failure: unknown = null;
  let succeeded = false;
  try {
    await operation;
    succeeded = true;
  } catch (error) {
    failure = error;
  }
  if (succeeded) throw new Error("expected repository operation to fail");
  expect(failure).toMatchObject(expected);
}

async function insertVm(
  ownerUserId: string,
  providerVmId: string,
  billingTeamId: string | null = null,
): Promise<void> {
  await requiredSql()`
    insert into cloud_vms (
      user_id, billing_team_id, provider, provider_vm_id, image_id, status,
      created_at, updated_at
    ) values (
      ${ownerUserId}, ${billingTeamId}, 'freestyle', ${providerVmId},
      'snapshot-publication-test', 'running', ${NOW}, ${NOW}
    )
  `;
}

async function createActivePublication(input: {
  readonly suffix: string;
  readonly ownerUserId?: string;
  readonly accessMode?: "personal" | "team" | "public";
  readonly teamId?: string | null;
}): Promise<CloudVmPublicationTarget> {
  const repo = requiredRepository();
  const ownerUserId = input.ownerUserId ?? `owner-${input.suffix}`;
  const accessMode = input.accessMode ?? "personal";
  const providerVmId = `provider-vm-${input.suffix}`;
  const hostname = `${input.suffix}.preview.example.test`;
  await insertVm(ownerUserId, providerVmId);
  const target = await runRepository(
    repo.reservePublicationWithNewDomain({
      ownerUserId,
      provider: "freestyle",
      providerVmId,
      domainHostname: hostname,
      hostname,
      kind: "generated",
      port: 3_000,
      accessMode,
      teamId: input.teamId,
      now: NOW,
    }),
  );
  const provisioned = await runRepository(
    repo.recordProvisioningTlsRule({
      id: target.publication.id,
      ownerUserId,
      expectedRoutingRevision: target.publication.routingRevision,
      providerTlsRuleId: `tls-rule-${input.suffix}`,
      providerForwardAuthId:
        accessMode === "public" ? null : "forward-auth-shared",
      now: NOW,
    }),
  );
  expect(provisioned.state).toBe("provisioning");
  const publication = await runRepository(
    repo.activatePublication({
      id: target.publication.id,
      ownerUserId,
      expectedRoutingRevision: target.publication.routingRevision,
      providerTlsRuleId: `tls-rule-${input.suffix}`,
      providerForwardAuthId:
        accessMode === "public" ? null : "forward-auth-shared",
      now: NOW,
    }),
  );
  return { ...target, publication };
}

beforeAll(async () => {
  if (!runDbTests) return;
  const databaseURL =
    process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL)
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 8 });
  repository = await Effect.runPromise(
    Effect.gen(function* () {
      return yield* CloudVmPublicationRepository;
    }).pipe(Effect.provide(CloudVmPublicationRepositoryLive)),
  );
});

beforeEach(async () => {
  if (!sql) return;
  await sql`
    truncate
      cloud_vm_publication_sessions,
      cloud_vm_publication_auth_codes,
      cloud_vm_publication_auth_transactions,
      cloud_vm_publications,
      cloud_vm_domains,
      cloud_vm_publication_vm_guards,
      cloud_vm_publication_provider_configs,
      cloud_vm_tunnels,
      cloud_vm_networks,
      account_mutation_leases,
      account_deletion_tombstones,
      cloud_vms
    restart identity cascade
  `;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end({ timeout: 5 });
});

describe("Cloud VM publication persistence", () => {
  dbTest(
    "serializes bootstrap of the account-shared forward-auth resource",
    async () => {
      const repo = requiredRepository();
      const contenders = [randomUUID(), randomUUID()];
      const expiresAt = new Date(NOW.getTime() + 60_000);
      const claims = await Promise.all(
        contenders.map(async (leaseId) => ({
          leaseId,
          result: await runRepository(
            repo.claimProviderForwardAuth({
              provider: "freestyle",
              leaseId,
              now: NOW,
              leaseExpiresAt: expiresAt,
            }),
          ),
        })),
      );

      expect(claims.map(({ result }) => result.kind).sort()).toEqual([
        "claimed",
        "in_progress",
      ]);
      const winner = claims.find(({ result }) => result.kind === "claimed");
      const loser = claims.find(({ result }) => result.kind === "in_progress");
      if (!winner || !loser)
        throw new Error("bootstrap did not elect one winner");

      await expectRepositoryError(
        runRepository(
          repo.completeProviderForwardAuth({
            provider: "freestyle",
            leaseId: loser.leaseId,
            providerForwardAuthId: "forward-auth-loser",
            now: NOW,
          }),
        ),
        {
          _tag: "PublicationConflictError",
          reason: "forward_auth_bootstrap_lost",
        },
      );
      const completed = await runRepository(
        repo.completeProviderForwardAuth({
          provider: "freestyle",
          leaseId: winner.leaseId,
          providerForwardAuthId: "forward-auth-canonical",
          now: NOW,
        }),
      );
      expect(completed.providerForwardAuthId).toBe("forward-auth-canonical");
      expect(completed.provisioningLeaseId).toBeNull();

      await expectRepositoryError(
        runRepository(
          repo.replaceProviderForwardAuth({
            provider: "freestyle",
            expectedProviderForwardAuthId: "forward-auth-stale",
            providerForwardAuthId: "forward-auth-recreated",
            now: NOW,
          }),
        ),
        {
          _tag: "PublicationConflictError",
          reason: "forward_auth_bootstrap_lost",
        },
      );
      const replaced = await runRepository(
        repo.replaceProviderForwardAuth({
          provider: "freestyle",
          expectedProviderForwardAuthId: "forward-auth-canonical",
          providerForwardAuthId: "forward-auth-recreated",
          now: NOW,
        }),
      );
      expect(replaced.providerForwardAuthId).toBe("forward-auth-recreated");

      const ready = await runRepository(
        repo.claimProviderForwardAuth({
          provider: "freestyle",
          leaseId: randomUUID(),
          now: NOW,
          leaseExpiresAt: expiresAt,
        }),
      );
      expect(ready.kind).toBe("ready");
      if (ready.kind === "ready") {
        expect(ready.config.providerForwardAuthId).toBe(
          "forward-auth-recreated",
        );
      }
    },
  );

  dbTest(
    "owns exact hostnames and prevents a live publication from losing its VM",
    async () => {
      const repo = requiredRepository();
      const target = await createActivePublication({ suffix: "ownership" });
      const verificationRecords = [
        {
          purpose: "routing" as const,
          recordTypes: ["CNAME", "ALIAS", "ANAME", "CNAME_FLATTENING"] as const,
          name: "custom.example.test",
          value: "beta-web.freestyle.sh",
        },
      ];
      const customDomain = await runRepository(
        repo.createDomain({
          ownerUserId: target.publication.ownerUserId,
          hostname: "custom.example.test",
          kind: "custom",
          provider: "freestyle",
          providerVerificationId: "verification-ownership",
          verificationState: "pending",
          certificateState: "missing",
          verificationRecords,
          now: NOW,
        }),
      );
      expect(customDomain.verificationRecords).toEqual(verificationRecords);

      const resolved = await runRepository(
        repo.findActivePublicationForRequest({
          hostname: "OWNERSHIP.PREVIEW.EXAMPLE.TEST",
          providerTlsRuleId: "tls-rule-ownership",
        }),
      );
      expect(resolved?.publication.id).toBe(target.publication.id);
      expect(
        await runRepository(
          repo.findActivePublicationForRequest({
            hostname: target.publication.hostname,
            providerTlsRuleId: "tls-rule-not-this-publication",
          }),
        ),
      ).toBeNull();

      await expectRepositoryError(
        runRepository(
          repo.reservePublication({
            ownerUserId: target.publication.ownerUserId,
            provider: "freestyle",
            providerVmId: target.vm.providerVmId ?? "",
            domainId: target.domain.id,
            hostname: target.publication.hostname,
            port: 4_000,
            accessMode: "public",
            now: NOW,
          }),
        ),
        { _tag: "PublicationConflictError", reason: "hostname_taken" },
      );

      let deleteError: unknown;
      try {
        await requiredSql()`delete from cloud_vms where id = ${target.vm.id}`;
      } catch (error) {
        deleteError = error;
      }
      expect((deleteError as { code?: string } | null)?.code).toBe("23503");
    },
  );

  dbTest(
    "allows normalized cross-owner pending zones and atomically elects one verified owner",
    async () => {
      const repo = requiredRepository();
      await insertVm("zone-owner-a", "zone-vm-a");
      await insertVm("zone-owner-b", "zone-vm-b");

      const [attemptA, attemptB] = await Promise.all([
        runRepository(
          repo.reservePublicationWithNewDomain({
            ownerUserId: "zone-owner-a",
            provider: "freestyle",
            providerVmId: "zone-vm-a",
            domainHostname: " Example.Test. ",
            hostname: "Preview.Example.Test.",
            kind: "custom",
            port: 3_000,
            accessMode: "personal",
            now: NOW,
          }),
        ),
        runRepository(
          repo.reservePublicationWithNewDomain({
            ownerUserId: "zone-owner-b",
            provider: "freestyle",
            providerVmId: "zone-vm-b",
            domainHostname: "example.test",
            hostname: "preview.example.test",
            kind: "custom",
            port: 3_001,
            accessMode: "personal",
            now: NOW,
          }),
        ),
      ]);

      expect(attemptA.domain.hostname).toBe("example.test");
      expect(attemptA.publication.hostname).toBe("preview.example.test");
      expect(attemptA.publication.hostnameClaimedAt).toBeNull();
      expect(attemptB.publication.hostnameClaimedAt).toBeNull();

      await expectRepositoryError(
        runRepository(
          repo.reservePublicationWithNewDomain({
            ownerUserId: "zone-owner-a",
            provider: "freestyle",
            providerVmId: "zone-vm-a",
            domainHostname: "EXAMPLE.TEST",
            hostname: "other.example.test",
            kind: "custom",
            port: 3_002,
            accessMode: "personal",
            now: new Date(NOW.getTime() + 1),
          }),
        ),
        { _tag: "PublicationConflictError", reason: "hostname_taken" },
      );

      const promotions = await Promise.allSettled([
        runRepository(
          repo.updateDomainState({
            id: attemptA.domain.id,
            ownerUserId: "zone-owner-a",
            providerVerificationId: "zone-verification-a",
            verificationState: "verified",
            certificateState: "pending",
            now: new Date(NOW.getTime() + 2),
          }),
        ),
        runRepository(
          repo.updateDomainState({
            id: attemptB.domain.id,
            ownerUserId: "zone-owner-b",
            providerVerificationId: "zone-verification-b",
            verificationState: "verified",
            certificateState: "pending",
            now: new Date(NOW.getTime() + 2),
          }),
        ),
      ]);
      expect(
        promotions.filter((result) => result.status === "fulfilled"),
      ).toHaveLength(1);
      const rejected = promotions.find(
        (result) => result.status === "rejected",
      );
      expect(rejected).toMatchObject({
        status: "rejected",
        reason: { _tag: "PublicationConflictError", reason: "hostname_taken" },
      });

      const [ownership] = await requiredSql()<
        {
          verified_zones: number;
          pending_zones: number;
          claimed_hosts: number;
          pending_hosts: number;
        }[]
      >`
        select
          count(*) filter (where verification_state = 'verified')::int as verified_zones,
          count(*) filter (where verification_state = 'pending')::int as pending_zones,
          (select count(*)::int from cloud_vm_publications where hostname_claimed_at is not null) as claimed_hosts,
          (select count(*)::int from cloud_vm_publications where hostname_claimed_at is null) as pending_hosts
        from cloud_vm_domains
        where hostname = 'example.test'
      `;
      expect(ownership).toEqual({
        verified_zones: 1,
        pending_zones: 1,
        claimed_hosts: 1,
        pending_hosts: 1,
      });
      const losingAttempt =
        promotions[0]?.status === "rejected" ? attemptA : attemptB;
      await expectRepositoryError(
        runRepository(
          repo.recordProvisioningTlsRule({
            id: losingAttempt.publication.id,
            ownerUserId: losingAttempt.publication.ownerUserId,
            expectedRoutingRevision: losingAttempt.publication.routingRevision,
            providerTlsRuleId: "must-not-persist-public-rule",
            providerForwardAuthId: "forward-auth-shared",
            now: new Date(NOW.getTime() + 3),
          }),
        ),
        { _tag: "PublicationConflictError", reason: "hostname_taken" },
      );
    },
  );

  dbTest(
    "reuses a verified zone for its apex or one-label child and keeps provider challenges unique",
    async () => {
      const repo = requiredRepository();
      await insertVm("reusable-zone-owner", "reusable-zone-vm");
      const first = await runRepository(
        repo.reservePublicationWithNewDomain({
          ownerUserId: "reusable-zone-owner",
          provider: "freestyle",
          providerVmId: "reusable-zone-vm",
          domainHostname: "reuse.example.test",
          hostname: "preview.reuse.example.test",
          kind: "custom",
          port: 3_000,
          accessMode: "personal",
          now: NOW,
        }),
      );
      await runRepository(
        repo.updateDomainState({
          id: first.domain.id,
          ownerUserId: "reusable-zone-owner",
          providerVerificationId: "reusable-zone-verification",
          verificationState: "verified",
          now: new Date(NOW.getTime() + 1),
        }),
      );

      const apex = await runRepository(
        repo.reservePublication({
          ownerUserId: "reusable-zone-owner",
          provider: "freestyle",
          providerVmId: "reusable-zone-vm",
          domainId: first.domain.id,
          hostname: "REUSE.EXAMPLE.TEST.",
          port: 3_001,
          accessMode: "public",
          now: new Date(NOW.getTime() + 2),
        }),
      );
      const child = await runRepository(
        repo.reservePublication({
          ownerUserId: "reusable-zone-owner",
          provider: "freestyle",
          providerVmId: "reusable-zone-vm",
          domainId: first.domain.id,
          hostname: "api.reuse.example.test",
          port: 3_002,
          accessMode: "personal",
          now: new Date(NOW.getTime() + 3),
        }),
      );
      expect(apex.publication.hostname).toBe("reuse.example.test");
      expect(apex.publication.hostnameClaimedAt).toBeInstanceOf(Date);
      expect(child.publication.hostnameClaimedAt).toBeInstanceOf(Date);

      await expectRepositoryError(
        runRepository(
          repo.reservePublication({
            ownerUserId: "reusable-zone-owner",
            provider: "freestyle",
            providerVmId: "reusable-zone-vm",
            domainId: first.domain.id,
            hostname: "too.deep.reuse.example.test",
            port: 3_003,
            accessMode: "personal",
            now: new Date(NOW.getTime() + 4),
          }),
        ),
        { _tag: "PublicationConflictError", reason: "hostname_taken" },
      );

      const competing = await runRepository(
        repo
          .createDomain({
            ownerUserId: "another-zone-owner",
            hostname: "another.example.test",
            kind: "custom",
            provider: "freestyle",
            providerVerificationId: "reusable-zone-verification",
            verificationState: "pending",
            certificateState: "missing",
            now: new Date(NOW.getTime() + 5),
          })
          .pipe(Effect.either),
      );
      expect(competing).toMatchObject({
        _tag: "Left",
        left: {
          _tag: "PublicationConflictError",
          reason: "provider_verification_in_use",
        },
      });
    },
  );

  dbTest(
    "reserves generated hosts globally and leaves no zone for an invalid or foreign VM",
    async () => {
      const repo = requiredRepository();
      await insertVm("generated-owner-a", "generated-vm-a");
      await insertVm("generated-owner-b", "generated-vm-b");

      await runRepository(
        repo.reservePublicationWithNewDomain({
          ownerUserId: "generated-owner-a",
          provider: "freestyle",
          providerVmId: "generated-vm-a",
          domainHostname: "Unique-Preview.CMUX.sh.",
          hostname: "Unique-Preview.CMUX.sh.",
          kind: "generated",
          port: 3_000,
          accessMode: "public",
          now: NOW,
        }),
      );
      await expectRepositoryError(
        runRepository(
          repo.reservePublicationWithNewDomain({
            ownerUserId: "generated-owner-b",
            provider: "freestyle",
            providerVmId: "generated-vm-b",
            domainHostname: "unique-preview.cmux.sh",
            hostname: "unique-preview.cmux.sh",
            kind: "generated",
            port: 3_001,
            accessMode: "public",
            now: NOW,
          }),
        ),
        { _tag: "PublicationConflictError", reason: "hostname_taken" },
      );

      for (const [providerVmId, domainHostname] of [
        ["missing-vm", "missing-vm.example.test"],
        ["generated-vm-b", "foreign-vm.example.test"],
      ] as const) {
        await expectRepositoryError(
          runRepository(
            repo.reservePublicationWithNewDomain({
              ownerUserId: "generated-owner-a",
              provider: "freestyle",
              providerVmId,
              domainHostname,
              hostname: `preview.${domainHostname}`,
              kind: "custom",
              port: 3_002,
              accessMode: "personal",
              now: new Date(NOW.getTime() + 1),
            }),
          ),
          { _tag: "PublicationNotFoundError", resource: "vm" },
        );
      }
      const [invalidRows] = await requiredSql()<
        { domain_count: number; publication_count: number }[]
      >`
        select
          count(*) filter (where hostname in ('missing-vm.example.test', 'foreign-vm.example.test'))::int as domain_count,
          (select count(*)::int from cloud_vm_publications where hostname in (
            'preview.missing-vm.example.test', 'preview.foreign-vm.example.test'
          )) as publication_count
        from cloud_vm_domains
      `;
      expect(invalidRows).toEqual({ domain_count: 0, publication_count: 0 });
    },
  );

  dbTest(
    "durably freezes a VM and waits for an in-flight publication operation",
    async () => {
      const repo = requiredRepository();
      const target = await createActivePublication({
        suffix: "vm-delete-freeze",
      });
      const leaseId = randomUUID();
      const leaseExpiresAt = new Date(NOW.getTime() + 60_000);
      const claim = await runRepository(
        repo.claimVmPublicationOperation({
          publicationId: target.publication.id,
          ownerUserId: target.publication.ownerUserId,
          leaseId,
          now: NOW,
          leaseExpiresAt,
        }),
      );
      expect(claim).toEqual({ kind: "claimed", vmId: target.vm.id });

      const firstFreeze = await runRepository(
        repo.freezeVmPublicationsForDeletion({
          requesterUserId: target.publication.ownerUserId,
          teamIds: [],
          providerVmId: target.vm.providerVmId ?? "",
          now: new Date(NOW.getTime() + 1),
        }),
      );
      expect(firstFreeze).toEqual({
        kind: "in_progress",
        vmId: target.vm.id,
        retryAt: leaseExpiresAt,
      });

      const secondDomain = await runRepository(
        repo.createDomain({
          ownerUserId: target.publication.ownerUserId,
          hostname: "vm-delete-frozen.preview.example.test",
          kind: "generated",
          provider: "freestyle",
          verificationState: "not_required",
          certificateState: "active",
          now: new Date(NOW.getTime() + 2),
        }),
      );
      await expectRepositoryError(
        runRepository(
          repo.reservePublication({
            ownerUserId: target.publication.ownerUserId,
            provider: "freestyle",
            providerVmId: target.vm.providerVmId ?? "",
            domainId: secondDomain.id,
            hostname: secondDomain.hostname,
            port: 4_000,
            accessMode: "personal",
            now: new Date(NOW.getTime() + 2),
          }),
        ),
        { _tag: "PublicationConflictError", reason: "vm_publication_frozen" },
      );

      expect(
        await runRepository(
          repo.releaseVmPublicationOperation({
            publicationId: target.publication.id,
            leaseId,
            now: new Date(NOW.getTime() + 3),
          }),
        ),
      ).toBe(true);
      const retry = await runRepository(
        repo.freezeVmPublicationsForDeletion({
          requesterUserId: target.publication.ownerUserId,
          teamIds: [],
          providerVmId: target.vm.providerVmId ?? "",
          now: new Date(NOW.getTime() + 4),
        }),
      );
      expect(retry.kind).toBe("ready");
      if (retry.kind === "ready") {
        expect(retry.publications).toEqual([
          expect.objectContaining({
            publicationId: target.publication.id,
            hostname: target.publication.hostname,
            state: "disabling",
          }),
        ]);
      }
      const [guard] = await requiredSql()<
        {
          teardown_started_at: Date;
          operation_lease_id: string | null;
        }[]
      >`
      select teardown_started_at, operation_lease_id
      from cloud_vm_publication_vm_guards
      where vm_id = ${target.vm.id}
    `;
      expect(guard?.teardown_started_at).toBeInstanceOf(Date);
      expect(guard?.operation_lease_id).toBeNull();
    },
  );

  dbTest(
    "deletes owned publications and viewer auth PII while permanently reserving verified domains",
    async () => {
      const repo = requiredRepository();
      const deletingUserId = "owner-account-delete";
      const owned = await createActivePublication({
        suffix: "account-delete-owned",
        ownerUserId: deletingUserId,
      });
      const retained = await createActivePublication({
        suffix: "account-delete-retained",
        ownerUserId: "owner-retained",
      });
      const transactionHash = "1".repeat(64);
      const stateHash = "2".repeat(64);
      const codeHash = "3".repeat(64);
      const sessionTokenHash = "4".repeat(64);
      const pkceChallenge = "K".repeat(43);
      await runRepository(
        repo.createAuthTransaction({
          publicationId: retained.publication.id,
          transactionHash,
          pkceChallenge,
          stateHash,
          hostname: retained.publication.hostname,
          returnPath: "/",
          now: NOW,
          expiresAt: new Date(NOW.getTime() + 10 * 60_000),
        }),
      );
      await runRepository(
        repo.issueAuthCode({
          transactionHash,
          stateHash,
          codeHash,
          userId: deletingUserId,
          now: new Date(NOW.getTime() + 1),
          expiresAt: new Date(NOW.getTime() + 5 * 60_000),
        }),
      );
      await runRepository(
        repo.consumeAuthCodeAndCreateSession({
          codeHash,
          transactionHash,
          stateHash,
          pkceChallenge,
          hostname: retained.publication.hostname,
          sessionTokenHash,
          now: new Date(NOW.getTime() + 2),
          sessionExpiresAt: new Date(NOW.getTime() + 60 * 60_000),
        }),
      );

      await cloudDb().transaction(async (tx) => {
        await deleteVmPublicationRowsForAccountDeletion(tx, deletingUserId);
      });

      const [counts] = await requiredSql()<
        {
          owned_publications: number;
          owned_domains: number;
          tombstoned_domain_owner: string | null;
          retained_publications: number;
          viewer_codes: number;
          viewer_sessions: number;
        }[]
      >`
      select
        (select count(*)::int from cloud_vm_publications where id = ${owned.publication.id}) as owned_publications,
        (select count(*)::int from cloud_vm_domains where id = ${owned.domain.id}) as owned_domains,
        (select owner_user_id from cloud_vm_domains where id = ${owned.domain.id}) as tombstoned_domain_owner,
        (select count(*)::int from cloud_vm_publications where id = ${retained.publication.id}) as retained_publications,
        (select count(*)::int from cloud_vm_publication_auth_codes where user_id = ${deletingUserId}) as viewer_codes,
        (select count(*)::int from cloud_vm_publication_sessions where user_id = ${deletingUserId}) as viewer_sessions
    `;
      expect(counts).toEqual({
        owned_publications: 0,
        owned_domains: 1,
        tombstoned_domain_owner: `deleted-domain:${owned.domain.id}`,
        retained_publications: 1,
        viewer_codes: 0,
        viewer_sessions: 0,
      });
    },
  );

  dbTest(
    "binds one-use auth artifacts to state, PKCE, host, and routing revision",
    async () => {
      const repo = requiredRepository();
      const target = await createActivePublication({ suffix: "auth" });
      const transactionHash = "a".repeat(64);
      const stateHash = "b".repeat(64);
      const codeHash = "c".repeat(64);
      const sessionTokenHash = "d".repeat(64);
      const pkceChallenge = "P".repeat(43);
      const transactionExpiresAt = new Date(NOW.getTime() + 10 * 60_000);

      const transaction = await runRepository(
        repo.createAuthTransaction({
          publicationId: target.publication.id,
          transactionHash,
          pkceChallenge,
          stateHash,
          hostname: target.publication.hostname,
          returnPath: "/workspace?tab=1",
          now: NOW,
          expiresAt: transactionExpiresAt,
        }),
      );
      expect(transaction.routingRevision).toBe(
        target.publication.routingRevision,
      );
      expect(
        (
          await runRepository(
            repo.findPendingAuthTransaction({
              transactionHash,
              now: new Date(NOW.getTime() + 1),
            }),
          )
        )?.publication.hostname,
      ).toBe(target.publication.hostname);

      await expectRepositoryError(
        runRepository(
          repo.issueAuthCode({
            transactionHash,
            stateHash: "e".repeat(64),
            codeHash,
            userId: target.publication.ownerUserId,
            now: new Date(NOW.getTime() + 2),
            expiresAt: new Date(NOW.getTime() + 5 * 60_000),
          }),
        ),
        {
          _tag: "PublicationAuthArtifactError",
          reason: "transaction_state_mismatch",
        },
      );
      expect(
        await runRepository(
          repo.findPendingAuthTransaction({
            transactionHash,
            now: new Date(NOW.getTime() + 3),
          }),
        ),
      ).not.toBeNull();

      await runRepository(
        repo.issueAuthCode({
          transactionHash,
          stateHash,
          codeHash,
          userId: target.publication.ownerUserId,
          now: new Date(NOW.getTime() + 4),
          expiresAt: new Date(NOW.getTime() + 5 * 60_000),
        }),
      );
      expect(
        await runRepository(
          repo.findPendingAuthTransaction({
            transactionHash,
            now: new Date(NOW.getTime() + 5),
          }),
        ),
      ).toBeNull();
      await expectRepositoryError(
        runRepository(
          repo.issueAuthCode({
            transactionHash,
            stateHash,
            codeHash: "f".repeat(64),
            userId: target.publication.ownerUserId,
            now: new Date(NOW.getTime() + 6),
            expiresAt: new Date(NOW.getTime() + 5 * 60_000),
          }),
        ),
        {
          _tag: "PublicationAuthArtifactError",
          reason: "transaction_replayed",
        },
      );

      await expectRepositoryError(
        runRepository(
          repo.consumeAuthCodeAndCreateSession({
            codeHash,
            transactionHash,
            stateHash,
            pkceChallenge: "Q".repeat(43),
            hostname: target.publication.hostname,
            sessionTokenHash,
            now: new Date(NOW.getTime() + 7),
            sessionExpiresAt: new Date(NOW.getTime() + 60 * 60_000),
          }),
        ),
        {
          _tag: "PublicationAuthArtifactError",
          reason: "transaction_pkce_mismatch",
        },
      );
      const consumed = await runRepository(
        repo.consumeAuthCodeAndCreateSession({
          codeHash,
          transactionHash,
          stateHash,
          pkceChallenge,
          hostname: target.publication.hostname,
          sessionTokenHash,
          now: new Date(NOW.getTime() + 8),
          sessionExpiresAt: new Date(NOW.getTime() + 60 * 60_000),
        }),
      );
      expect(consumed.returnPath).toBe("/workspace?tab=1");
      expect(consumed.session.userId).toBe(target.publication.ownerUserId);
      expect(
        await runRepository(
          repo.findValidSession({
            tokenHash: sessionTokenHash,
            publicationId: target.publication.id,
            hostname: target.publication.hostname,
            now: new Date(NOW.getTime() + 9),
          }),
        ),
      ).not.toBeNull();
      await expectRepositoryError(
        runRepository(
          repo.consumeAuthCodeAndCreateSession({
            codeHash,
            transactionHash,
            stateHash,
            pkceChallenge,
            hostname: target.publication.hostname,
            sessionTokenHash: "0".repeat(64),
            now: new Date(NOW.getTime() + 10),
            sessionExpiresAt: new Date(NOW.getTime() + 60 * 60_000),
          }),
        ),
        {
          _tag: "PublicationAuthArtifactError",
          reason: "authorization_code_replayed",
        },
      );

      const updated = await runRepository(
        repo.commitAccessPolicy({
          id: target.publication.id,
          ownerUserId: target.publication.ownerUserId,
          expectedRoutingRevision: target.publication.routingRevision,
          accessMode: "public",
          now: new Date(NOW.getTime() + 11),
        }),
      );
      expect(updated.routingRevision).toBe(
        target.publication.routingRevision + 1,
      );
      expect(
        await runRepository(
          repo.findValidSession({
            tokenHash: sessionTokenHash,
            publicationId: target.publication.id,
            hostname: target.publication.hostname,
            now: new Date(NOW.getTime() + 12),
          }),
        ),
      ).toBeNull();
    },
  );

  dbTest(
    "publishes a team-billed VM by current membership rather than by creator",
    async () => {
      const repo = requiredRepository();
      await insertVm("creator", "team-vm", "team-a");
      const reserve = (input: {
        readonly ownerUserId: string;
        readonly billingTeamId?: string | null;
        readonly teamIds: readonly string[];
        readonly hostname: string;
      }) =>
        runRepository(
          repo.reservePublicationWithNewDomain({
            ownerUserId: input.ownerUserId,
            billingTeamId: input.billingTeamId,
            teamIds: input.teamIds,
            provider: "freestyle",
            providerVmId: "team-vm",
            domainHostname: input.hostname,
            hostname: input.hostname,
            kind: "generated",
            port: 3_000,
            accessMode: "public",
            now: NOW,
          }),
        );

      // A member acting in the team scope publishes it even though they did
      // not create it, and the publication stays owned by that member.
      const member = await reserve({
        ownerUserId: "member-1",
        billingTeamId: "team-a",
        teamIds: ["team-a"],
        hostname: "member.cmux.sh",
      });
      expect(member.publication.ownerUserId).toBe("member-1");
      expect(member.vm.billingTeamId).toBe("team-a");

      // Naming the team without being a member fails closed as not found.
      await expectRepositoryError(
        reserve({
          ownerUserId: "outsider",
          billingTeamId: "team-a",
          teamIds: ["team-b"],
          hostname: "outsider.cmux.sh",
        }),
        { _tag: "PublicationNotFoundError", resource: "vm" },
      );
      // The creator's personal scope no longer sees a VM billed to a team,
      // exactly like the other VM routes.
      await expectRepositoryError(
        reserve({
          ownerUserId: "creator",
          teamIds: [],
          hostname: "creator.cmux.sh",
        }),
        { _tag: "PublicationNotFoundError", resource: "vm" },
      );
    },
  );

  dbTest(
    "lets a delete resume a publication left disabling by a failed sweep",
    async () => {
      const repo = requiredRepository();
      const target = await createActivePublication({ suffix: "resume-delete" });
      const disabling = await runRepository(
        repo.beginDisablePublication({
          id: target.publication.id,
          ownerUserId: target.publication.ownerUserId,
          now: NOW,
        }),
      );
      expect(disabling.state).toBe("disabling");
      const claim = (intent?: "mutate" | "disable") =>
        runRepository(
          repo.claimVmPublicationOperation({
            publicationId: target.publication.id,
            ownerUserId: target.publication.ownerUserId,
            leaseId: randomUUID(),
            intent,
            now: new Date(NOW.getTime() + 1),
            leaseExpiresAt: new Date(NOW.getTime() + 60_000),
          }),
        );

      await expectRepositoryError(claim(), {
        _tag: "PublicationConflictError",
        reason: "publication_not_active",
      });
      await expectRepositoryError(claim("mutate"), {
        _tag: "PublicationConflictError",
        reason: "publication_not_active",
      });
      expect(await claim("disable")).toEqual({ kind: "claimed", vmId: target.vm.id });

      await runRepository(
        repo.finishDisablePublication({
          id: target.publication.id,
          now: new Date(NOW.getTime() + 2),
        }),
      );
      await expectRepositoryError(claim("disable"), {
        _tag: "PublicationConflictError",
        reason: "publication_not_active",
      });
    },
  );

  dbTest(
    "retires expired auth artifacts on the hot path and caps pending transactions",
    async () => {
      const repo = requiredRepository();
      const sql = requiredSql();
      const target = await createActivePublication({ suffix: "auth-hygiene" });
      const publicationId = target.publication.id;
      const hash = (prefix: string, index: number) =>
        createHash("sha256").update(`${prefix}-${index}`).digest("hex");
      const later = new Date(NOW.getTime() + 60_000);

      // Seed many expired transactions plus a full pending set, oldest first.
      const expiredRows = Array.from({ length: AUTH_ARTIFACT_SWEEP_LIMIT + 5 }, (_, index) => ({
        transaction_hash: hash("e", index),
        publication_id: publicationId,
        routing_revision: target.publication.routingRevision,
        pkce_challenge: "P".repeat(43),
        state_hash: hash("s", index),
        hostname: target.publication.hostname,
        return_path: "/",
        created_at: new Date(NOW.getTime() - 120_000),
        expires_at: new Date(NOW.getTime() - 60_000),
      }));
      const pendingRows = Array.from({ length: MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION }, (_, index) => ({
        transaction_hash: hash("p", index),
        publication_id: publicationId,
        routing_revision: target.publication.routingRevision,
        pkce_challenge: "P".repeat(43),
        state_hash: hash("t", index),
        hostname: target.publication.hostname,
        return_path: "/",
        created_at: new Date(NOW.getTime() + index),
        expires_at: new Date(later.getTime() + 600_000),
      }));
      await sql`insert into cloud_vm_publication_auth_transactions ${sql(expiredRows)}`;
      await sql`insert into cloud_vm_publication_auth_transactions ${sql(pendingRows)}`;

      await runRepository(
        repo.createAuthTransaction({
          publicationId,
          transactionHash: hash("n", 0),
          pkceChallenge: "P".repeat(43),
          stateHash: hash("u", 0),
          hostname: target.publication.hostname,
          returnPath: "/",
          now: later,
          expiresAt: new Date(later.getTime() + 600_000),
        }),
      );

      const [counts] = await sql<{ expired: string; pending: string; oldest_pending: string }[]>`
        select
          count(*) filter (where expires_at <= ${later}) as expired,
          count(*) filter (where expires_at > ${later} and consumed_at is null) as pending,
          count(*) filter (where transaction_hash = ${hash("p", 0)}) as oldest_pending
        from cloud_vm_publication_auth_transactions
        where publication_id = ${publicationId}
      `;
      // One bounded batch of expired rows is gone, the oldest pending row made
      // room for the new one, and the pending set never exceeds the cap.
      expect(Number(counts?.expired)).toBe(5);
      expect(Number(counts?.pending)).toBe(MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION);
      expect(Number(counts?.oldest_pending)).toBe(0);

      // Sessions: an expired or revoked session is retired when a new one is minted.
      await sql`
        insert into cloud_vm_publication_sessions (
          token_hash, publication_id, user_id, routing_revision, created_at, expires_at, revoked_at
        ) values
          (${hash("x", 1)}, ${publicationId}, 'viewer', ${target.publication.routingRevision},
            ${new Date(NOW.getTime() - 7_200_000)}, ${new Date(NOW.getTime() - 3_600_000)}, null),
          (${hash("x", 2)}, ${publicationId}, 'viewer', ${target.publication.routingRevision},
            ${NOW}, ${new Date(later.getTime() + 600_000)}, ${NOW}),
          (${hash("x", 3)}, ${publicationId}, 'viewer', ${target.publication.routingRevision},
            ${NOW}, ${new Date(later.getTime() + 600_000)}, null)
      `;
      const codeHash = hash("c", 0);
      await runRepository(
        repo.issueAuthCode({
          transactionHash: hash("n", 0),
          stateHash: hash("u", 0),
          codeHash,
          userId: target.publication.ownerUserId,
          now: new Date(later.getTime() + 1),
          expiresAt: new Date(later.getTime() + 60_000),
        }),
      );
      await runRepository(
        repo.consumeAuthCodeAndCreateSession({
          codeHash,
          transactionHash: hash("n", 0),
          stateHash: hash("u", 0),
          pkceChallenge: "P".repeat(43),
          hostname: target.publication.hostname,
          sessionTokenHash: hash("y", 0),
          now: new Date(later.getTime() + 2),
          sessionExpiresAt: new Date(later.getTime() + 3_600_000),
        }),
      );
      const sessions = await sql<{ token_hash: string }[]>`
        select token_hash from cloud_vm_publication_sessions
        where publication_id = ${publicationId} order by token_hash
      `;
      expect(sessions.map((row) => row.token_hash).sort()).toEqual(
        [hash("x", 3), hash("y", 0)].sort(),
      );
    },
  );

  dbTest(
    "never lists a disabled publication for account deletion sweeps",
    async () => {
      const repo = requiredRepository();
      const ownerUserId = "owner-sweep-scope";
      const finished = await createActivePublication({
        suffix: "sweep-finished",
        ownerUserId,
      });
      const live = await createActivePublication({
        suffix: "sweep-live",
        ownerUserId,
      });
      await runRepository(
        repo.beginDisablePublication({
          id: finished.publication.id,
          ownerUserId,
          now: NOW,
        }),
      );
      await runRepository(
        repo.finishDisablePublication({
          id: finished.publication.id,
          now: new Date(NOW.getTime() + 1),
        }),
      );
      const stuck = await createActivePublication({
        suffix: "sweep-stuck",
        ownerUserId,
      });
      await runRepository(
        repo.beginDisablePublication({
          id: stuck.publication.id,
          ownerUserId,
          now: new Date(NOW.getTime() + 2),
        }),
      );

      const targets = await runRepository(
        repo.listPublicationsForAccountDeletion(ownerUserId),
      );
      expect(targets.map((target) => target.publicationId).sort()).toEqual(
        [live.publication.id, stuck.publication.id].sort(),
      );
    },
  );

  dbTest(
    "addresses publications and zones by hostname within one owner",
    async () => {
      const repo = requiredRepository();
      const live = await createActivePublication({ suffix: "by-hostname" });
      const ownerUserId = live.publication.ownerUserId;
      const byHostname = await runRepository(
        repo.findOwnedPublicationByHostname({
          hostname: ` ${live.publication.hostname.toUpperCase()}. `,
          ownerUserId,
        }),
      );
      expect(byHostname?.publication.id).toBe(live.publication.id);
      expect(
        await runRepository(
          repo.findOwnedPublicationByHostname({
            hostname: live.publication.hostname,
            ownerUserId: "someone-else",
          }),
        ),
      ).toBeNull();

      await runRepository(
        repo.beginDisablePublication({ id: live.publication.id, ownerUserId, now: NOW }),
      );
      await runRepository(
        repo.finishDisablePublication({
          id: live.publication.id,
          now: new Date(NOW.getTime() + 1),
        }),
      );
      expect(
        await runRepository(
          repo.findOwnedPublicationByHostname({
            hostname: live.publication.hostname,
            ownerUserId,
          }),
        ),
      ).toBeNull();

      // A verified zone wins over a newer pending attempt on the same hostname.
      const pendingFirst = await runRepository(
        repo.createDomain({
          ownerUserId,
          hostname: "zone.example.test",
          kind: "custom",
          provider: "freestyle",
          verificationState: "pending",
          certificateState: "missing",
          now: NOW,
        }),
      );
      const verified = await runRepository(
        repo.updateDomainState({
          id: pendingFirst.id,
          ownerUserId,
          providerVerificationId: "verification-zone-1",
          verificationState: "verified",
          certificateState: "pending",
          now: new Date(NOW.getTime() + 2),
        }),
      );
      await runRepository(
        repo.createDomain({
          ownerUserId,
          hostname: "zone.example.test",
          kind: "custom",
          provider: "freestyle",
          verificationState: "pending",
          certificateState: "missing",
          now: new Date(NOW.getTime() + 3),
        }),
      );
      expect(
        (
          await runRepository(
            repo.findOwnedDomainByHostname({ hostname: "Zone.Example.Test", ownerUserId }),
          )
        )?.id,
      ).toBe(verified.id);
      expect(
        await runRepository(
          repo.findOwnedDomainByHostname({ hostname: "zone.example.test", ownerUserId: "other" }),
        ),
      ).toBeNull();
    },
  );
});
