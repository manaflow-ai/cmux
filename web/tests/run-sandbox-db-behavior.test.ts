import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import type { Sql } from "postgres";
type RunRepositoryModule = typeof import("../services/runs/repository");

// A sandboxed Run (hq#3367) keeps nothing: each terminal path makes its VM due for destroy now,
// and the reaper fails a sandbox whose launcher died. Runs against a real database.
const dbEnabled = process.env.CMUX_DB_TEST === "1";
const dbTest = dbEnabled ? test : test.skip;
let sql: Sql | null = null;
let repository: RunRepositoryModule | null = null;

beforeAll(async () => {
  if (!dbEnabled) return;
  const [{ default: postgres }, loaded] = await Promise.all([import("postgres"), import("../services/runs/repository")]);
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 1 });
  repository = loaded;
});

afterAll(async () => {
  if (dbEnabled) await (await import("../db/client")).closeCloudDbForTests();
  await sql?.end();
});

function repo(): RunRepositoryModule {
  if (!repository) throw new Error("Run repository was not loaded");
  return repository;
}

function input(userId: string, environment: "sandboxed" | "persistent" = "sandboxed") {
  const value = environment === "sandboxed"
    ? { source: {}, recipe: "sandbox-task", desiredAttempts: 1, environment, imageId: "sh-test-image", imageVersion: "test-version" } as const
    : { source: { repository: "manaflow-ai/cmux", commit: "c".repeat(40) }, recipe: "parallel-review", desiredAttempts: 1, environment } as const;
  return {
    userId,
    billingTeamId: userId,
    idempotencyKey: `sandbox-test-${randomUUID()}`,
    requestDigest: repo().requestDigest({ ...value, nonce: randomUUID() }),
    ...value,
  };
}

async function startedAttempt(userId: string, environment: "sandboxed" | "persistent" = "sandboxed") {
  const created = await repo().createRun(input(userId, environment));
  const attempt = created.attempts[0];
  if (!attempt) throw new Error("run did not create an attempt");
  const lease = await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "sandbox-worker" });
  await repo().ingestRunEvent({
    runId: created.run.id, attemptId: attempt.id, leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration,
    externalId: "attempt-started", attemptSequence: 0, kind: "attempt.started", payload: { providerVmId: `vm-${attempt.id}` },
  });
  return { runId: created.run.id, attemptId: attempt.id, lease };
}

/** A VM row as the sandbox launcher leaves it: its create key and the matching server-set marker. */
async function insertSandboxVm(userId: string, key: string, providerVmId: string, marked = true): Promise<void> {
  await sql!`insert into cloud_vms (user_id, billing_team_id, provider, image_id, status, idempotency_key, provider_vm_id, provider_metadata)
    values (${userId}, ${userId}, 'freestyle', 'sh-test-image', 'running', ${key}, ${providerVmId}, ${sql!.json(marked ? { cmuxSandboxRun: key } : {})})`;
}

/** The launcher's end: the terminal event, then the handoff that makes the VM due at once. */
async function finishAttempt(target: { runId: string; attemptId: string; lease: { leaseToken: string; leaseGeneration: number } }, kind: "attempt.succeeded" | "attempt.failed" = "attempt.succeeded"): Promise<void> {
  await repo().ingestRunEvent({ runId: target.runId, attemptId: target.attemptId, ...target.lease, externalId: "end", attemptSequence: 1, kind, payload: kind === "attempt.failed" ? { error: "x" } : {} });
  await repo().scheduleAttemptRetention({ runId: target.runId, attemptId: target.attemptId, ...target.lease, retentionMs: 0 });
}

async function removeRuns(userId: string): Promise<void> {
  await sql!`delete from runs where user_id = ${userId}`;
}

describe("sandboxed Run lifecycle in the repository", () => {
  dbTest("a sandboxed Run needs exactly one attempt and a pinned image", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      await expect(repo().createRun({ ...input(userId), imageId: null })).rejects.toThrow("pinned image");
      await expect(repo().createRun({ ...input(userId), desiredAttempts: 2 })).rejects.toThrow("exactly one attempt");
      await expect(repo().createRun({ ...input(userId), billingTeamId: null })).rejects.toThrow("billing team");
      const created = await repo().createRun(input(userId));
      expect(created.run).toMatchObject({ environment: "sandboxed", imageId: "sh-test-image", imageVersion: "test-version" });
      const constraint = await sql!`update runs set desired_attempts = 2 where id = ${created.run.id}`.then(() => null, (error: unknown) => error);
      expect(String(constraint)).toContain("runs_sandboxed_single_attempt_check");
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("success and failure make the VM due now; a persistent Run keeps its attach window", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      for (const kind of ["attempt.succeeded", "attempt.failed"] as const) {
        const { runId, attemptId, lease } = await startedAttempt(userId);
        await repo().ingestRunEvent({ runId, attemptId, ...lease, externalId: `end-${kind}`, attemptSequence: 1, kind });
        // The launcher's handoff window: not yet the reaper's.
        expect(await repo().claimExpiredAttemptCleanups({ runId })).toEqual([]);
        // The launcher's handoff makes it due at once.
        await repo().scheduleAttemptRetention({ runId, attemptId, ...lease, retentionMs: 0 });
        const claims = await repo().claimExpiredAttemptCleanups({ runId });
        expect(claims.map((claim) => claim.attempt.id)).toEqual([attemptId]);
        await repo().finishAttemptCleanup({ attemptId, cleanupLeaseToken: claims[0]!.cleanupLeaseToken, succeeded: true });
        const snapshot = await repo().getRun(runId, userId);
        expect(snapshot.attempts[0]?.providerVmId).toBeNull();
        // Once the VM is gone, the launcher's lease is gone with it.
        expect(snapshot.attempts[0]?.leaseToken).toBeNull();
      }
      const persistent = await startedAttempt(userId, "persistent");
      await repo().ingestRunEvent({ runId: persistent.runId, attemptId: persistent.attemptId, ...persistent.lease, externalId: "end", attemptSequence: 1, kind: "attempt.succeeded" });
      expect(await repo().claimExpiredAttemptCleanups({ runId: persistent.runId })).toEqual([]);
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("cancel makes the VM due now and the scoped claim takes only that Run's VM", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const cancelled = await startedAttempt(userId);
      const other = await startedAttempt(userId);
      await repo().cancelRun(cancelled.runId, userId);
      await repo().finalizeAttemptCancellation({ runId: cancelled.runId, attemptId: cancelled.attemptId, leaseToken: cancelled.lease.leaseToken, leaseGeneration: cancelled.lease.leaseGeneration });
      await finishAttempt(other);
      const claims = await repo().claimExpiredAttemptCleanups({ runId: cancelled.runId });
      expect(claims.map((claim) => claim.attempt.id)).toEqual([cancelled.attemptId]);
      expect((await repo().getRun(cancelled.runId, userId)).run.status).toBe("cancelled");
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("a sandboxed attempt is never attachable, and only its own marked VM row is its VM", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { toRunSnapshotView } = await import("../services/runs/view");
      const sandbox = await startedAttempt(userId);
      const persistent = await startedAttempt(userId, "persistent");
      for (const target of [sandbox, persistent]) {
        await sql!`update run_attempts set provider_workspace_id = 'ws-1', provider_terminal_id = 'term-1' where id = ${target.attemptId}`;
        // The terminal event opens the handoff window (sandbox) or the attach window (persistent).
        await repo().ingestRunEvent({ runId: target.runId, attemptId: target.attemptId, ...target.lease, externalId: "end", attemptSequence: 1, kind: "attempt.succeeded" });
      }
      await expect(repo().mintRunAttachTicket({ runId: sandbox.runId, attemptId: sandbox.attemptId, userId })).rejects.toThrow("sandboxed");
      expect(toRunSnapshotView(await repo().getRun(sandbox.runId, userId)).attempts[0]?.attachable).toBe(false);
      expect(toRunSnapshotView(await repo().getRun(persistent.runId, userId)).attempts[0]?.attachable).toBe(true);
      expect((await repo().mintRunAttachTicket({ runId: persistent.runId, attemptId: persistent.attemptId, userId })).ticket).toBeTruthy();

      // A VM id from an event is the attempt's VM only with the launcher's keyed, marked row for that user.
      const owned = { providerVmId: `vm-${sandbox.attemptId}`, runId: sandbox.runId, attemptId: sandbox.attemptId, userId };
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(false);
      const key = `sandbox-run:${sandbox.runId}:attempt:${sandbox.attemptId}`;
      // Another user's row with that VM id and key is not this attempt's VM.
      await insertSandboxVm(`other-${userId}`, key, owned.providerVmId);
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(false);
      // This user's row without the server-set marker is not either.
      await sql!`update cloud_vms set user_id = ${userId}, billing_team_id = ${userId}, provider_metadata = '{}'::jsonb where provider_vm_id = ${owned.providerVmId}`;
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(false);
      await sql!`update cloud_vms set provider_metadata = ${sql!.json({ cmuxSandboxRun: key })} where provider_vm_id = ${owned.providerVmId}`;
      expect(await repo().sandboxVmOwnedByAttempt(owned)).toBe(true);
    } finally {
      await sql!`delete from cloud_vms where user_id in ${sql!([userId, `other-${userId}`])}`;
      await removeRuns(userId);
    }
  });

  dbTest("forced cancellation of a vanished launcher makes the VM due now", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { runId, attemptId } = await startedAttempt(userId);
      await repo().cancelRun(runId, userId);
      await repo().forceFinalizeRunCancellation(runId, userId);
      expect((await repo().claimExpiredAttemptCleanups({ runId })).map((claim) => claim.attempt.id)).toEqual([attemptId]);
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("the reaper fails a sandbox whose launcher died, and its VM becomes due", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const lapsed = await startedAttempt(userId);
      const live = await startedAttempt(userId);
      const persistent = await startedAttempt(userId, "persistent");
      const queued = await repo().createRun(input(userId));
      await sql!`update run_attempts set lease_expires_at = now() - interval '10 minutes' where id in ${sql!([lapsed.attemptId, persistent.attemptId])}`;
      await sql!`update runs set created_at = now() - interval '1 hour' where id = ${queued.run.id}`;

      // Other test files share the table, so assert on this user's rows rather than the count.
      await repo().failAbandonedSandboxAttempts({ limit: 100 });

      const failed = await repo().getRun(lapsed.runId, userId);
      expect(failed.run.status).toBe("failed");
      expect(failed.attempts[0]).toMatchObject({ status: "failed", leaseToken: null });
      expect(failed.attempts[0]?.terminalRetainUntil?.getTime()).toBeLessThanOrEqual(Date.now());
      expect((await repo().claimExpiredAttemptCleanups({ runId: lapsed.runId })).map((claim) => claim.attempt.id)).toEqual([lapsed.attemptId]);
      const events = await repo().listRunEvents({ runId: lapsed.runId, userId });
      expect(events.events.map((event) => event.kind)).toContain("run.completed");

      const neverLeased = await repo().getRun(queued.run.id, userId);
      expect(neverLeased.run.status).toBe("failed");
      expect(neverLeased.attempts[0]).toMatchObject({ status: "failed", providerVmId: null, terminalRetainUntil: null });

      expect((await repo().getRun(live.runId, userId)).attempts[0]?.status).toBe("running");
      expect((await repo().getRun(persistent.runId, userId)).attempts[0]?.status).toBe("running");

      // A second pass finds nothing more to do for these rows.
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      expect((await repo().listRunEvents({ runId: lapsed.runId, userId })).events.filter((event) => event.kind === "run.completed")).toHaveLength(1);
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("a VM created but never journaled is adopted after a cancel and reported pending until destroyed", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0]!;
      await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "sandbox-worker" });
      // The launcher created the VM, then died before journaling it.
      const vmId = `vm-orphan-${randomUUID()}`;
      await insertSandboxVm(userId, `sandbox-run:${created.run.id}:attempt:${attempt.id}`, vmId);
      await repo().cancelRun(created.run.id, userId);
      await repo().forceFinalizeRunCancellation(created.run.id, userId);
      const cancelled = await repo().getRun(created.run.id, userId);
      expect(cancelled.attempts[0]).toMatchObject({ status: "cancelled", providerVmId: null });

      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      const claims = await repo().claimExpiredAttemptCleanups({ runId: created.run.id });
      expect(claims.map((claim) => claim.attempt.providerVmId)).toEqual([vmId]);

      // The reaper destroyed it and cleared the row; the VM row says destroyed; no second adoption.
      await repo().finishAttemptCleanup({ attemptId: attempt.id, cleanupLeaseToken: claims[0]!.cleanupLeaseToken, succeeded: true });
      await sql!`update cloud_vms set status = 'destroyed' where provider_vm_id = ${vmId}`;
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      const done = await repo().getRun(created.run.id, userId);
      expect(done.attempts[0]?.providerVmId).toBeNull();
    } finally {
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });

  dbTest("a VM the provider already lost is adopted once, not every sweep", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0]!;
      const vmId = `vm-lost-${randomUUID()}`;
      await insertSandboxVm(userId, `sandbox-run:${created.run.id}:attempt:${attempt.id}`, vmId);
      await repo().cancelRun(created.run.id, userId);
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      const claims = await repo().claimExpiredAttemptCleanups({ runId: created.run.id });
      expect(claims).toHaveLength(1);
      // The destroy answered not-found, so the reaper cleared the row but the VM row stays running.
      await repo().finishAttemptCleanup({ attemptId: attempt.id, cleanupLeaseToken: claims[0]!.cleanupLeaseToken, succeeded: true });
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      expect(await repo().claimExpiredAttemptCleanups({ runId: created.run.id })).toEqual([]);
      // The adoption event's id is opaque: the VM id is in no field a Run view shows.
      const events = await repo().listRunEvents({ runId: created.run.id, userId });
      expect(events.events.map((event) => event.externalId)).not.toContain(expect.stringContaining(vmId));

      // An adopted row never takes the batch ahead of a live orphan, however old.
      const second = await repo().createRun(input(userId));
      const secondAttempt = second.attempts[0]!;
      const secondVm = `vm-old-${randomUUID()}`;
      await insertSandboxVm(userId, `sandbox-run:${second.run.id}:attempt:${secondAttempt.id}`, secondVm);
      await repo().cancelRun(second.run.id, userId);
      await sql!`update runs set updated_at = now() - interval '3 days' where id = ${second.run.id}`;
      await repo().failAbandonedSandboxAttempts({ limit: 1 });
      expect((await repo().claimExpiredAttemptCleanups({ runId: second.run.id })).map((claim) => claim.attempt.providerVmId)).toEqual([secondVm]);
    } finally {
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });

  dbTest("the reaper keeps a sandbox VM it can't reach while its VM row is up, and retries it later", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const started = await startedAttempt(userId);
      const { runId, attemptId } = started;
      await finishAttempt(started);
      const vmId = `vm-${attemptId}`;
      // Recorded under another owner: the run's scope can't reach it, but it is not destroyed.
      await sql!`insert into cloud_vms (user_id, billing_team_id, owner_team_id, provider, image_id, status, provider_vm_id)
        values ('someone-else', 'other-team', 'other-team', 'freestyle', 'sh-test-image', 'running', ${vmId})`;
      const { reapExpiredCloudVmAttempts } = await import("../services/runs/dogfood");
      const result = await reapExpiredCloudVmAttempts({ runId });
      expect(result).toMatchObject({ claimed: 1, cleaned: 0, errors: 1 });
      const kept = (await repo().getRun(runId, userId)).attempts[0]!;
      expect(kept.providerVmId).toBe(vmId);
      expect(kept.terminalRetainUntil!.getTime()).toBeGreaterThan(Date.now() + 5 * 60_000);
      expect(await repo().claimExpiredAttemptCleanups({ runId })).toEqual([]);
    } finally {
      await sql!`delete from cloud_vms where user_id = 'someone-else' and provider_vm_id like 'vm-%'`;
      await removeRuns(userId);
    }
  });

  dbTest("with no live VM row left, the reaper asks the provider about the attempt's own VM and only then lets the handle go", async () => {
    const userId = `sandbox-${randomUUID()}`;
    const foreignUser = `other-${userId}`;
    const destroyed: string[] = [];
    const { mock } = await import("bun:test");
    const drivers = await import("../services/vms/drivers");
    // `drivers` is a live module namespace: keep a copy of the real exports to restore.
    const original = { ...drivers };
    mock.module("../services/vms/drivers", () => ({
      ...original,
      getProvider: () => ({ destroy: async (id: string, _credential?: unknown, options?: { strict?: boolean }) => {
        // The no-row fallback always asks for a strict destroy.
        expect(options?.strict).toBe(true);
        destroyed.push(id);
        if (id.endsWith("-down")) throw new Error("provider unavailable");
        // An endpoint 404 is not the provider saying the machine is gone.
        if (id.endsWith("-route")) throw Object.assign(new Error("no route"), { status: 404, code: "ROUTE_NOT_FOUND" });
      } }),
    }));
    // The launcher's row for the attempt's VM, already reconciled to destroyed (so not live).
    const destroyedRow = async (target: { runId: string; attemptId: string }, vmId: string) => {
      await insertSandboxVm(userId, `sandbox-run:${target.runId}:attempt:${target.attemptId}`, vmId);
      await sql!`update cloud_vms set status = 'destroyed', destroyed_at = now() where provider_vm_id = ${vmId}`;
    };
    try {
      const { reapExpiredCloudVmAttempts } = await import("../services/runs/dogfood");
      const gone = await startedAttempt(userId);
      const down = await startedAttempt(userId);
      await sql!`update run_attempts set provider_vm_id = ${`vm-${down.attemptId}-down`} where id = ${down.attemptId}`;
      await destroyedRow(gone, `vm-${gone.attemptId}`);
      await destroyedRow(down, `vm-${down.attemptId}-down`);
      for (const target of [gone, down]) {
        await finishAttempt(target);
      }
      expect(await reapExpiredCloudVmAttempts({ runId: gone.runId })).toMatchObject({ claimed: 1, cleaned: 1, errors: 0 });
      expect((await repo().getRun(gone.runId, userId)).attempts[0]?.providerVmId).toBeNull();
      expect(await reapExpiredCloudVmAttempts({ runId: down.runId })).toMatchObject({ claimed: 1, cleaned: 0, errors: 1 });
      expect((await repo().getRun(down.runId, userId)).attempts[0]?.providerVmId).toBe(`vm-${down.attemptId}-down`);
      // Claimed by the reaper (deferred, failed or done): the launcher's lease is gone.
      expect((await repo().getRun(down.runId, userId)).attempts[0]?.leaseToken).toBeNull();
      const route = await startedAttempt(userId);
      await sql!`update run_attempts set provider_vm_id = ${`vm-${route.attemptId}-route`} where id = ${route.attemptId}`;
      await destroyedRow(route, `vm-${route.attemptId}-route`);
      await finishAttempt(route);
      expect(await reapExpiredCloudVmAttempts({ runId: route.runId })).toMatchObject({ claimed: 1, cleaned: 0, errors: 1 });
      expect((await repo().getRun(route.runId, userId)).attempts[0]?.providerVmId).toBe(`vm-${route.attemptId}-route`);
      // A VM id that only came from the worker's event (no launcher row for this attempt and user)
      // is never destroyed through the provider: the handle is released untouched.
      const forged = await startedAttempt(userId);
      await finishAttempt(forged);
      expect(await reapExpiredCloudVmAttempts({ runId: forged.runId })).toMatchObject({ claimed: 1, cleaned: 0, errors: 0 });
      expect((await repo().getRun(forged.runId, userId)).attempts[0]?.providerVmId).toBeNull();
      // The same for an id naming another user's marked sandbox VM: no destroy, and its row is not
      // marked as a confirmed destroy, so its own orphan sweep still finds it.
      const foreignVm = `vm-foreign-${randomUUID()}`;
      await insertSandboxVm(foreignUser, `sandbox-run:${randomUUID()}:attempt:${randomUUID()}`, foreignVm);
      await sql!`update cloud_vms set status = 'destroyed', destroyed_at = now() where provider_vm_id = ${foreignVm}`;
      const pointed = await startedAttempt(userId);
      await sql!`update run_attempts set provider_vm_id = ${foreignVm} where id = ${pointed.attemptId}`;
      await finishAttempt(pointed);
      expect(await reapExpiredCloudVmAttempts({ runId: pointed.runId })).toMatchObject({ claimed: 1, cleaned: 0, errors: 0 });
      const [foreignRow] = await sql!`select provider_metadata from cloud_vms where provider_vm_id = ${foreignVm}`;
      expect(foreignRow?.provider_metadata?.cmuxSandboxDestroyConfirmed).toBeUndefined();
      // An ownership lookup that fails is no answer: no provider call, and the obligation waits.
      const repositoryModule = await import("../services/runs/repository");
      const realRepository = { ...repositoryModule };
      mock.module("../services/runs/repository", () => ({ ...realRepository, sandboxVmOwnedByAttempt: async () => { throw new Error("db unavailable"); } }));
      try {
        const unknown = await startedAttempt(userId);
        await finishAttempt(unknown);
        expect(await reapExpiredCloudVmAttempts({ runId: unknown.runId })).toMatchObject({ claimed: 1, cleaned: 0, errors: 1 });
        expect((await repo().getRun(unknown.runId, userId)).attempts[0]?.providerVmId).toBe(`vm-${unknown.attemptId}`);
      } finally {
        mock.module("../services/runs/repository", () => realRepository);
      }
      expect(destroyed).toEqual([`vm-${gone.attemptId}`, `vm-${down.attemptId}-down`, `vm-${route.attemptId}-route`]);
    } finally {
      mock.module("../services/vms/drivers", () => original);
      await sql!`delete from cloud_vms where user_id in ${sql!([userId, foreignUser])}`;
      await removeRuns(userId);
    }
  });

  dbTest("a row that only carries the sandbox key prefix, without the launcher's marker, is never adopted", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0]!;
      await insertSandboxVm(userId, `sandbox-run:${created.run.id}:attempt:${attempt.id}`, `vm-unmarked-${randomUUID()}`, false);
      await repo().cancelRun(created.run.id, userId);
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      expect(await repo().claimExpiredAttemptCleanups({ runId: created.run.id })).toEqual([]);
    } finally {
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });

  dbTest("a cancel's own reap adopts that Run's orphan VM, and a sandbox destroy that keeps failing is retried later", async () => {
    const userId = `sandbox-${randomUUID()}`;
    const { mock } = await import("bun:test");
    const drivers = await import("../services/vms/drivers");
    const original = { ...drivers };
    mock.module("../services/vms/drivers", () => ({
      ...original,
      getProvider: () => ({ destroy: async () => { throw new Error("provider unavailable"); } }),
    }));
    try {
      const { reapExpiredCloudVmAttempts } = await import("../services/runs/dogfood");
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0]!;
      await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "sandbox-worker" });
      const vmId = `vm-cancel-orphan-${randomUUID()}`;
      const key = `sandbox-run:${created.run.id}:attempt:${attempt.id}`;
      // Reachable by the Run's scope, so the destroy reaches the (failing) provider.
      await sql!`insert into cloud_vms (user_id, billing_team_id, owner_team_id, provider, image_id, status, idempotency_key, provider_vm_id, provider_metadata)
        values (${userId}, ${userId}, ${userId}, 'freestyle', 'sh-test-image', 'running', ${key}, ${vmId}, ${sql!.json({ cmuxSandboxRun: key })})`;
      await repo().cancelRun(created.run.id, userId);
      await repo().forceFinalizeRunCancellation(created.run.id, userId);
      // The cancel's scoped reap: adopts the orphan now, without waiting for the cron pass.
      const result = await reapExpiredCloudVmAttempts({ runId: created.run.id });
      expect(result).toMatchObject({ claimed: 1, cleaned: 0, errors: 1 });
      const kept = (await repo().getRun(created.run.id, userId)).attempts[0]!;
      expect(kept.providerVmId).toBe(vmId);
      // The failed destroy is deferred, not left at the head of every batch.
      expect(kept.terminalRetainUntil!.getTime()).toBeGreaterThan(Date.now() + 5 * 60_000);
      expect(await repo().claimExpiredAttemptCleanups({ runId: created.run.id })).toEqual([]);
    } finally {
      mock.module("../services/vms/drivers", () => original);
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });

  dbTest("a worker can't take the sweep's event id, so the sweep always lands", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { runId, attemptId, lease } = await startedAttempt(userId);
      await expect(repo().ingestRunEvent({ runId, attemptId, ...lease, externalId: `cmux:sandbox-abandoned:${lease.leaseGeneration}`, attemptSequence: 1, kind: "attempt.heartbeat" }))
        .rejects.toThrow("reserved prefix");
      // The old, unprefixed id a worker might have used is no obstacle either.
      await repo().ingestRunEvent({ runId, attemptId, ...lease, externalId: `sandbox-abandoned:${lease.leaseGeneration}`, attemptSequence: 2, kind: "attempt.heartbeat" });
      await sql!`update run_attempts set lease_expires_at = now() - interval '10 minutes' where id = ${attemptId}`;
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      expect((await repo().getRun(runId, userId)).attempts[0]).toMatchObject({ status: "failed" });
    } finally {
      await removeRuns(userId);
    }
  });

  dbTest("the repository reserves the sandbox key: no unmarked create, and no unmarked or foreign row returned", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { vmRepositoryLiveShape: liveVmRepository } = await import("../services/vms/repository");
      const Effect = await import("effect/Effect");
      const key = `sandbox-run:${randomUUID()}:attempt:${randomUUID()}`;
      const begin = (input: { sandboxMarker?: string }) => Effect.runPromiseExit(liveVmRepository.beginCreate({
        userId, billingTeamId: userId, billingPlanId: "pro", provider: "freestyle", image: "sh-test-image",
        maxActiveVms: 5, idempotencyKey: key, ...input,
      }));
      // No marker: refused before anything is written.
      expect((await begin({}))._tag).toBe("Failure");
      // A row someone else wrote under the key without the marker is never handed back.
      await sql!`insert into cloud_vms (user_id, billing_team_id, owner_team_id, provider, image_id, status, idempotency_key, provider_vm_id)
        values (${userId}, ${userId}, ${userId}, 'freestyle', 'sh-test-image', 'running', ${key}, 'vm-foreign')`;
      expect((await begin({ sandboxMarker: key }))._tag).toBe("Failure");
    } finally {
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });

  dbTest("a sandbox key allocates one machine, ever: a destroyed or failed row is returned, never replaced", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const { vmRepositoryLiveShape: liveVmRepository } = await import("../services/vms/repository");
      const Effect = await import("effect/Effect");
      for (const status of ["destroyed", "failed"] as const) {
        const key = `sandbox-run:${randomUUID()}:attempt:${randomUUID()}`;
        await sql!`insert into cloud_vms (user_id, billing_team_id, owner_team_id, provider, image_id, status, idempotency_key, provider_vm_id, provider_metadata, updated_at)
          values (${userId}, ${userId}, ${userId}, 'freestyle', 'sh-test-image', ${status}, ${key}, ${`vm-${status}-${randomUUID()}`}, ${sql!.json({ cmuxSandboxRun: key })}, now() - interval '1 day')`;
        const result = await Effect.runPromise(liveVmRepository.beginCreate({
          userId, billingTeamId: userId, billingPlanId: "pro", provider: "freestyle", image: "sh-test-image",
          maxActiveVms: 5, idempotencyKey: key, sandboxMarker: key,
        }));
        expect(result).toMatchObject({ inserted: false, vm: { status, idempotencyKey: key } });
        const rows = await sql!`select status from cloud_vms where user_id = ${userId} and provider_metadata->>'cmuxSandboxRun' = ${key}`;
        expect(rows.map((row) => row.status)).toEqual([status]);
      }
    } finally {
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });

  dbTest("a VM row reconciled to destroyed is still adopted until a strict destroy confirms it gone", async () => {
    const userId = `sandbox-${randomUUID()}`;
    try {
      const created = await repo().createRun(input(userId));
      const attempt = created.attempts[0]!;
      await repo().claimAttemptLease({ runId: created.run.id, attemptId: attempt.id, workerId: "sandbox-worker" });
      // The launcher created the VM and died before journaling it; status reconciliation then
      // read an endpoint 404 as destroyed, which proves nothing.
      const vmId = `vm-reconciled-${randomUUID()}`;
      await insertSandboxVm(userId, `sandbox-run:${created.run.id}:attempt:${attempt.id}`, vmId);
      await sql!`update cloud_vms set status = 'destroyed', destroyed_at = now() where provider_vm_id = ${vmId}`;
      await repo().cancelRun(created.run.id, userId);
      await repo().forceFinalizeRunCancellation(created.run.id, userId);
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      const claims = await repo().claimExpiredAttemptCleanups({ runId: created.run.id });
      expect(claims.map((claim) => claim.attempt.providerVmId)).toEqual([vmId]);

      // The strict destroy confirmed it: the row says so, and nothing adopts it again.
      await repo().confirmSandboxVmDestroyed(vmId);
      await repo().finishAttemptCleanup({ attemptId: attempt.id, cleanupLeaseToken: claims[0]!.cleanupLeaseToken, succeeded: true });
      const [row] = await sql!`select provider_metadata from cloud_vms where provider_vm_id = ${vmId}`;
      expect(typeof row?.provider_metadata?.cmuxSandboxDestroyConfirmed).toBe("string");
      await sql!`delete from run_events where attempt_id = ${attempt.id} and external_id like 'cmux:sandbox-vm-adopted%'`;
      await repo().failAbandonedSandboxAttempts({ limit: 100 });
      expect(await repo().claimExpiredAttemptCleanups({ runId: created.run.id })).toEqual([]);
    } finally {
      await sql!`delete from cloud_vms where user_id = ${userId}`;
      await removeRuns(userId);
    }
  });
});
