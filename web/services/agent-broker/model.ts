import { createHash } from "node:crypto";

export const AGENT_BROKER_PROTOCOL_VERSION = 1 as const;
export const AGENT_BROKER_JOB_STATES = ["queued", "leased", "completed", "failed"] as const;
export type AgentBrokerJobState = (typeof AGENT_BROKER_JOB_STATES)[number];

export type AgentBrokerEnvelope = {
  readonly protocolVersion: typeof AGENT_BROKER_PROTOCOL_VERSION;
  /** Tenant/account boundary. It is part of the idempotency namespace. */
  readonly tenantId: string;
  /** Stable logical effect identifier. Retries must reuse this value. */
  readonly effectKey: string;
  /** Digest of the semantic request, including its payload. */
  readonly requestDigest: string;
  /** Logical owner of the work (session, run, or coordinator). */
  readonly owner: string;
  /** Source revision used to decide whether a receipt is still applicable. */
  readonly sourceSha: string;
  /** Monotonic caller scope revision, kept opaque to this transport layer. */
  readonly scopeRevision: string;
  /** Opaque host class selected by the caller (for example, huge-blue). */
  readonly hostClass: string;
  readonly payload: Record<string, unknown>;
};

export type AgentBrokerReceipt = {
  readonly jobId: string;
  readonly sequence: number;
  readonly state: AgentBrokerJobState;
  readonly attempt: number;
  readonly leaseGeneration: number;
  readonly owner: string;
  readonly hostClass: string;
  readonly effectKey: string;
  readonly result: Record<string, unknown> | null;
  readonly error: string | null;
  readonly createdAt: Date;
};

const NON_EMPTY = /\S/;
const IDENTIFIER = /^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,255}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/i;

export class AgentBrokerInputError extends Error {
  override name = "AgentBrokerInputError";
}

function assertIdentifier(name: string, value: string): void {
  if (!IDENTIFIER.test(value) || !NON_EMPTY.test(value)) {
    throw new AgentBrokerInputError(`${name} must be a non-empty bounded identifier`);
  }
}

export function assertAgentBrokerEnvelope(value: AgentBrokerEnvelope): void {
  if (value.protocolVersion !== AGENT_BROKER_PROTOCOL_VERSION) {
    throw new AgentBrokerInputError("unsupported agent broker protocol version");
  }
  assertIdentifier("tenantId", value.tenantId);
  assertIdentifier("effectKey", value.effectKey);
  assertIdentifier("owner", value.owner);
  assertIdentifier("sourceSha", value.sourceSha);
  assertIdentifier("scopeRevision", value.scopeRevision);
  assertIdentifier("hostClass", value.hostClass);
  if (!DIGEST.test(value.requestDigest)) {
    throw new AgentBrokerInputError("requestDigest must be a sha256 digest");
  }
  if (!value.payload || typeof value.payload !== "object" || Array.isArray(value.payload)) {
    throw new AgentBrokerInputError("payload must be a JSON object");
  }
  if (JSON.stringify(value.payload).length > 512_000) {
    throw new AgentBrokerInputError("payload is too large");
  }
}

export function requestDigest(value: unknown): string {
  return `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`;
}

export function assertLeaseTtl(ttlMs: number | undefined, defaultMs: number): number {
  const value = ttlMs ?? defaultMs;
  if (!Number.isSafeInteger(value) || value < 5_000 || value > 15 * 60_000) {
    throw new AgentBrokerInputError("lease ttl must be between 5000ms and 900000ms");
  }
  return value;
}
