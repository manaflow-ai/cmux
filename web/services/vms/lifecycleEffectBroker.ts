import {
  AGENT_BROKER_PROTOCOL_VERSION,
  requestDigest,
  type AgentBrokerEnvelope,
} from "../agent-broker/model";
import {
  AgentBrokerJobNotFoundError,
  claimJobById,
  completeJob,
  enqueueJob,
  failJob,
  getJob,
  type AgentBrokerJob,
} from "../agent-broker/repository";

/** A JSON object is the only result shape persisted in broker receipts. */
export type LifecycleEffectResult = Record<string, unknown>;

export type LifecycleEffectRequest = {
  readonly tenantId: string;
  readonly ownerId: string;
  readonly hostClass: string;
  /** Stable across retries and process restarts. */
  readonly effectKey: string;
  /** Safe, credential-free operation inputs for receipt replay/audit. */
  readonly payload: LifecycleEffectResult;
  readonly run: () => Promise<LifecycleEffectResult>;
};

export type LifecycleEffectReceipt = {
  readonly result: LifecycleEffectResult;
  readonly replayed: boolean;
  readonly jobId: string;
  readonly sequence: number;
};

export interface PersistentWorkspaceEffectBroker {
  execute(input: LifecycleEffectRequest): Promise<LifecycleEffectReceipt>;
}

export class LifecycleEffectBrokerError extends Error {
  constructor(
    public readonly code: "effect_in_progress" | "effect_failed" | "effect_invalid_result" | "effect_store_error",
    message: string,
    options?: { readonly cause?: unknown },
  ) {
    super(message, options);
    this.name = "LifecycleEffectBrokerError";
  }
}

export type AgentBrokerLifecycleEffectConfig = {
  readonly workerId: string;
  /** Stable source identity for this deployed lifecycle worker. */
  readonly sourceSha?: string;
  /** Caller authorization revision; stable for a retry of one effect. */
  readonly scopeRevision?: string | (() => string);
  readonly leaseTtlMs?: number;
  readonly now?: () => Date;
};

function safeText(value: string, label: string): string {
  const text = value.trim();
  if (!text || text.length > 256 || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new LifecycleEffectBrokerError("effect_store_error", `${label} must be a bounded printable string`);
  }
  return text;
}

function safeResult(value: unknown): LifecycleEffectResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new LifecycleEffectBrokerError("effect_invalid_result", "lifecycle effect returned a non-object result");
  }
  try {
    // Force a JSON round trip so a provider cannot smuggle an unsupported
    // value into a durable receipt. The stored object is intentionally plain.
    const parsed = JSON.parse(JSON.stringify(value)) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("result is not an object");
    return parsed as LifecycleEffectResult;
  } catch (cause) {
    throw new LifecycleEffectBrokerError("effect_invalid_result", "lifecycle effect returned an unserializable result", { cause });
  }
}

function replayReceipt(job: AgentBrokerJob): LifecycleEffectReceipt {
  return {
    result: safeResult(job.result ?? { ok: true }),
    replayed: true,
    jobId: job.id,
    sequence: job.receiptSequence,
  };
}

function failedJobError(job: AgentBrokerJob): LifecycleEffectBrokerError {
  return new LifecycleEffectBrokerError("effect_failed", job.error ?? "lifecycle effect failed");
}

/**
 * Runs lifecycle provider effects through the durable broker ledger. The
 * exact-job claim is important: a request that already has a job id must not
 * claim an unrelated queued effect merely because it has the same host class.
 */
export function createAgentBrokerLifecycleEffectBroker(
  config: AgentBrokerLifecycleEffectConfig,
): PersistentWorkspaceEffectBroker {
  const workerId = safeText(config.workerId, "workerId");
  const sourceSha = safeText(config.sourceSha ?? "cmux-runtime-lifecycle-v1", "sourceSha");
  const scopeRevision = () => safeText(
    typeof config.scopeRevision === "function" ? config.scopeRevision() : config.scopeRevision ?? "runtime-lifecycle",
    "scopeRevision",
  );
  const now = config.now ?? (() => new Date());

  return {
    async execute(input): Promise<LifecycleEffectReceipt> {
      const tenantId = safeText(input.tenantId, "tenantId");
      const ownerId = safeText(input.ownerId, "ownerId");
      const hostClass = safeText(input.hostClass, "hostClass");
      const effectKey = safeText(input.effectKey, "effectKey");
      const payload = safeResult(input.payload);
      const envelope: AgentBrokerEnvelope = {
        protocolVersion: AGENT_BROKER_PROTOCOL_VERSION,
        tenantId,
        effectKey,
        requestDigest: requestDigest(payload),
        owner: ownerId,
        sourceSha,
        scopeRevision: scopeRevision(),
        hostClass,
        payload,
      };

      let job: AgentBrokerJob;
      try {
        job = await enqueueJob(envelope, now());
      } catch (cause) {
        throw new LifecycleEffectBrokerError("effect_store_error", "lifecycle effect could not be enqueued", { cause });
      }
      if (job.status === "completed") return replayReceipt(job);
      if (job.status === "failed") throw failedJobError(job);

      const lease = await claimJobById({
        jobId: job.id,
        workerId,
        hostClass,
        ttlMs: config.leaseTtlMs,
        now: now(),
      });
      if (!lease) {
        const current = await getJob(job.id, tenantId).catch((cause) => {
          if (cause instanceof AgentBrokerJobNotFoundError) return null;
          throw cause;
        });
        if (current?.status === "completed") return replayReceipt(current);
        if (current?.status === "failed") throw failedJobError(current);
        throw new LifecycleEffectBrokerError("effect_in_progress", "lifecycle effect is already leased by another worker");
      }

      let result: LifecycleEffectResult;
      try {
        result = safeResult(await input.run());
      } catch (cause) {
        const error = cause instanceof Error ? cause.message.slice(0, 8_192) : String(cause).slice(0, 8_192);
        await failJob({
          jobId: lease.job.id,
          leaseToken: lease.leaseToken,
          leaseGeneration: lease.leaseGeneration,
          error,
          now: now(),
        }).catch(() => undefined);
        if (cause instanceof LifecycleEffectBrokerError) throw cause;
        throw new LifecycleEffectBrokerError("effect_failed", "lifecycle provider effect failed", { cause });
      }

      try {
        const completed = await completeJob({
          jobId: lease.job.id,
          leaseToken: lease.leaseToken,
          leaseGeneration: lease.leaseGeneration,
          result,
          now: now(),
        });
        return {
          result: safeResult(completed.result ?? result),
          replayed: false,
          jobId: completed.id,
          sequence: completed.receiptSequence,
        };
      } catch (cause) {
        throw new LifecycleEffectBrokerError("effect_store_error", "lifecycle effect receipt could not be committed", { cause });
      }
    },
  };
}
