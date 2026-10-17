import {
  claimJob,
  completeJob,
  failJob,
  renewJobLease,
  type AgentBrokerJob,
  type AgentBrokerLease,
} from "./repository";
import {
  adapterInputFromJob,
  assertAdapterResult,
  createAdapterRegistry,
  type AgentBrokerAdapterResult,
  type AgentBrokerEffectAdapter,
} from "./adapterBoundary";

export type AgentBrokerWorkerRepository = {
  claim(input: { readonly workerId: string; readonly hostClass?: string; readonly ttlMs?: number; readonly now?: Date }): Promise<AgentBrokerLease | null>;
  renew(input: { readonly jobId: string; readonly leaseToken: string; readonly leaseGeneration: number; readonly ttlMs?: number; readonly now?: Date }): Promise<AgentBrokerLease>;
  complete(input: { readonly jobId: string; readonly leaseToken: string; readonly leaseGeneration: number; readonly result: Record<string, unknown>; readonly now?: Date }): Promise<AgentBrokerJob>;
  fail(input: { readonly jobId: string; readonly leaseToken: string; readonly leaseGeneration: number; readonly error: string; readonly now?: Date }): Promise<AgentBrokerJob>;
};

export function cloudAgentBrokerWorkerRepository(): AgentBrokerWorkerRepository {
  return { claim: claimJob, renew: renewJobLease, complete: completeJob, fail: failJob };
}

export type AgentBrokerWorkerResult =
  | { readonly status: "idle" }
  | { readonly status: "completed"; readonly jobId: string; readonly replayed: boolean }
  | { readonly status: "failed"; readonly jobId: string; readonly error: string };

export type AgentBrokerWorkerConfig = {
  readonly workerId: string;
  readonly adapters: readonly AgentBrokerEffectAdapter[];
  readonly hostClass?: string;
  readonly leaseTtlMs?: number;
  readonly repository?: AgentBrokerWorkerRepository;
  readonly now?: () => Date;
  readonly sleep?: (milliseconds: number) => Promise<void>;
};

function errorText(cause: unknown): string {
  return (cause instanceof Error ? cause.message : String(cause)).slice(0, 8_192);
}

function defaultSleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Runs serialized broker effects in a separate process. Provider credentials
 * and SDK objects stay inside adapters; the worker only sees the durable job
 * envelope and writes a fenced receipt back to PlanetScale.
 */
export function createAgentBrokerWorker(config: AgentBrokerWorkerConfig) {
  const repository = config.repository ?? cloudAgentBrokerWorkerRepository();
  const registry = createAdapterRegistry(config.adapters);
  const now = config.now ?? (() => new Date());
  const sleep = config.sleep ?? defaultSleep;
  const pollMs = 1_000;

  async function runOnce(): Promise<AgentBrokerWorkerResult> {
    const lease = await repository.claim({
      workerId: config.workerId,
      hostClass: config.hostClass,
      ttlMs: config.leaseTtlMs,
      now: now(),
    });
    if (!lease) return { status: "idle" };

    const adapter = registry.get(lease.job.hostClass);
    if (!adapter) {
      const error = `no broker adapter configured for ${lease.job.hostClass}`;
      await repository.fail({
        jobId: lease.job.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        error,
        now: now(),
      });
      return { status: "failed", jobId: lease.job.id, error };
    }

    let renewTimer: ReturnType<typeof setInterval> | undefined;
    try {
      const renewEveryMs = Math.max(1_000, Math.floor((config.leaseTtlMs ?? 30_000) / 3));
      renewTimer = setInterval(() => {
        void repository.renew({
          jobId: lease.job.id,
          leaseToken: lease.leaseToken,
          leaseGeneration: lease.leaseGeneration,
          ttlMs: config.leaseTtlMs,
          now: now(),
        }).catch(() => undefined);
      }, renewEveryMs);
      let result: AgentBrokerAdapterResult;
      try {
        result = assertAdapterResult(await adapter.execute(adapterInputFromJob(lease.job)));
      } catch (cause) {
        const error = errorText(cause);
        await repository.fail({
          jobId: lease.job.id,
          leaseToken: lease.leaseToken,
          leaseGeneration: lease.leaseGeneration,
          error,
          now: now(),
        }).catch(() => undefined);
        return { status: "failed", jobId: lease.job.id, error };
      }
      const completed = await repository.complete({
        jobId: lease.job.id,
        leaseToken: lease.leaseToken,
        leaseGeneration: lease.leaseGeneration,
        result,
        now: now(),
      });
      return { status: "completed", jobId: completed.id, replayed: false };
    } catch (cause) {
      const error = errorText(cause);
      return { status: "failed", jobId: lease.job.id, error };
    } finally {
      if (renewTimer) clearInterval(renewTimer);
    }
  }

  async function run(input: { readonly signal?: AbortSignal; readonly pollMs?: number } = {}): Promise<void> {
    while (!input.signal?.aborted) {
      const result = await runOnce();
      if (result.status === "idle") await sleep(input.pollMs ?? pollMs);
    }
  }

  return { runOnce, run };
}
