import {
  getJob,
  listJobReceipts,
  type AgentBrokerJob,
  type AgentBrokerReceiptPage,
} from "../agent-broker/repository";
import type { AgentBrokerReceipt } from "../agent-broker/model";
import { ingestRunEvent } from "./repository";
import type { RunEventKind } from "./model";

const FORBIDDEN_KEY = /(?:token|secret|password|authorization|credential|cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|provider(?:lease|vm|workspace|terminal)id|leaseid)/i;
const FORBIDDEN_VALUE = /(?:\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+\b|\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}\b|(?:token|secret|password|authorization|credential|api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]\s*[^\s,;]+)/i;
const MAX_RESULT_DEPTH = 6;
const MAX_RESULT_STRING = 8_192;

export type BrokerReceiptProjectionInput = {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly tenantId: string;
  readonly owner: string;
  readonly hostClass: string;
  readonly effectKey: string;
  readonly sourceSha: string;
  readonly scopeRevision: string;
  readonly jobId: string;
  readonly afterSequence?: number;
  readonly limit?: number;
};

export class BrokerReceiptProjectionError extends Error {
  constructor(
    public readonly code: "correlation_mismatch" | "sequence_conflict" | "unsafe_receipt",
    message: string,
  ) {
    super(message);
    this.name = "BrokerReceiptProjectionError";
  }
}

type ProjectionDependencies = {
  readonly getJob: (jobId: string, tenantId?: string) => Promise<AgentBrokerJob>;
  readonly listJobReceipts: (input: {
    readonly jobId: string;
    readonly tenantId?: string;
    readonly afterSequence?: number;
    readonly limit?: number;
  }) => Promise<AgentBrokerReceiptPage>;
  readonly ingestRunEvent: typeof ingestRunEvent;
};

const defaultDependencies: ProjectionDependencies = { getJob, listJobReceipts, ingestRunEvent };

function requireSafeText(value: string, label: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 256 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new BrokerReceiptProjectionError("correlation_mismatch", `${label} is invalid`);
  }
  return value;
}

function requireSafeReceiptText(value: string | null, label: string, maxLength = MAX_RESULT_STRING): string | null {
  if (value === null) return null;
  if (typeof value !== "string" || value.length > maxLength || /[\u0000-\u001f\u007f]/.test(value) || FORBIDDEN_VALUE.test(value)) {
    throw new BrokerReceiptProjectionError("unsafe_receipt", `broker receipt ${label} is unsafe`);
  }
  return value;
}

function assertCorrelation(job: AgentBrokerJob, input: BrokerReceiptProjectionInput): void {
  const pairs: readonly [string, string, string][] = [
    ["job id", job.id, input.jobId],
    ["tenant", job.tenantId, input.tenantId],
    ["owner", job.owner, input.owner],
    ["host class", job.hostClass, input.hostClass],
    ["effect key", job.effectKey, input.effectKey],
    ["source revision", job.sourceSha, input.sourceSha],
    ["scope revision", job.scopeRevision, input.scopeRevision],
  ];
  for (const [label, actual, expected] of pairs) {
    if (actual !== expected) throw new BrokerReceiptProjectionError("correlation_mismatch", `broker ${label} does not match the run projection`);
  }
}

function optionalReceiptField(receipt: AgentBrokerReceipt, field: string): unknown {
  return (receipt as unknown as Record<string, unknown>)[field];
}

function safeValue(value: unknown, depth = 0): unknown {
  if (depth > MAX_RESULT_DEPTH) throw new BrokerReceiptProjectionError("unsafe_receipt", "broker receipt result is too deeply nested");
  if (value === null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") {
    if (value.length > MAX_RESULT_STRING || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value)) {
      throw new BrokerReceiptProjectionError("unsafe_receipt", "broker receipt result contains an unsafe string");
    }
    return value;
  }
  if (Array.isArray(value)) return value.map((entry) => safeValue(entry, depth + 1));
  if (!value || typeof value !== "object") throw new BrokerReceiptProjectionError("unsafe_receipt", "broker receipt result is not JSON data");
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => {
    if (FORBIDDEN_KEY.test(key)) throw new BrokerReceiptProjectionError("unsafe_receipt", `broker receipt contains forbidden field ${key}`);
    return [key, safeValue(entry, depth + 1)];
  }));
}

function safeResult(value: Record<string, unknown> | null): Record<string, unknown> | null {
  if (value === null) return null;
  const result = safeValue(value);
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new BrokerReceiptProjectionError("unsafe_receipt", "broker receipt result is not an object");
  }
  return result as Record<string, unknown>;
}

function eventKind(state: AgentBrokerReceipt["state"]): RunEventKind {
  return state === "queued" ? "attempt.queued" : "attempt.heartbeat";
}

function eventPayload(receipt: AgentBrokerReceipt): Record<string, unknown> {
  return {
    brokerReceipt: {
      jobId: receipt.jobId,
      sequence: receipt.sequence,
      state: receipt.state,
      attempt: receipt.attempt,
      leaseGeneration: receipt.leaseGeneration,
      hostClass: receipt.hostClass,
      effectKey: requireSafeReceiptText(receipt.effectKey, "effectKey", 256),
      result: safeResult(receipt.result),
      error: requireSafeReceiptText(receipt.error, "error"),
    },
  };
}

function validateProjectionInput(input: BrokerReceiptProjectionInput): void {
  for (const [value, label] of [[input.runId, "runId"], [input.attemptId, "attemptId"], [input.leaseToken, "leaseToken"], [input.tenantId, "tenantId"], [input.owner, "owner"], [input.hostClass, "hostClass"], [input.effectKey, "effectKey"], [input.sourceSha, "sourceSha"], [input.scopeRevision, "scopeRevision"], [input.jobId, "jobId"]] as const) requireSafeText(value, label);
  if (!Number.isSafeInteger(input.leaseGeneration) || input.leaseGeneration < 0) throw new BrokerReceiptProjectionError("correlation_mismatch", "leaseGeneration is invalid");
  if (input.afterSequence !== undefined && (!Number.isSafeInteger(input.afterSequence) || input.afterSequence < 0)) throw new BrokerReceiptProjectionError("sequence_conflict", "afterSequence is invalid");
}

function validateReceipt(receipt: AgentBrokerReceipt, input: BrokerReceiptProjectionInput, job: AgentBrokerJob, previous: number, previousLeaseGeneration: number): void {
  if (receipt.jobId !== input.jobId || receipt.owner !== input.owner || receipt.hostClass !== input.hostClass || receipt.effectKey !== input.effectKey) {
    throw new BrokerReceiptProjectionError("correlation_mismatch", "broker receipt correlation does not match the run projection");
  }
  if (!Number.isSafeInteger(receipt.sequence) || receipt.sequence <= previous) throw new BrokerReceiptProjectionError("sequence_conflict", "broker receipt sequence is stale or reordered");
  if (!Number.isSafeInteger(receipt.leaseGeneration) || receipt.leaseGeneration < previousLeaseGeneration || receipt.leaseGeneration > job.leaseGeneration) {
    throw new BrokerReceiptProjectionError("sequence_conflict", "broker receipt lease generation is stale or from the future");
  }
  for (const [field, expected] of [["tenantId", input.tenantId], ["sourceSha", input.sourceSha], ["scopeRevision", input.scopeRevision]] as const) {
    const actual = optionalReceiptField(receipt, field);
    if (actual !== undefined && actual !== expected) throw new BrokerReceiptProjectionError("correlation_mismatch", `broker receipt ${field} does not match the run projection`);
  }
}

/** Project a validated broker journal page into replay-safe, non-terminal Run events. */
export async function projectBrokerReceipts(
  input: BrokerReceiptProjectionInput,
  dependencies: ProjectionDependencies = defaultDependencies,
): Promise<{ readonly events: readonly Awaited<ReturnType<typeof ingestRunEvent>>[]; readonly nextSequence: number | null }> {
  validateProjectionInput(input);

  const job = await dependencies.getJob(input.jobId, input.tenantId);
  assertCorrelation(job, input);
  const page = await dependencies.listJobReceipts({ jobId: input.jobId, tenantId: input.tenantId, afterSequence: input.afterSequence, limit: input.limit });
  let previous = input.afterSequence ?? 0;
  let previousLeaseGeneration = 0;
  const events: Awaited<ReturnType<typeof ingestRunEvent>>[] = [];
  for (const receipt of page.receipts) {
    validateReceipt(receipt, input, job, previous, previousLeaseGeneration);
    previous = receipt.sequence;
    previousLeaseGeneration = receipt.leaseGeneration;
    const event = await dependencies.ingestRunEvent({
      runId: input.runId,
      attemptId: input.attemptId,
      leaseToken: input.leaseToken,
      leaseGeneration: input.leaseGeneration,
      externalId: `broker:${input.jobId}:${receipt.sequence}`,
      kind: eventKind(receipt.state),
      payload: eventPayload(receipt),
    });
    events.push(event);
  }
  return { events, nextSequence: page.nextSequence };
}
