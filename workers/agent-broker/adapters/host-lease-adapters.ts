import { createSshHostLeaseClient } from "../../../web/services/vms/sshHostLeaseClient";
import type {
  AgentBrokerAdapterInput,
  AgentBrokerAdapterResult,
  AgentBrokerEffectAdapter,
} from "../../../web/services/agent-broker/adapterBoundary";
import {
  createFreestyleHostLeaseHttpClient,
  createHugeBlueHostLeaseHttpClient,
  type VmHostLeaseOperation,
  type VmHostLeaseProviderClient,
} from "../../../web/services/vms/hostLeaseTransport";

type Env = Readonly<Record<string, string | undefined>>;
type Fetcher = typeof fetch;
type Provider = "huge-blue" | "freestyle";

const PROVIDERS: readonly Provider[] = ["huge-blue", "freestyle"];
const OPERATIONS: readonly VmHostLeaseOperation[] = ["acquire", "renew", "release"];

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 256 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new Error(`${name} must be a bounded non-empty string`);
  }
  return value;
}

function positiveInteger(value: unknown, name: string, fallback?: number): number {
  const candidate = value ?? fallback;
  if (!Number.isSafeInteger(candidate) || (candidate as number) < 1) throw new Error(`${name} must be a positive integer`);
  return candidate as number;
}

function providerPrefix(provider: Provider): "HUGE_BLUE" | "FREESTYLE" {
  return provider === "huge-blue" ? "HUGE_BLUE" : "FREESTYLE";
}

function configuredClient(provider: Provider, env: Env, fetcher: Fetcher): VmHostLeaseProviderClient | null {
  const prefix = providerPrefix(provider);
  const baseUrl = env[`${prefix}_HOST_LEASE_URL`]?.trim();
  const token = (env[`${prefix}_HOST_LEASE_TOKEN`]?.trim() || env[`${prefix}_API_TOKEN`]?.trim() || env[`${prefix}_API_KEY`]?.trim());
  if (baseUrl && token) {
    const config = { baseUrl, token: () => token, fetch: fetcher } as const;
    return provider === "huge-blue"
      ? createHugeBlueHostLeaseHttpClient(config)
      : createFreestyleHostLeaseHttpClient(config);
  }
  const sshHost = env[`${prefix}_SSH_HOST`]?.trim();
  return sshHost ? createSshHostLeaseClient(sshHost, {
    user: env[`${prefix}_SSH_USER`]?.trim(),
    identityFile: env[`${prefix}_SSH_KEY`]?.trim(),
    proxyCommand: env[`${prefix}_SSH_PROXY_COMMAND`]?.trim(),
  }) : null;
}

function safeMetadata(value: unknown, depth = 0): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  if (depth > 4) return { truncated: true };
  return Object.fromEntries(Object.entries(value as Record<string, unknown>)
    .filter(([key]) => !/(token|secret|password|authorization|credential)/i.test(key))
    .map(([key, entry]) => [key, entry && typeof entry === "object" && !Array.isArray(entry) ? safeMetadata(entry, depth + 1) : entry]));
}

function leaseRequest(provider: Provider, input: AgentBrokerAdapterInput, env: Env) {
  const payload = input.payload;
  const operation = payload.operation;
  if (!OPERATIONS.includes(operation as VmHostLeaseOperation)) {
    throw new Error(`host lease payload operation must be acquire, renew, or release for ${provider}`);
  }
  const prefix = providerPrefix(provider);
  const hostId = typeof payload.hostId === "string" && payload.hostId.length > 0
    ? payload.hostId
    : env[`${prefix}_HOST_ID`];
  return {
    provider,
    operation: operation as VmHostLeaseOperation,
    leaseId: requiredString(payload.leaseId, "payload.leaseId"),
    hostId: requiredString(hostId, "payload.hostId"),
    ownerId: input.owner,
    generation: positiveInteger(payload.generation, "payload.generation"),
    effectKey: input.effectKey,
    ttlMs: positiveInteger(payload.ttlMs, "payload.ttlMs", 60_000),
    nowMs: positiveInteger(payload.nowMs, "payload.nowMs", Date.now()),
  } as const;
}

function adapter(provider: Provider, hostClass: string, client: VmHostLeaseProviderClient, env: Env): AgentBrokerEffectAdapter {
  return {
    hostClass,
    async execute(input): Promise<AgentBrokerAdapterResult> {
      const request = leaseRequest(provider, input, env);
      const result = await client[request.operation](request);
      return {
        provider,
        operation: request.operation,
        leaseId: request.leaseId,
        hostId: request.hostId,
        generation: request.generation,
        providerLeaseId: result.providerLeaseId ?? null,
        expiresAtMs: result.expiresAtMs ?? null,
        metadata: safeMetadata(result.metadata),
      };
    },
  };
}

/** Build only explicitly configured provider adapters; missing credentials fail closed. */
export function createHostLeaseAdapters(input: { readonly env: Env; readonly fetch?: Fetcher }): readonly AgentBrokerEffectAdapter[] {
  const fetcher = input.fetch ?? globalThis.fetch;
  if (typeof fetcher !== "function") throw new Error("host lease adapters require fetch");
  return PROVIDERS.flatMap((provider) => {
    const client = configuredClient(provider, input.env, fetcher);
    if (!client) return [];
    const hostClasses = provider === "freestyle" ? ["freestyle", "freestyle-vm"] : ["huge-blue"];
    return hostClasses.map((hostClass) => adapter(provider, hostClass, client, input.env));
  });
}

export async function createAgentBrokerAdapters(input: { readonly env: Env }): Promise<readonly AgentBrokerEffectAdapter[]> {
  return createHostLeaseAdapters(input);
}
