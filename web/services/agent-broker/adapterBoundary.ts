import type { AgentBrokerJob } from "./repository";

/** Versioned boundary for adapters that may later live in a private repository. */
export const AGENT_BROKER_ADAPTER_PROTOCOL_VERSION = 1 as const;

/** Only safe, serialized job data crosses the adapter boundary. */
export type AgentBrokerAdapterInput = {
  readonly protocolVersion: typeof AGENT_BROKER_ADAPTER_PROTOCOL_VERSION;
  readonly jobId: string;
  readonly tenantId: string;
  readonly owner: string;
  readonly hostClass: string;
  readonly effectKey: string;
  readonly attempt: number;
  readonly leaseGeneration: number;
  readonly payload: Record<string, unknown>;
};

export type AgentBrokerAdapterResult = Record<string, unknown>;

export type AgentBrokerEffectAdapter = {
  /** Must match the durable job's hostClass exactly. */
  readonly hostClass: string;
  execute(input: AgentBrokerAdapterInput): Promise<AgentBrokerAdapterResult>;
};

export type AgentBrokerAdapterModule = {
  createAgentBrokerAdapters(input: {
    readonly env: Readonly<Record<string, string | undefined>>;
  }): Promise<readonly AgentBrokerEffectAdapter[]> | readonly AgentBrokerEffectAdapter[];
};

export function adapterInputFromJob(job: AgentBrokerJob): AgentBrokerAdapterInput {
  return {
    protocolVersion: AGENT_BROKER_ADAPTER_PROTOCOL_VERSION,
    jobId: job.id,
    tenantId: job.tenantId,
    owner: job.owner,
    hostClass: job.hostClass,
    effectKey: job.effectKey,
    attempt: job.attempt,
    leaseGeneration: job.leaseGeneration,
    payload: job.payload,
  };
}

export function assertAdapterResult(value: unknown): AgentBrokerAdapterResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("broker adapter must return a JSON object");
  }
  const result = JSON.parse(JSON.stringify(value)) as unknown;
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error("broker adapter returned a non-serializable result");
  }
  return result as AgentBrokerAdapterResult;
}

export function createAdapterRegistry(
  adapters: readonly AgentBrokerEffectAdapter[],
): ReadonlyMap<string, AgentBrokerEffectAdapter> {
  const registry = new Map<string, AgentBrokerEffectAdapter>();
  for (const adapter of adapters) {
    if (!/^[a-z][a-z0-9-]{1,63}$/.test(adapter.hostClass)) {
      throw new Error(`invalid broker adapter host class: ${adapter.hostClass}`);
    }
    if (registry.has(adapter.hostClass)) {
      throw new Error(`duplicate broker adapter host class: ${adapter.hostClass}`);
    }
    registry.set(adapter.hostClass, adapter);
  }
  return registry;
}
