import { describe, expect, test } from "bun:test";

/**
 * Contract-only fakes for the remote broker and VM lease adapters.
 *
 * These tests intentionally do not import an implementation from cmuxterm-hq:
 * the broker is a separate service and the host transport is provider-neutral.
 * Once those modules are available, their clients can run the same cases by
 * replacing this fake with the two interfaces below.
 */

type HostClass = "huge-blue" | "freestyle-vm";
type JobState = "queued" | "leased" | "completed" | "failed";

type HostIdentity = {
  hostId: string;
  hostClass: HostClass;
};

type JobEnvelope = {
  tenantId: string;
  effectKey: string;
  requestDigest: string;
  ownerId: string;
  hostClass: HostClass;
  sourceSha: string;
  scopeRevision: string;
  payload: Record<string, unknown>;
};

type LeaseToken = {
  leaseId: string;
  ownerId: string;
  hostClass: HostClass;
  generation: number;
  expiresAtMs: number;
};

type BrokerReceipt = {
  sequence: number;
  jobId: string;
  state: JobState;
  attempt: number;
  leaseGeneration: number;
  ownerId: string;
  hostClass: HostClass;
  effectKey: string;
  atMs: number;
  errorCode?: string;
};

type StoredJob = {
  jobId: string;
  envelope: JobEnvelope;
  state: JobState;
  attempt: number;
  generation: number;
  lease?: LeaseToken;
  result?: unknown;
  receipts: BrokerReceipt[];
};

type BrokerSnapshot = {
  nextJob: number;
  nextSequence: number;
  jobs: StoredJob[];
  effectToJob: [string, string][];
  appliedEffects: [string, { requestDigest: string; result: unknown }][];
};

class LeaseFenceError extends Error {
  readonly code = "lease_fenced";
}

class DuplicateEffectError extends Error {
  readonly code = "effect_conflict";
}

/** Expected integration surface for the remote broker implementation. */
interface AgentBroker {
  enqueueJob(envelope: JobEnvelope, nowMs: number): { jobId: string; replayed: boolean };
  claimJob(jobId: string, owner: HostIdentity, nowMs: number, leaseTtlMs: number): LeaseToken;
  renewJobLease(jobId: string, token: LeaseToken, nowMs: number, leaseTtlMs: number): LeaseToken;
  completeJob(jobId: string, token: LeaseToken, result: unknown, nowMs: number): BrokerReceipt;
  failJob(jobId: string, token: LeaseToken, errorCode: string, nowMs: number): BrokerReceipt;
  applyEffect(effectKey: string, requestDigest: string, operation: () => unknown): { replayed: boolean; result: unknown };
  listJobReceipts(jobId: string): BrokerReceipt[];
  snapshot(): BrokerSnapshot;
}

/** Expected integration surface for Huge Blue/Freestyle VM lease adapters. */
interface HostLeaseTransport {
  acquire(request: {
    leaseId: string;
    hostId: string;
    ownerId: string;
    generation: number;
    ttlMs: number;
    nowMs: number;
    idempotencyKey: string;
  }): { provider: HostClass; leaseId: string; hostId: string; ownerId: string; generation: number; expiresAtMs: number };
  renew(request: {
    leaseId: string;
    hostId: string;
    ownerId: string;
    generation: number;
    ttlMs: number;
    nowMs: number;
    idempotencyKey: string;
  }): { provider: HostClass; leaseId: string; hostId: string; ownerId: string; generation: number; expiresAtMs: number };
  release(request: { leaseId: string; hostId: string; ownerId: string; generation: number; nowMs: number }): void;
}

class FakeBroker implements AgentBroker {
  private nextJob = 1;
  private nextSequence = 1;
  private readonly jobsById = new Map<string, StoredJob>();
  private readonly effectToJob = new Map<string, string>();
  private readonly appliedEffects = new Map<string, { requestDigest: string; result: unknown }>();

  enqueueJob(envelope: JobEnvelope, nowMs: number) {
    const existingId = this.effectToJob.get(envelope.effectKey);
    if (existingId) {
      const existing = this.jobsById.get(existingId)!;
      if (existing.envelope.requestDigest !== envelope.requestDigest) {
        throw new DuplicateEffectError(`effect_key ${envelope.effectKey} has a different request digest`);
      }
      return { jobId: existingId, replayed: true };
    }

    const jobId = `job-${this.nextJob++}`;
    const job: StoredJob = {
      jobId,
      envelope,
      state: "queued",
      attempt: 0,
      generation: 0,
      receipts: [],
    };
    this.jobsById.set(jobId, job);
    this.effectToJob.set(envelope.effectKey, jobId);
    this.appendReceipt(job, "queued", envelope.ownerId, envelope.hostClass, nowMs);
    return { jobId, replayed: false };
  }

  claimJob(jobId: string, owner: HostIdentity, nowMs: number, leaseTtlMs: number): LeaseToken {
    const job = this.requireJob(jobId);
    const active = job.lease;
    if (active && active.expiresAtMs > nowMs) {
      if (active.ownerId === owner.hostId && active.hostClass === owner.hostClass) return { ...active };
      throw new LeaseFenceError(`job ${jobId} is owned by ${active.ownerId}`);
    }

    if (active && active.expiresAtMs <= nowMs) {
      job.state = "failed";
      this.appendReceipt(job, "failed", active.ownerId, active.hostClass, nowMs, "lease_expired");
    }

    job.attempt += 1;
    job.generation += 1;
    const token: LeaseToken = {
      leaseId: jobId,
      ownerId: owner.hostId,
      hostClass: owner.hostClass,
      generation: job.generation,
      expiresAtMs: nowMs + leaseTtlMs,
    };
    job.lease = token;
    job.state = "leased";
    this.appendReceipt(job, "leased", owner.hostId, owner.hostClass, nowMs);
    return { ...token };
  }

  renewJobLease(jobId: string, token: LeaseToken, nowMs: number, leaseTtlMs: number): LeaseToken {
    const job = this.requireJob(jobId);
    this.assertLease(job, token, nowMs);
    const renewed = { ...token, expiresAtMs: nowMs + leaseTtlMs };
    job.lease = renewed;
    return renewed;
  }

  completeJob(jobId: string, token: LeaseToken, result: unknown, nowMs: number): BrokerReceipt {
    const job = this.requireJob(jobId);
    this.assertLease(job, token, nowMs);
    job.state = "completed";
    job.result = result;
    const receipt = this.appendReceipt(job, "completed", token.ownerId, token.hostClass, nowMs);
    job.lease = undefined;
    return receipt;
  }

  failJob(jobId: string, token: LeaseToken, errorCode: string, nowMs: number): BrokerReceipt {
    const job = this.requireJob(jobId);
    this.assertLease(job, token, nowMs);
    job.state = "failed";
    const receipt = this.appendReceipt(job, "failed", token.ownerId, token.hostClass, nowMs, errorCode);
    job.lease = undefined;
    return receipt;
  }

  applyEffect(effectKey: string, requestDigest: string, operation: () => unknown) {
    const previous = this.appliedEffects.get(effectKey);
    if (previous) {
      if (previous.requestDigest !== requestDigest) throw new DuplicateEffectError(`effect_key ${effectKey} has a different request digest`);
      return { replayed: true, result: previous.result };
    }
    const result = operation();
    this.appliedEffects.set(effectKey, { requestDigest, result });
    return { replayed: false, result };
  }

  listJobReceipts(jobId: string) {
    return this.requireJob(jobId).receipts.map((receipt) => ({ ...receipt }));
  }

  snapshot(): BrokerSnapshot {
    return {
      nextJob: this.nextJob,
      nextSequence: this.nextSequence,
      jobs: [...this.jobsById.values()].map((job) => ({ ...job, envelope: { ...job.envelope }, lease: job.lease && { ...job.lease }, receipts: job.receipts.map((receipt) => ({ ...receipt })) })),
      effectToJob: [...this.effectToJob.entries()],
      appliedEffects: [...this.appliedEffects.entries()],
    };
  }

  static restore(snapshot: BrokerSnapshot) {
    const broker = new FakeBroker();
    broker.nextJob = snapshot.nextJob;
    broker.nextSequence = snapshot.nextSequence;
    for (const job of snapshot.jobs) broker.jobsById.set(job.jobId, { ...job, envelope: { ...job.envelope }, lease: job.lease && { ...job.lease }, receipts: job.receipts.map((receipt) => ({ ...receipt })) });
    for (const entry of snapshot.effectToJob) broker.effectToJob.set(...entry);
    for (const entry of snapshot.appliedEffects) broker.appliedEffects.set(...entry);
    return broker;
  }

  private requireJob(jobId: string) {
    const job = this.jobsById.get(jobId);
    if (!job) throw new Error(`unknown job ${jobId}`);
    return job;
  }

  private assertLease(job: StoredJob, token: LeaseToken, nowMs: number) {
    const active = job.lease;
    if (!active || active.ownerId !== token.ownerId || active.hostClass !== token.hostClass || active.generation !== token.generation || active.expiresAtMs <= nowMs) {
      throw new LeaseFenceError(`stale lease for ${job.jobId}`);
    }
  }

  private appendReceipt(job: StoredJob, state: JobState, ownerId: string, hostClass: HostClass, atMs: number, errorCode?: string) {
    const receipt: BrokerReceipt = {
      sequence: this.nextSequence++,
      jobId: job.jobId,
      state,
      attempt: job.attempt,
      leaseGeneration: job.generation,
      ownerId,
      hostClass,
      effectKey: job.envelope.effectKey,
      atMs,
      ...(errorCode ? { errorCode } : {}),
    };
    job.receipts.push(receipt);
    return receipt;
  }
}

class FakeHostLeaseTransport implements HostLeaseTransport {
  constructor(private readonly broker: FakeBroker, private readonly host: HostIdentity) {}

  acquire(request: Parameters<HostLeaseTransport["acquire"]>[0]) {
    if (request.hostId !== this.host.hostId) throw new LeaseFenceError("host identity mismatch");
    const token = this.broker.claimJob(request.leaseId, this.host, request.nowMs, request.ttlMs);
    return { provider: this.host.hostClass, leaseId: token.leaseId, hostId: this.host.hostId, ownerId: token.ownerId, generation: token.generation, expiresAtMs: token.expiresAtMs };
  }

  renew(request: Parameters<HostLeaseTransport["renew"]>[0]) {
    if (request.hostId !== this.host.hostId) throw new LeaseFenceError("host identity mismatch");
    const token: LeaseToken = { leaseId: request.leaseId, ownerId: request.ownerId, hostClass: this.host.hostClass, generation: request.generation, expiresAtMs: request.nowMs };
    const renewed = this.broker.renewJobLease(request.leaseId, token, request.nowMs, request.ttlMs);
    return { provider: this.host.hostClass, leaseId: renewed.leaseId, hostId: this.host.hostId, ownerId: renewed.ownerId, generation: renewed.generation, expiresAtMs: renewed.expiresAtMs };
  }

  release(request: Parameters<HostLeaseTransport["release"]>[0]) {
    if (request.hostId !== this.host.hostId) throw new LeaseFenceError("host identity mismatch");
    // Release is modelled as an immediate failure with a provider-neutral code.
    const token: LeaseToken = { leaseId: request.leaseId, ownerId: request.ownerId, hostClass: this.host.hostClass, generation: request.generation, expiresAtMs: request.nowMs + 1 };
    this.broker.failJob(request.leaseId, token, "released", request.nowMs);
  }
}

const envelope = (effectKey: string, hostClass: HostClass = "huge-blue"): JobEnvelope => ({
  tenantId: "test-tenant",
  effectKey,
  requestDigest: `digest:${effectKey}`,
  ownerId: "agent-coordinator",
  hostClass,
  sourceSha: "abc123",
  scopeRevision: "scope-1",
  payload: { action: "run-turn", prompt: "hello" },
});

describe("cross-host remote broker and VM lease contract", () => {
  test("deduplicates duplicate effect delivery across Huge Blue and Freestyle", () => {
    const broker = new FakeBroker();
    const hugeBlue: HostIdentity = { hostId: "huge-blue-01", hostClass: "huge-blue" };
    const freestyle: HostIdentity = { hostId: "freestyle-vm-01", hostClass: "freestyle-vm" };
    const first = broker.enqueueJob(envelope("effect-1"), 0);
    const duplicate = broker.enqueueJob(envelope("effect-1", "freestyle-vm"), 1);
    expect(duplicate).toEqual({ jobId: first.jobId, replayed: true });
    expect(() => broker.enqueueJob({ ...envelope("effect-1", "freestyle-vm"), requestDigest: "different" }, 1)).toThrow(DuplicateEffectError);

    const hugeLease = broker.claimJob(first.jobId, hugeBlue, 2, 100);
    const firstEffect = broker.applyEffect("effect-1", "digest:effect-1", () => ({ host: hugeBlue.hostId, output: "ok" }));
    broker.completeJob(first.jobId, hugeLease, firstEffect.result, 3);
    const replay = broker.applyEffect("effect-1", "digest:effect-1", () => ({ host: freestyle.hostId, output: "would-run-twice" }));

    expect(firstEffect.replayed).toBe(false);
    expect(replay).toEqual({ replayed: true, result: { host: hugeBlue.hostId, output: "ok" } });
    expect(() => broker.applyEffect("effect-1", "different", () => ({ duplicate: true }))).toThrow(DuplicateEffectError);
    expect(broker.listJobReceipts(first.jobId).map((receipt) => receipt.state)).toEqual(["queued", "leased", "completed"]);
  });

  test("retries after lease expiry and fences stale Huge Blue owner", () => {
    const broker = new FakeBroker();
    const hugeBlue: HostIdentity = { hostId: "huge-blue-01", hostClass: "huge-blue" };
    const freestyle: HostIdentity = { hostId: "freestyle-vm-01", hostClass: "freestyle-vm" };
    const { jobId } = broker.enqueueJob(envelope("effect-expiry"), 0);
    const hugeLease = broker.claimJob(jobId, hugeBlue, 10, 50);
    const freestyleTransport = new FakeHostLeaseTransport(broker, freestyle);
    const freestyleLease = freestyleTransport.acquire({ leaseId: jobId, hostId: freestyle.hostId, ownerId: freestyle.hostId, generation: 0, ttlMs: 50, nowMs: 61, idempotencyKey: "claim-2" });

    expect(freestyleLease.generation).toBe(2);
    expect(() => broker.completeJob(jobId, hugeLease, { stale: true }, 62)).toThrow(LeaseFenceError);
    const completed = broker.completeJob(jobId, { ...freestyleLease, hostClass: freestyle.hostClass }, { host: freestyle.hostId }, 63);
    expect(completed.state).toBe("completed");
    expect(broker.listJobReceipts(jobId).map((receipt) => receipt.errorCode)).toContain("lease_expired");
  });

  test("rejects a wrong owner and stale generation through the VM transport", () => {
    const broker = new FakeBroker();
    const hugeBlue: HostIdentity = { hostId: "huge-blue-01", hostClass: "huge-blue" };
    const freestyle: HostIdentity = { hostId: "freestyle-vm-01", hostClass: "freestyle-vm" };
    const { jobId } = broker.enqueueJob(envelope("effect-fence"), 0);
    const hugeTransport = new FakeHostLeaseTransport(broker, hugeBlue);
    const hugeLease = hugeTransport.acquire({ leaseId: jobId, hostId: hugeBlue.hostId, ownerId: hugeBlue.hostId, generation: 0, ttlMs: 100, nowMs: 1, idempotencyKey: "claim" });
    const freestyleTransport = new FakeHostLeaseTransport(broker, freestyle);

    expect(() => freestyleTransport.renew({ leaseId: jobId, hostId: freestyle.hostId, ownerId: freestyle.hostId, generation: hugeLease.generation, ttlMs: 100, nowMs: 2, idempotencyKey: "wrong-owner" })).toThrow(LeaseFenceError);
    expect(() => hugeTransport.renew({ leaseId: jobId, hostId: hugeBlue.hostId, ownerId: hugeBlue.hostId, generation: hugeLease.generation - 1, ttlMs: 100, nowMs: 2, idempotencyKey: "stale-generation" })).toThrow(LeaseFenceError);
  });

  test("preserves receipt ordering across expiry, reassignment, completion, and restart", () => {
    let broker = new FakeBroker();
    const hugeBlue: HostIdentity = { hostId: "huge-blue-01", hostClass: "huge-blue" };
    const freestyle: HostIdentity = { hostId: "freestyle-vm-01", hostClass: "freestyle-vm" };
    const { jobId } = broker.enqueueJob(envelope("effect-order"), 0);
    broker.claimJob(jobId, hugeBlue, 10, 10);
    broker.claimJob(jobId, freestyle, 21, 10);
    broker = FakeBroker.restore(broker.snapshot());
    const latest = broker.claimJob(jobId, freestyle, 22, 10);
    broker.completeJob(jobId, { ...latest, hostClass: freestyle.hostClass }, { ok: true }, 23);

    const receipts = broker.listJobReceipts(jobId);
    expect(receipts.map((receipt) => receipt.sequence)).toEqual([1, 2, 3, 4, 5]);
    expect(receipts.map((receipt) => receipt.state)).toEqual(["queued", "leased", "failed", "leased", "completed"]);
    expect(receipts[2]?.errorCode).toBe("lease_expired");
    expect(receipts[3]?.hostClass).toBe("freestyle-vm");
  });
});
