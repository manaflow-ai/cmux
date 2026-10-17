import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import {
  createConfiguredHostLeaseAdapters,
  createHugeBlueHostLeaseHttpClient,
  MemoryVmHostLeaseStore,
  VmHostLeaseTransport,
  type VmHostLeaseProvider,
  type VmHostLeaseProviderClient,
  type VmHostLeaseProviderAdapter,
  type VmHostLeaseReceipt,
} from "../services/vms/hostLeaseTransport";
import {
  persistentWorkspaceProviderFromCloudVm,
  createPersistentWorkspacePromotionRuntimePort,
  createPersistentWorkspaceService,
  type PersistentWorkspaceProvider,
  type PersistentWorkspaceRecord,
  type PersistentWorkspaceStore,
} from "../services/vms/persistentWorkspace";
import type { CloudVmPersistentTerminalRef, CloudVmWorkspaceRef } from "../services/vms/cloudVmRunAdapter";
import {
  type LifecycleEffectRequest,
  type LifecycleEffectReceipt,
  type PersistentWorkspaceEffectBroker,
} from "../services/vms/lifecycleEffectBroker";
import {
  promoteRunAttempt,
  type AttemptPromotionDependencies,
  type AttemptPromotionSource,
  type AttemptPromotionStorePort,
  type PromotionView,
} from "../services/runs/promotion";

/**
 * Cross-host broker verification is fixture-first. A fixture run covers the
 * complete lifecycle without credentials; live provider calls are only made
 * when CMUX_CROSS_HOST_LIVE=1 and a complete, provider-specific config exists.
 */
export const CROSS_HOST_PROVIDERS = ["huge-blue", "freestyle", "mac-mini"] as const;
export type CrossHostProvider = (typeof CROSS_HOST_PROVIDERS)[number];
export type VerificationMode = "fixture" | "live";
export type VerificationStatus = "passed" | "skipped" | "failed";

export type CrossHostLaneReport = {
  readonly provider: CrossHostProvider;
  readonly mode: VerificationMode;
  readonly status: VerificationStatus;
  readonly reason?: string;
  readonly adapterRegistered: boolean;
  readonly leaseReceipts: readonly Pick<VmHostLeaseReceipt, "operation" | "state" | "generation" | "effectKey" | "replayed">[];
  readonly effectReceipts: readonly EffectReceipt[];
  readonly workspace: {
    readonly replayed: boolean;
    readonly lifecycle: string;
    readonly runtimeId: string;
    readonly workspaceId: string;
  };
  readonly promotion: {
    readonly replayed: boolean;
    readonly runtimeId: string;
    readonly workspaceId: string;
    readonly sessionId: string;
  };
};

export type CrossHostVerificationReport = {
  readonly startedAt: string;
  readonly finishedAt: string;
  readonly liveRequested: boolean;
  readonly liveConfig: Record<CrossHostProvider, LiveConfigStatus>;
  readonly lanes: readonly CrossHostLaneReport[];
};

export type LiveConfigStatus = {
  readonly configured: boolean;
  readonly usable: boolean;
  readonly detail: string;
};

type Env = Record<string, string | undefined>;

type EffectReceipt = {
  readonly effectKey: string;
  readonly requestDigest: string;
  readonly sequence: number;
  readonly replayed: boolean;
};

function digest(value: unknown): string {
  // This is a verification-only digest; the production broker validates its
  // canonical request digest before persisting an effect.
  const text = JSON.stringify(value);
  let hash = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `fixture:${(hash >>> 0).toString(16).padStart(8, "0")}`;
}

class FixtureEffectBroker implements PersistentWorkspaceEffectBroker {
  private sequence = 0;
  private readonly effects = new Map<string, { readonly requestDigest: string; readonly result: Record<string, unknown> }>();
  readonly receipts: EffectReceipt[] = [];
  readonly requests: LifecycleEffectRequest[] = [];

  async execute(input: LifecycleEffectRequest): Promise<LifecycleEffectReceipt> {
    this.requests.push(input);
    const requestDigest = digest(input.payload);
    const previous = this.effects.get(input.effectKey);
    if (previous) {
      this.receipts.push({ effectKey: input.effectKey, requestDigest, sequence: ++this.sequence, replayed: true });
      return { result: previous.result, replayed: true, jobId: `fixture-job-${input.effectKey}`, sequence: this.sequence };
    }
    const result = await input.run();
    const normalized = JSON.parse(JSON.stringify(result)) as Record<string, unknown>;
    this.effects.set(input.effectKey, { requestDigest, result: normalized });
    this.receipts.push({ effectKey: input.effectKey, requestDigest, sequence: ++this.sequence, replayed: false });
    return { result: normalized, replayed: false, jobId: `fixture-job-${input.effectKey}`, sequence: this.sequence };
  }

  async apply<T>(effectKey: string, request: unknown, operation: () => T | Promise<T>): Promise<T> {
    const requestDigest = digest(request);
    const previous = this.effects.get(effectKey);
    if (previous) {
      assert.equal(previous.requestDigest, requestDigest, `effect ${effectKey} changed its request`);
      this.receipts.push({ effectKey, requestDigest, sequence: ++this.sequence, replayed: true });
      return previous.result as T;
    }
    const result = await operation();
    const normalized = JSON.parse(JSON.stringify(result)) as Record<string, unknown>;
    this.effects.set(effectKey, { requestDigest, result: normalized });
    this.receipts.push({ effectKey, requestDigest, sequence: ++this.sequence, replayed: false });
    return result;
  }
}

function fixtureClient(provider: CrossHostProvider, calls: string[]): VmHostLeaseProviderClient {
  return {
    async acquire(input) {
      calls.push(`${provider}:acquire:${input.effectKey}`);
      return { providerLeaseId: `${provider}-fixture-lease`, generation: input.generation, expiresAtMs: input.nowMs + input.ttlMs, metadata: { fixture: true, provider } };
    },
    async renew(input) {
      calls.push(`${provider}:renew:${input.effectKey}`);
      return { providerLeaseId: `${provider}-fixture-lease`, generation: input.generation, expiresAtMs: input.nowMs + input.ttlMs, metadata: { fixture: true, provider } };
    },
    async release(input) {
      calls.push(`${provider}:release:${input.effectKey}`);
      return { providerLeaseId: `${provider}-fixture-lease`, generation: input.generation, expiresAtMs: input.nowMs, metadata: { fixture: true, provider } };
    },
  };
}

function fixtureFetch(provider: CrossHostProvider, calls: string[]): typeof fetch {
  return async (input, init) => {
    const url = String(input);
    const body = JSON.parse(String(init?.body ?? "{}")) as { effectKey?: string; generation?: number; ttlMs?: number };
    const operation = url.split("/").at(-1) ?? "unknown";
    const hostId = decodeURIComponent(url.split("/hosts/")[1]?.split("/", 1)[0] ?? "");
    const wiredHost = hostId.endsWith("-fixture-vm");
    calls.push(`${provider}:${operation}:${body.effectKey ?? "missing"}`);
    return new Response(JSON.stringify({
      leaseId: `${provider}-fixture-lease`,
      generation: body.generation,
      // Direct transport checks use a deterministic clock; the wired provider
      // path uses Date.now(), so its fixture receipt is relative to that clock.
      expiresAtMs: operation === "release" ? null : wiredHost ? Date.now() + 60_000 : (body.generation === 1 ? 9_000 : 11_000),
      metadata: { fixture: true, provider },
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
}

function fixtureAdapters(calls: string[]): ReadonlyMap<VmHostLeaseProvider, VmHostLeaseProviderAdapter> {
  const freestyle = fixtureClient("freestyle", calls);
  const macMini = fixtureClient("mac-mini", calls);
  return createConfiguredHostLeaseAdapters({
    hugeBlue: {
      baseUrl: "https://fixture.invalid/huge-blue",
      token: () => "fixture-token",
      fetch: fixtureFetch("huge-blue", calls),
    },
    freestyle: { hostLeases: freestyle },
    additional: [{ provider: "mac-mini", client: macMini }],
  });
}

function fixtureWorkspaceStore(): PersistentWorkspaceStore {
  const rows = new Map<string, PersistentWorkspaceRecord>();
  return {
    async createRuntime({ record }) {
      const existing = [...rows.values()].find((row) => row.tenantId === record.tenantId && row.idempotencyKey === record.idempotencyKey);
      if (existing) return { record: existing, created: false };
      rows.set(record.runtimeId, record);
      return { record, created: true };
    },
    async getRuntime({ runtimeId }) { return rows.get(runtimeId) ?? null; },
    async updateRuntime({ runtimeId, patch, expectedVersion }) {
      const current = rows.get(runtimeId);
      if (!current) throw new Error(`fixture runtime ${runtimeId} is missing`);
      if (expectedVersion !== undefined && expectedVersion !== (current.version ?? 1)) throw new Error("fixture runtime version fence failed");
      const next = { ...current, ...patch, version: (current.version ?? 1) + 1, updatedAt: new Date().toISOString() };
      rows.set(runtimeId, next);
      return next;
    },
  };
}

function fixtureWorkspaceProvider(provider: CrossHostProvider, calls: string[]): PersistentWorkspaceProvider {
  return {
    async create(input) {
      calls.push(`${provider}:workspace:create:${input.workspaceKey}`);
      return {
        providerVmId: `${provider}-fixture-vm`,
        providerWorkspaceId: `${provider}-fixture-workspace`,
        providerTerminalId: `${provider}-fixture-terminal`,
      };
    },
    async resume(input) { calls.push(`${provider}:workspace:resume:${input.providerVmId}`); },
    async suspend(input) { calls.push(`${provider}:workspace:suspend:${input.providerVmId}`); },
    async stop(input) { calls.push(`${provider}:workspace:stop:${input.providerVmId}`); },
    async attach() { return { provider, url: `wss://${provider}.fixture.invalid/attach?token=fixture` }; },
  };
}

function wiredWorkspaceProvider(
  provider: CrossHostProvider,
  calls: string[],
  leaseTransport: VmHostLeaseTransport,
  effectBroker: FixtureEffectBroker,
): PersistentWorkspaceProvider {
  return persistentWorkspaceProviderFromCloudVm({
    provisionVm: async (input) => {
      calls.push(`${provider}:vm:create:${input.workspaceKey}`);
      return { providerVmId: `${provider}-fixture-vm` };
    },
    vm: {
      async resume(providerVmId) { calls.push(`${provider}:vm:resume:${providerVmId}`); },
      async pause(providerVmId) { calls.push(`${provider}:vm:pause:${providerVmId}`); },
    },
    runAdapter: {
      async createWorkspace(input): Promise<CloudVmWorkspaceRef> {
        calls.push(`${provider}:workspace:create:${input.workspaceKey}`);
        return {
          provider: "cloud-vm",
          runtimeId: input.runtimeId,
          vmId: input.vmId,
          workspaceId: `${provider}-fixture-workspace`,
          workspaceKey: input.workspaceKey,
          replayed: false,
        };
      },
      async createTerminal(input): Promise<CloudVmPersistentTerminalRef> {
        calls.push(`${provider}:terminal:create:${input.terminalKey ?? `cmux-runtime:${input.runtimeId}:terminal`}`);
        return {
          provider: "cloud-vm",
          runtimeId: input.runtimeId,
          vmId: input.vmId,
          workspaceId: input.workspaceId,
          terminalId: `${provider}-fixture-terminal`,
          terminalKey: input.terminalKey ?? `cmux-runtime:${input.runtimeId}:terminal`,
          replayed: false,
        };
      },
    },
    hostLeaseTransport: leaseTransport,
    effectBroker,
    hostLeaseProvider: provider,
    hostLeaseTtlMs: 10_000,
    attach: async () => ({ provider, url: `wss://${provider}.fixture.invalid/attach?token=fixture` }),
  });
}

class FixturePromotionStore implements AttemptPromotionStorePort {
  private readonly byKey = new Map<string, PromotionView>();
  private readonly byAttempt = new Map<string, PromotionView>();
  private readonly pending = new Map<string, { userId: string; runId: string; attemptId: string }>();

  async findByRequestKey(input: { userId: string; requestKey: string }): Promise<PromotionView | null> {
    return this.byKey.get(`${input.userId}:${input.requestKey}`) ?? null;
  }
  async reserve(input: { userId: string; runId: string; attemptId: string; requestKey: string }) {
    const key = `${input.userId}:${input.requestKey}`;
    const attemptKey = `${input.userId}:${input.runId}:${input.attemptId}`;
    const existing = this.byKey.get(key);
    if (existing) return existing.runId === input.runId && existing.attemptId === input.attemptId
      ? { kind: "replay" as const, promotion: existing }
      : { kind: "idempotency_conflict" as const };
    const duplicate = this.byAttempt.get(attemptKey);
    if (duplicate) return { kind: "duplicate" as const, promotion: duplicate };
    if (this.pending.has(key)) return { kind: "in_progress" as const };
    this.pending.set(key, input);
    return { kind: "reserved" as const, reservation: { claimId: key } };
  }
  async complete(input: { reservation: { claimId: string }; promotion: PromotionView }) {
    const pending = this.pending.get(input.reservation.claimId);
    if (!pending) throw new Error("missing promotion reservation");
    this.pending.delete(input.reservation.claimId);
    this.byKey.set(input.reservation.claimId, input.promotion);
    this.byAttempt.set(`${pending.userId}:${pending.runId}:${pending.attemptId}`, input.promotion);
    return input.promotion;
  }
  async release(reservation: { claimId: string }) { this.pending.delete(reservation.claimId); }
}

function promotionSource(provider: CrossHostProvider): AttemptPromotionSource {
  return {
    userId: "fixture-user",
    runId: `run-${provider}`,
    attemptId: `attempt-${provider}`,
    status: "succeeded",
    provider,
    billingTeamId: "fixture-team",
    providerVmId: `${provider}-fixture-vm`,
    providerWorkspaceId: `${provider}-fixture-workspace`,
    providerTerminalId: `${provider}-fixture-terminal`,
    terminalRetainUntil: new Date(Date.now() + 60_000),
    result: { evidenceVerified: true },
    artifacts: [{ id: `artifact-${provider}`, digest: `sha256:${"a".repeat(64)}`, verified: true }],
  };
}

function promotionDependencies(source: AttemptPromotionSource, service: ReturnType<typeof createPersistentWorkspaceService>): AttemptPromotionDependencies {
  const store = new FixturePromotionStore();
  return {
    source: { find: async (input) => input.userId === source.userId && input.runId === source.runId && input.attemptId === source.attemptId ? source : null },
    store,
    runtime: createPersistentWorkspacePromotionRuntimePort({ service }),
  };
}

function liveConfig(env: Env): Record<CrossHostProvider, LiveConfigStatus> {
  const liveRequested = env.CMUX_CROSS_HOST_LIVE === "1";
  const hugeUrl = env.HUGE_BLUE_HOST_LEASE_URL?.trim();
  const hugeToken = env.HUGE_BLUE_HOST_LEASE_TOKEN?.trim() || env.HUGE_BLUE_API_TOKEN?.trim();
  const hugeHost = env.HUGE_BLUE_HOST_ID?.trim();
  const freestyleUrl = env.FREESTYLE_HOST_LEASE_URL?.trim();
  const freestyleToken = env.FREESTYLE_HOST_LEASE_TOKEN?.trim();
  const freestyleHost = env.FREESTYLE_HOST_ID?.trim();
  const hugeConfigured = Boolean(hugeUrl && hugeToken && hugeHost);
  const freestyleConfigured = Boolean(freestyleUrl && freestyleToken && freestyleHost);
  return {
    "huge-blue": {
      configured: hugeConfigured,
      usable: liveRequested && hugeConfigured,
      detail: hugeConfigured ? "gateway URL, token, and host id are configured" : "set HUGE_BLUE_HOST_LEASE_URL, HUGE_BLUE_HOST_LEASE_TOKEN, and HUGE_BLUE_HOST_ID",
    },
    freestyle: {
      configured: freestyleConfigured,
      usable: liveRequested && freestyleConfigured,
      detail: freestyleConfigured ? "host lease gateway URL, token, and host id are configured" : "set FREESTYLE_HOST_LEASE_URL, FREESTYLE_HOST_LEASE_TOKEN, and FREESTYLE_HOST_ID",
    },
    "mac-mini": {
      configured: false,
      usable: false,
      detail: "Mac mini is a deterministic fixture lane; no remote credentials are read",
    },
  };
}

async function runLiveLeaseProbe(
  provider: Exclude<CrossHostProvider, "mac-mini">,
  config: LiveConfigStatus,
  env: Env,
): Promise<readonly Pick<VmHostLeaseReceipt, "operation" | "state" | "generation" | "effectKey" | "replayed">[]> {
  if (!config.usable) throw new Error(`live ${provider} lane is not configured`);
  const baseUrl = provider === "huge-blue" ? env.HUGE_BLUE_HOST_LEASE_URL?.trim() : env.FREESTYLE_HOST_LEASE_URL?.trim();
  const token = provider === "huge-blue"
    ? (env.HUGE_BLUE_HOST_LEASE_TOKEN?.trim() || env.HUGE_BLUE_API_TOKEN?.trim())
    : env.FREESTYLE_HOST_LEASE_TOKEN?.trim();
  const hostId = provider === "huge-blue" ? env.HUGE_BLUE_HOST_ID?.trim() : env.FREESTYLE_HOST_ID?.trim();
  if (!baseUrl || !token || !hostId) throw new Error(`live ${provider} lane is missing required configuration`);
  const client = createHugeBlueHostLeaseHttpClient({ baseUrl, token: () => token });
  const adapters = createConfiguredHostLeaseAdapters({ additional: [{ provider, client }] });
  const transport = new VmHostLeaseTransport(new MemoryVmHostLeaseStore(), adapters);
  const lease = { provider, leaseId: `cmux-cross-host-${randomUUID()}`, hostId, ownerId: "cmux-cross-host-verifier", generation: 1, ttlMs: 30_000 } as const;
  const acquire = await transport.acquire({ ...lease, effectKey: `cmux-cross-host:${provider}:acquire`, nowMs: Date.now() });
  const release = await transport.release({ ...lease, effectKey: `cmux-cross-host:${provider}:release`, nowMs: Date.now() + 100 });
  return [acquire, release];
}

async function runFixtureLane(provider: CrossHostProvider): Promise<CrossHostLaneReport> {
  const calls: string[] = [];
  const adapters = fixtureAdapters(calls);
  assert(adapters.has(provider), `${provider} fixture adapter is not registered`);
  const transport = new VmHostLeaseTransport(new MemoryVmHostLeaseStore(), adapters);
  const broker = new FixtureEffectBroker();
  const leaseBase = { provider, leaseId: `lease-${provider}`, hostId: `${provider}:fixture-host`, ownerId: "fixture-worker", generation: 1, ttlMs: 1_000 } as const;
  const acquireInput = { ...leaseBase, effectKey: `lease:${provider}:acquire`, nowMs: 0 } as const;
  const first = await broker.apply(acquireInput.effectKey, acquireInput, () => transport.acquire(acquireInput));
  // Exercise both dedupe layers: the transport returns a replay receipt, while
  // the broker suppresses the second provider invocation and records a replay.
  const replay = await transport.acquire(acquireInput);
  await broker.apply(acquireInput.effectKey, acquireInput, () => replay);
  assert.equal(replay.replayed, true);
  assert.equal(first.replayed, false);
  await assert.rejects(() => transport.renew({ ...leaseBase, generation: 2, effectKey: `lease:${provider}:stale`, nowMs: 100 }), (error: unknown) => (error as { code?: string }).code === "stale_generation");
  const reacquireAt = provider === "huge-blue" ? 10_000 : 1_000;
  const reacquired = await transport.acquire({ ...leaseBase, generation: 2, effectKey: `lease:${provider}:reacquire`, nowMs: reacquireAt });
  assert.equal(reacquired.generation, 2);
  const release = await transport.release({ ...leaseBase, generation: 2, effectKey: `lease:${provider}:release`, nowMs: reacquireAt + 100 });
  assert.equal(release.state, "released");

  // Keep one direct provider/service lane as a control check, then run the
  // same lifecycle through the configured host lease + effect-broker path.
  const directCalls: string[] = [];
  const directService = createPersistentWorkspaceService({
    store: fixtureWorkspaceStore(),
    provider: fixtureWorkspaceProvider(provider, directCalls),
  });
  const direct = await directService.create({
    tenantId: "fixture-team",
    ownerId: "fixture-user",
    idempotencyKey: `direct-workspace-${provider}`,
    workspaceName: `${provider} direct workspace`,
  });
  const directLookup = { tenantId: "fixture-team", ownerId: "fixture-user", runtimeId: direct.runtimeId };
  await directService.suspend(directLookup);
  await directService.resume(directLookup);
  await directService.stop(directLookup);
  assert.equal(directCalls.filter((call) => call.includes(":workspace:create:")).length, 1);

  const wiredProvider = wiredWorkspaceProvider(provider, calls, transport, broker);
  const workspaceService = createPersistentWorkspaceService({
    store: fixtureWorkspaceStore(),
    provider: wiredProvider,
  });
  const request = {
    tenantId: "fixture-team",
    ownerId: "fixture-user",
    idempotencyKey: `workspace-${provider}`,
    workspaceName: `${provider} verification workspace`,
    providerInput: { providerMetadata: { hostClass: provider, fixture: true } },
  } as const;
  const workspace = await broker.apply(`workspace:${provider}:create`, request, () => workspaceService.create(request));
  const workspaceReplay = await broker.apply(`workspace:${provider}:create`, request, () => workspaceService.create(request));
  assert.equal(workspaceReplay.runtimeId, workspace.runtimeId);
  assert.equal(workspaceReplay.workspaceId, workspace.workspaceId);
  const providerCreateInput = {
    runtimeId: workspace.runtimeId,
    workspaceId: workspace.workspaceId,
    tenantId: request.tenantId,
    ownerId: request.ownerId,
    generation: 1,
    effectKey: `cmux-runtime:${workspace.runtimeId}:create:v1`,
    workspaceName: request.workspaceName,
    workspaceKey: `cmux-runtime:${workspace.runtimeId}:workspace`,
    providerInput: request.providerInput,
  } as const;
  const providerReplay = await wiredProvider.create(providerCreateInput);
  assert.equal(providerReplay.providerWorkspaceId, workspace.provider === "freestyle" ? `${provider}-fixture-workspace` : `${provider}-fixture-workspace`);
  await workspaceService.suspend({ tenantId: request.tenantId, ownerId: request.ownerId, runtimeId: workspace.runtimeId });
  const resumed = await workspaceService.resume({ tenantId: request.tenantId, ownerId: request.ownerId, runtimeId: workspace.runtimeId });
  assert.equal(resumed.lifecycle, "running");
  const stopped = await workspaceService.stop({ tenantId: request.tenantId, ownerId: request.ownerId, runtimeId: workspace.runtimeId });
  assert.equal(stopped.lifecycle, "stopped");

  const source = promotionSource(provider);
  const promotion = await promoteRunAttempt({
    userId: source.userId,
    runId: source.runId,
    attemptId: source.attemptId,
    requestKey: `promote-${provider}`,
    dependencies: promotionDependencies(source, workspaceService),
    now: Date.now(),
  });
  assert.match(promotion.runtime.id, /^runtime_/);
  assert.match(promotion.workspace.id, /^workspace_/);
  assert.equal(promotion.attach.reconnectable, true);
  assert(broker.receipts.some((receipt) => receipt.replayed), "wired lifecycle broker did not record a replay");
  assert(calls.some((call) => call.startsWith(`${provider}:acquire:`)), "wired provider did not acquire host lease");

  return {
    provider,
    mode: "fixture",
    status: "passed",
    adapterRegistered: true,
    leaseReceipts: [first, replay, reacquired, release],
    effectReceipts: broker.receipts,
    workspace: { replayed: workspaceReplay.runtimeId === workspace.runtimeId, lifecycle: stopped.lifecycle, runtimeId: workspace.runtimeId, workspaceId: workspace.workspaceId },
    promotion: { replayed: false, runtimeId: promotion.runtime.id, workspaceId: promotion.workspace.id, sessionId: promotion.runtime.sessionId },
  };
}

/** Run deterministic verification and produce a redacted machine-readable receipt. */
export async function runCrossHostVerification(options: { readonly env?: Env; readonly live?: boolean } = {}): Promise<CrossHostVerificationReport> {
  const env = options.env ?? process.env;
  const startedAt = new Date().toISOString();
  const config = liveConfig(env);
  const lanes: CrossHostLaneReport[] = [];
  for (const provider of CROSS_HOST_PROVIDERS) {
    lanes.push(await runFixtureLane(provider));
    if (provider !== "mac-mini" && (options.live ?? env.CMUX_CROSS_HOST_LIVE === "1")) {
      if (!config[provider].usable) {
        lanes.push({
          ...lanes.at(-1)!,
          mode: "live",
          status: "skipped",
          reason: config[provider].detail,
          leaseReceipts: [],
          effectReceipts: [],
          workspace: { replayed: false, lifecycle: "skipped", runtimeId: "", workspaceId: "" },
          promotion: { replayed: false, runtimeId: "", workspaceId: "", sessionId: "" },
        });
      } else {
        // A live provider probe is deliberately limited to acquire/release. The
        // fixture lane above remains the complete runtime/workspace/promotion
        // gate until a provider workspace SDK is explicitly composed here.
        const fixture = lanes.at(-1)!;
        const leaseReceipts = await runLiveLeaseProbe(provider, config[provider], env);
        lanes.push({ ...fixture, mode: "live", status: "passed", reason: "live lease probe passed; workspace and promotion were verified by the fixture lane", leaseReceipts, effectReceipts: [] });
      }
    }
  }
  // Live calls are intentionally reported as skipped until a provider adapter
  // is explicitly injected. The fixture receipt remains the required gate.
  return { startedAt, finishedAt: new Date().toISOString(), liveRequested: options.live ?? env.CMUX_CROSS_HOST_LIVE === "1", liveConfig: config, lanes };
}

if (process.argv[1]?.endsWith("/verify-cross-host-broker.ts")) {
  const report = await runCrossHostVerification();
  console.log(JSON.stringify(report, null, 2));
}
