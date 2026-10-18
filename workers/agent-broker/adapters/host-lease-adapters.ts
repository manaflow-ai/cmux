import { spawn } from "node:child_process";
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

function safeLeasePart(value: string, name: string): string {
  if (!/^[A-Za-z0-9._:/-]{1,256}$/.test(value)) throw new Error(`${name} contains unsupported characters`);
  return value;
}

function b64(value: string): string {
  return Buffer.from(value, "utf8").toString("base64");
}

function runSsh(host: string, script: string, options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string }): Promise<string> {
  return new Promise((resolve, reject) => {
    const args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"];
    if (options.user) args.push("-o", `User=${safeLeasePart(options.user, "SSH user")}`);
    if (options.identityFile) args.push("-i", safeLeasePart(options.identityFile, "SSH key path"));
    if (options.proxyCommand) args.push("-o", `ProxyCommand=${options.proxyCommand}`);
    args.push(host, "bash", "-s");
    const child = spawn("ssh", args, { stdio: ["pipe", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) return resolve(Buffer.concat(stdout).toString("utf8"));
      reject(new Error(`host lease SSH transport failed with exit ${code}: ${Buffer.concat(stderr).toString("utf8").slice(0, 512)}`));
    });
    child.stdin.end(script);
  });
}

function createSshHostLeaseClient(host: string, options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string }): VmHostLeaseProviderClient {
  const safeHost = safeLeasePart(host, "SSH host");
  return {
    acquire: (input) => runSshLease(safeHost, options, input),
    renew: (input) => runSshLease(safeHost, options, input),
    release: (input) => runSshLease(safeHost, options, input),
  };
}

async function runSshLease(
  host: string,
  options: { readonly user?: string; readonly identityFile?: string; readonly proxyCommand?: string },
  input: Parameters<VmHostLeaseProviderClient["acquire"]>[0],
): Promise<{ providerLeaseId: string; expiresAtMs: number; generation: number; metadata: Record<string, unknown> }> {
  const leaseId = safeLeasePart(input.leaseId, "lease id");
  const ownerId = safeLeasePart(input.ownerId, "owner id");
  const effectKey = safeLeasePart(input.effectKey, "effect key");
  const hostId = safeLeasePart(input.hostId, "host id");
  const op = input.operation;
  const script = `
set -eu
root="\$HOME/.cache/cmux-agent-broker/leases"
mkdir -p "\$root"
exec 9>"\$root/.lock"
flock -x 9
lease_id=\$(printf '%s' '${b64(leaseId)}' | base64 -d)
owner_id=\$(printf '%s' '${b64(ownerId)}' | base64 -d)
effect_key=\$(printf '%s' '${b64(effectKey)}' | base64 -d)
host_id=\$(printf '%s' '${b64(hostId)}' | base64 -d)
path="\$root/\$lease_id"
now_ms=${input.nowMs}
generation=${input.generation}
ttl_ms=${input.ttlMs}
current_owner=''
current_generation=0
current_expiry=0
if [ -f "\$path" ]; then read -r current_owner current_generation current_expiry _current_effect _current_host < "\$path" || true; fi
if [ '${op}' = acquire ]; then
  if [ "\$current_expiry" -gt "\$now_ms" ] && [ "\$generation" -le "\$current_generation" ]; then exit 73; fi
  expiry=\$((now_ms + ttl_ms))
  printf '%s %s %s %s %s\\n' "\$owner_id" "\$generation" "\$expiry" "\$effect_key" "\$host_id" > "\$path.tmp"
  mv -f "\$path.tmp" "\$path"
elif [ "\$current_owner" != "\$owner_id" ] || [ "\$current_generation" -ne "\$generation" ] || [ "\$current_expiry" -le "\$now_ms" ]; then
  exit 74
elif [ '${op}' = renew ]; then
  expiry=\$((now_ms + ttl_ms))
  printf '%s %s %s %s %s\\n' "\$owner_id" "\$generation" "\$expiry" "\$effect_key" "\$host_id" > "\$path.tmp"
  mv -f "\$path.tmp" "\$path"
else
  expiry=\$now_ms
  rm -f "\$path"
fi
printf '{"providerLeaseId":"ssh-%s","expiresAtMs":%s,"generation":%s,"metadata":{"transport":"ssh","hostId":"%s"}}\\n' "\$lease_id" "\$expiry" "\$generation" "\$host_id"
`;
  const parsed = JSON.parse((await runSsh(host, script, options)).trim()) as Record<string, unknown>;
  return {
    providerLeaseId: String(parsed.providerLeaseId),
    expiresAtMs: Number(parsed.expiresAtMs),
    generation: Number(parsed.generation),
    metadata: safeMetadata(parsed.metadata),
  };
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
