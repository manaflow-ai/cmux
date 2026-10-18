import { randomUUID } from "node:crypto";

/**
 * Provider-neutral host leases for remote VM brokers.
 *
 * The broker owns effect keys and injects a durable store. Provider adapters are
 * deliberately tiny: they translate the normalized operation to an injected
 * client and never construct SDK credentials themselves.
 */

export const VM_HOST_LEASE_PROVIDERS = ["huge-blue", "freestyle"] as const;
/** A registered host class/provider id, kept open for future VM hosts. */
export type VmHostLeaseProvider = string;

export const VM_HOST_LEASE_OPERATIONS = ["acquire", "renew", "release"] as const;
export type VmHostLeaseOperation = (typeof VM_HOST_LEASE_OPERATIONS)[number];

export type VmHostLeaseState = "active" | "released";

export const DEFAULT_VM_HOST_LEASE_TTL_MS = 60_000;
export const MIN_VM_HOST_LEASE_TTL_MS = 1_000;
export const MAX_VM_HOST_LEASE_TTL_MS = 15 * 60_000;

export type VmHostLeaseInput = {
  readonly provider: VmHostLeaseProvider;
  readonly operation: VmHostLeaseOperation;
  /** Stable lease identity across retries and process restarts. */
  readonly leaseId: string;
  /** Stable host identity (Huge Blue VM host, Freestyle VM, or future host). */
  readonly hostId: string;
  /** Coordinator/worker identity that owns the lease. */
  readonly ownerId: string;
  /** Monotonically increasing fence. A reacquire after expiry must advance it. */
  readonly generation: number;
  /** Stable broker effect key. Replays never call the provider twice. */
  readonly effectKey: string;
  /** Requested lease duration. The store clamps no values: invalid TTLs fail closed. */
  readonly ttlMs?: number;
  /** Injected clock value for deterministic tests and receipt auditing. */
  readonly nowMs?: number;
};

export type VmHostLeaseProviderOperation = Omit<Required<VmHostLeaseInput>, "operation"> & {
  readonly operation: VmHostLeaseOperation;
};

export type VmHostLeaseProviderResult = {
  /** Provider's opaque lease handle, if it has one. */
  readonly providerLeaseId?: string | null;
  /** Provider expiry in epoch milliseconds, when available. */
  readonly expiresAtMs?: number | null;
  /** Provider echo of the fencing generation, when available. */
  readonly generation?: number | null;
  /** Safe provider metadata; never put credentials here. */
  readonly metadata?: Readonly<Record<string, unknown>>;
};

export type VmHostLeaseReceipt = {
  readonly operation: VmHostLeaseOperation;
  readonly provider: VmHostLeaseProvider;
  readonly leaseId: string;
  readonly hostId: string;
  readonly ownerId: string;
  readonly generation: number;
  readonly state: VmHostLeaseState;
  readonly expiresAtMs: number;
  readonly effectKey: string;
  readonly providerLeaseId: string | null;
  readonly metadata: Readonly<Record<string, unknown>>;
  readonly replayed: boolean;
};

export type VmHostLeaseRecord = Omit<VmHostLeaseReceipt, "replayed">;

export type VmHostLeaseReservation =
  | { readonly kind: "new"; readonly reservationToken: string; readonly record: VmHostLeaseRecord | null }
  | { readonly kind: "pending"; readonly record: VmHostLeaseRecord | null }
  | { readonly kind: "replay"; readonly record: VmHostLeaseRecord };

/**
 * Durable reservation/commit seam. A production implementation must persist
 * reservations before provider I/O and retain completed effects for replay.
 */
export interface VmHostLeaseStore {
  reserve(input: VmHostLeaseInput, provider: VmHostLeaseProvider): Promise<VmHostLeaseReservation>;
  complete(input: VmHostLeaseInput, provider: VmHostLeaseProvider, result: VmHostLeaseProviderResult, reservationToken: string): Promise<VmHostLeaseRecord>;
}

export interface VmHostLeaseProviderClient {
  acquire(input: VmHostLeaseProviderOperation): Promise<VmHostLeaseProviderResult>;
  renew(input: VmHostLeaseProviderOperation): Promise<VmHostLeaseProviderResult>;
  release(input: VmHostLeaseProviderOperation): Promise<VmHostLeaseProviderResult>;
}

export interface VmHostLeaseProviderAdapter {
  readonly provider: VmHostLeaseProvider;
  execute(input: VmHostLeaseProviderOperation): Promise<VmHostLeaseProviderResult>;
}

export class VmHostLeaseError extends Error {
  constructor(
    public readonly code:
      | "invalid_input"
      | "stale_generation"
      | "lease_conflict"
      | "lease_expired"
      | "owner_mismatch"
      | "provider_mismatch"
      | "receipt_mismatch"
      | "store_error"
      | "provider_error",
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = "VmHostLeaseError";
  }
}

function validateToken(label: string, value: string): string {
  if (typeof value !== "string" || value.length < 1 || value.length > 256 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new VmHostLeaseError("invalid_input", `${label} must be 1 to 256 characters without control characters`);
  }
  return value;
}

export function validateVmHostLeaseInput(input: VmHostLeaseInput): Required<VmHostLeaseInput> {
  validateProvider(input.provider);
  if (!VM_HOST_LEASE_OPERATIONS.includes(input.operation)) {
    throw new VmHostLeaseError("invalid_input", `unsupported lease operation ${JSON.stringify(input.operation)}`);
  }
  validateToken("leaseId", input.leaseId);
  validateToken("hostId", input.hostId);
  validateToken("ownerId", input.ownerId);
  validateToken("effectKey", input.effectKey);
  if (!Number.isSafeInteger(input.generation) || input.generation < 1) {
    throw new VmHostLeaseError("invalid_input", "generation must be a positive safe integer");
  }
  const ttlMs = input.ttlMs ?? DEFAULT_VM_HOST_LEASE_TTL_MS;
  if (!Number.isSafeInteger(ttlMs) || ttlMs < MIN_VM_HOST_LEASE_TTL_MS || ttlMs > MAX_VM_HOST_LEASE_TTL_MS) {
    throw new VmHostLeaseError("invalid_input", `ttlMs must be an integer from ${MIN_VM_HOST_LEASE_TTL_MS} to ${MAX_VM_HOST_LEASE_TTL_MS}`);
  }
  const nowMs = input.nowMs ?? Date.now();
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
    throw new VmHostLeaseError("invalid_input", "nowMs must be a non-negative safe integer");
  }
  return { ...input, ttlMs, nowMs };
}

function validateProvider(provider: VmHostLeaseProvider): void {
  if (typeof provider !== "string" || !/^[a-z][a-z0-9-]{1,63}$/.test(provider)) {
    throw new VmHostLeaseError("invalid_input", `invalid host lease provider ${JSON.stringify(provider)}`);
  }
}

function providerOperation(input: Required<VmHostLeaseInput>): VmHostLeaseProviderOperation {
  return input;
}

function normalizeProviderResult(
  input: Required<VmHostLeaseInput>,
  provider: VmHostLeaseProvider,
  result: VmHostLeaseProviderResult,
): VmHostLeaseProviderResult {
  if (!result || typeof result !== "object") {
    throw new VmHostLeaseError("receipt_mismatch", "provider returned no lease receipt");
  }
  if (result.generation !== undefined && result.generation !== null && result.generation !== input.generation) {
    throw new VmHostLeaseError("receipt_mismatch", "provider lease receipt returned a different generation", {
      expected: input.generation,
      actual: result.generation,
      provider,
    });
  }
  if (result.expiresAtMs !== undefined && result.expiresAtMs !== null && (!Number.isSafeInteger(result.expiresAtMs) || result.expiresAtMs < input.nowMs)) {
    throw new VmHostLeaseError("receipt_mismatch", "provider lease receipt returned an invalid expiry", { expiresAtMs: result.expiresAtMs });
  }
  if (result.providerLeaseId !== undefined && result.providerLeaseId !== null) validateToken("providerLeaseId", result.providerLeaseId);
  return result;
}

function recordFrom(
  input: Required<VmHostLeaseInput>,
  provider: VmHostLeaseProvider,
  result: VmHostLeaseProviderResult,
): VmHostLeaseRecord {
  const normalized = normalizeProviderResult(input, provider, result);
  const expiresAtMs = input.operation === "release"
    ? input.nowMs
    : normalized.expiresAtMs ?? input.nowMs + input.ttlMs;
  if (input.operation !== "release" && expiresAtMs <= input.nowMs) {
    throw new VmHostLeaseError("receipt_mismatch", "provider lease expiry must be in the future", { expiresAtMs, nowMs: input.nowMs });
  }
  return {
    operation: input.operation,
    provider,
    leaseId: input.leaseId,
    hostId: input.hostId,
    ownerId: input.ownerId,
    generation: input.generation,
    state: input.operation === "release" ? "released" : "active",
    expiresAtMs,
    effectKey: input.effectKey,
    providerLeaseId: normalized.providerLeaseId ?? null,
    metadata: normalized.metadata ?? {},
  };
}

/** Provider-neutral transport with a required durable deduplication store. */
export class VmHostLeaseTransport {
  constructor(
    private readonly store: VmHostLeaseStore,
    private readonly adapters: ReadonlyMap<VmHostLeaseProvider, VmHostLeaseProviderAdapter>,
  ) {}

  /** Composition roots can fail closed before provisioning a remote VM. */
  hasConfiguredProvider(provider: VmHostLeaseProvider): boolean {
    const adapter = this.adapters.get(provider);
    return !!adapter && adapter.provider === provider;
  }

  acquire(input: Omit<VmHostLeaseInput, "operation">): Promise<VmHostLeaseReceipt> {
    return this.execute({ ...input, operation: "acquire" });
  }

  renew(input: Omit<VmHostLeaseInput, "operation">): Promise<VmHostLeaseReceipt> {
    return this.execute({ ...input, operation: "renew" });
  }

  release(input: Omit<VmHostLeaseInput, "operation">): Promise<VmHostLeaseReceipt> {
    return this.execute({ ...input, operation: "release" });
  }

  private async execute(rawInput: VmHostLeaseInput): Promise<VmHostLeaseReceipt> {
    const input = validateVmHostLeaseInput(rawInput);
    const provider = input.provider;
    const reservation = await this.store.reserve(input, provider);
    if (reservation.kind === "replay") return { ...reservation.record, replayed: true };
    if (reservation.kind === "pending") {
      throw new VmHostLeaseError("lease_conflict", "the same host lease effect is already in progress");
    }
    const adapter = this.adapters.get(provider);
    if (!adapter || adapter.provider !== provider) throw new VmHostLeaseError("provider_mismatch", `no adapter configured for ${provider}`);
    let providerResult: VmHostLeaseProviderResult;
    try {
      providerResult = await adapter.execute(providerOperation(input));
    } catch (cause) {
      if (cause instanceof VmHostLeaseError) throw cause;
      throw new VmHostLeaseError("provider_error", "host lease provider operation failed", cause);
    }
    const completed = recordFrom(input, provider, providerResult);
    const stored = await this.store.complete(input, provider, providerResult, reservation.reservationToken);
    // The store is authoritative for fencing and dedupe. It may normalize
    // provider metadata, but must return the same operation identity.
    if (stored.leaseId !== completed.leaseId || stored.effectKey !== completed.effectKey || stored.generation !== completed.generation) {
      throw new VmHostLeaseError("store_error", "lease store returned a mismatched completion record");
    }
    return { ...stored, replayed: false };
  }
}

abstract class InjectedVmHostLeaseAdapter implements VmHostLeaseProviderAdapter {
  abstract readonly provider: VmHostLeaseProvider;
  constructor(protected readonly client: VmHostLeaseProviderClient) {}

  execute(input: VmHostLeaseProviderOperation): Promise<VmHostLeaseProviderResult> {
    return this.client[input.operation](input);
  }
}

export class HugeBlueHostLeaseAdapter extends InjectedVmHostLeaseAdapter {
  readonly provider = "huge-blue" as const;
}

export class FreestyleHostLeaseAdapter extends InjectedVmHostLeaseAdapter {
  readonly provider = "freestyle" as const;
}

/** Generic adapter registration for a new host class (for example mac-mini). */
export class RegisteredHostLeaseAdapter extends InjectedVmHostLeaseAdapter {
  constructor(readonly provider: VmHostLeaseProvider, client: VmHostLeaseProviderClient) {
    super(client);
    validateProvider(provider);
  }
}

export function createHugeBlueHostLeaseAdapter(client: VmHostLeaseProviderClient): VmHostLeaseProviderAdapter {
  return new HugeBlueHostLeaseAdapter(client);
}

export function createFreestyleHostLeaseAdapter(client: VmHostLeaseProviderClient): VmHostLeaseProviderAdapter {
  return new FreestyleHostLeaseAdapter(client);
}

/**
 * Deterministic store for unit tests and local simulations. Production wiring
 * must use a durable implementation (for example DrizzleVmHostLeaseStore).
 */
export class MemoryVmHostLeaseStore implements VmHostLeaseStore {
  private readonly current = new Map<string, VmHostLeaseRecord>();
  private readonly operations = new Map<string, VmHostLeaseRecord>();
  private readonly pending = new Set<string>();
  private readonly pendingByLease = new Map<string, string>();
  private readonly pendingTokens = new Map<string, string>();

  async reserve(input: VmHostLeaseInput, provider: VmHostLeaseProvider): Promise<VmHostLeaseReservation> {
    const key = operationKey(input);
    const replay = this.operations.get(key);
    if (replay) {
      assertSameOperation(replay, input, provider);
      return { kind: "replay", record: replay };
    }
    const leaseKey = currentKey(input);
    const pendingKey = this.pendingByLease.get(leaseKey);
    if (pendingKey) return { kind: "pending", record: null };
    const current = this.current.get(currentKey(input));
    assertCanReserve(current, input, provider);
    this.pending.add(key);
    this.pendingByLease.set(leaseKey, key);
    const reservationToken = randomUUID();
    this.pendingTokens.set(key, reservationToken);
    return { kind: "new", reservationToken, record: null };
  }

  async complete(input: VmHostLeaseInput, provider: VmHostLeaseProvider, result: VmHostLeaseProviderResult, reservationToken: string): Promise<VmHostLeaseRecord> {
    const key = operationKey(input);
    const existing = this.operations.get(key);
    if ((!this.pending.has(key) && !existing) || (this.pendingTokens.get(key) !== reservationToken && !existing)) throw new VmHostLeaseError("store_error", "lease completion has no reservation");
    if (existing) assertSameOperation(existing, input, provider);
    const completed = recordFrom(validateVmHostLeaseInput(input), provider, result);
    const current = this.current.get(currentKey(input));
    if (current?.state === "released"
      && (input.operation === "renew" || input.generation <= current.generation)) {
      throw new VmHostLeaseError("lease_expired", "a released host lease cannot be renewed");
    }
    this.pending.delete(key);
    this.pendingTokens.delete(key);
    if (this.pendingByLease.get(currentKey(input)) === key) this.pendingByLease.delete(currentKey(input));
    this.operations.set(key, completed);
    this.current.set(currentKey(input), completed);
    return completed;
  }
}

function operationKey(input: VmHostLeaseInput): string {
  return `${input.hostId}\u0000${input.leaseId}\u0000${input.effectKey}`;
}

function currentKey(input: VmHostLeaseInput): string {
  return `${input.hostId}\u0000${input.leaseId}`;
}

function assertSameOperation(record: VmHostLeaseRecord, input: VmHostLeaseInput, provider: VmHostLeaseProvider): void {
  if (record.provider !== provider) throw new VmHostLeaseError("provider_mismatch", "lease effect belongs to another provider");
  if (record.ownerId !== input.ownerId || record.hostId !== input.hostId || record.leaseId !== input.leaseId) {
    throw new VmHostLeaseError("owner_mismatch", "lease effect identity does not match the reservation");
  }
  if (record.generation !== input.generation || record.operation !== input.operation) {
    throw new VmHostLeaseError("stale_generation", "lease effect generation or operation does not match the reservation");
  }
}

export function assertCanReserve(current: VmHostLeaseRecord | undefined, input: VmHostLeaseInput, provider: VmHostLeaseProvider): void {
  if (!current) {
    if (input.operation !== "acquire") throw new VmHostLeaseError("stale_generation", "cannot renew or release a missing lease");
    return;
  }
  if (current.provider !== provider) throw new VmHostLeaseError("provider_mismatch", "host lease is owned by another provider");
  if (current.ownerId !== input.ownerId) throw new VmHostLeaseError("owner_mismatch", "host lease is owned by another coordinator");
  const nowMs = input.nowMs ?? Date.now();
  const expired = current.state === "active" && current.expiresAtMs <= nowMs;
  if (input.operation === "acquire") {
    if (!expired && current.state === "active") throw new VmHostLeaseError("lease_conflict", "host lease is already active");
    if (input.generation <= current.generation) throw new VmHostLeaseError("stale_generation", "reacquire must advance the lease generation");
    return;
  }
  if (current.state !== "active" || expired) throw new VmHostLeaseError("lease_expired", "host lease is no longer active");
  if (input.generation !== current.generation) throw new VmHostLeaseError("stale_generation", "host lease generation is stale");
}

export type VmHostLeaseHttpClientConfig = {
  readonly baseUrl: string;
  /** Resolve a short-lived token at request time; raw credentials never enter lease records. */
  readonly token: () => string | Promise<string>;
  readonly fetch?: typeof fetch;
};

/**
 * Generic Huge Blue-compatible HTTP client. The protocol is intentionally
 * narrow and provider-neutral; Huge Blue's SDK/ACP gateway can be injected at
 * this boundary without adding credentials or SDK imports to the web service.
 */
export function createHugeBlueHostLeaseHttpClient(config: VmHostLeaseHttpClientConfig): VmHostLeaseProviderClient {
  return createHttpHostLeaseClient(config);
}

/**
 * Freestyle's broker gateway uses the same provider-neutral lease envelope.
 * The web runtime may still inject the native SDK facade below, while the
 * independently deployed worker uses this HTTP form so the SDK and its
 * credentials stay outside the worker image.
 */
export function createFreestyleHostLeaseHttpClient(config: VmHostLeaseHttpClientConfig): VmHostLeaseProviderClient {
  return createHttpHostLeaseClient(config);
}

export type FreestyleHostLeaseSdk = {
  readonly hostLeases: VmHostLeaseProviderClient;
};

export type ConfiguredHostLeaseAdapters = {
  readonly hugeBlue?: VmHostLeaseHttpClientConfig;
  readonly freestyle?: FreestyleHostLeaseSdk;
  readonly additional?: ReadonlyArray<{
    readonly provider: VmHostLeaseProvider;
    readonly client: VmHostLeaseProviderClient;
  }>;
};

/**
 * Build provider clients for the web composition root from deployment
 * configuration. Provider credentials stay in the process environment and
 * are only used by the HTTPS gateway client; they never enter broker payloads
 * or persisted receipts.
 */
export function createConfiguredHostLeaseAdaptersFromEnv(
  env: Readonly<Record<string, string | undefined>> = process.env,
): ReadonlyMap<VmHostLeaseProvider, VmHostLeaseProviderAdapter> {
  const adapters = new Map<VmHostLeaseProvider, VmHostLeaseProviderAdapter>();
  const hugeUrl = env.HUGE_BLUE_HOST_LEASE_URL?.trim();
  const hugeToken = (env.HUGE_BLUE_HOST_LEASE_TOKEN?.trim() || env.HUGE_BLUE_API_TOKEN?.trim());
  if (hugeUrl && hugeToken) {
    adapters.set("huge-blue", createHugeBlueHostLeaseAdapter(createHugeBlueHostLeaseHttpClient({
      baseUrl: hugeUrl,
      token: () => hugeToken,
    })));
  }
  const freestyleUrl = env.FREESTYLE_HOST_LEASE_URL?.trim();
  const freestyleToken = (env.FREESTYLE_HOST_LEASE_TOKEN?.trim() || env.FREESTYLE_API_TOKEN?.trim());
  if (freestyleUrl && freestyleToken) {
    adapters.set("freestyle", createFreestyleHostLeaseAdapter(createFreestyleHostLeaseHttpClient({
      baseUrl: freestyleUrl,
      token: () => freestyleToken,
    })));
  }
  return adapters;
}

/** Adapt the configured Freestyle SDK facade without importing credentials here. */
export function createFreestyleHostLeaseClient(config: { readonly sdk: FreestyleHostLeaseSdk }): VmHostLeaseProviderClient {
  if (!config.sdk?.hostLeases) throw new VmHostLeaseError("provider_mismatch", "Freestyle host lease SDK is not configured");
  return config.sdk.hostLeases;
}

/**
 * Builds the configured adapter registry for a broker worker. Missing provider
 * configuration is intentionally omitted, so selecting it fails closed rather
 * than falling back to an in-memory or another provider's client.
 */
export function createConfiguredHostLeaseAdapters(config: ConfiguredHostLeaseAdapters): ReadonlyMap<VmHostLeaseProvider, VmHostLeaseProviderAdapter> {
  const adapters = new Map<VmHostLeaseProvider, VmHostLeaseProviderAdapter>();
  if (config.hugeBlue) adapters.set("huge-blue", createHugeBlueHostLeaseAdapter(createHugeBlueHostLeaseHttpClient(config.hugeBlue)));
  if (config.freestyle) adapters.set("freestyle", createFreestyleHostLeaseAdapter(createFreestyleHostLeaseClient({ sdk: config.freestyle })));
  for (const entry of config.additional ?? []) adapters.set(entry.provider, new RegisteredHostLeaseAdapter(entry.provider, entry.client));
  return adapters;
}

function createHttpHostLeaseClient(config: VmHostLeaseHttpClientConfig): VmHostLeaseProviderClient {
  let baseUrl: URL;
  try {
    baseUrl = new URL(config.baseUrl);
  } catch (cause) {
    throw new VmHostLeaseError("invalid_input", "host lease gateway URL is invalid", cause);
  }
  if (baseUrl.protocol !== "https:") throw new VmHostLeaseError("invalid_input", "host lease gateway URL must use HTTPS");
  const fetcher = config.fetch ?? globalThis.fetch;
  if (typeof fetcher !== "function") throw new VmHostLeaseError("provider_mismatch", "host lease gateway has no fetch implementation");
  return {
    acquire: (input) => requestHostLeaseGateway(baseUrl, fetcher, config.token, input),
    renew: (input) => requestHostLeaseGateway(baseUrl, fetcher, config.token, input),
    release: (input) => requestHostLeaseGateway(baseUrl, fetcher, config.token, input),
  };
}

async function requestHostLeaseGateway(
  baseUrl: URL,
  fetcher: typeof fetch,
  tokenProvider: () => string | Promise<string>,
  input: VmHostLeaseProviderOperation,
): Promise<VmHostLeaseProviderResult> {
  const token = await tokenProvider();
  if (!token || /[\r\n]/.test(token)) throw new VmHostLeaseError("provider_mismatch", "host lease gateway token is unavailable");
  const endpoint = new URL(`/v1/hosts/${encodeURIComponent(input.hostId)}/leases/${input.operation}`, baseUrl);
  const response = await fetcher(endpoint, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      leaseId: input.leaseId,
      ownerId: input.ownerId,
      generation: input.generation,
      ttlMs: input.ttlMs,
      effectKey: input.effectKey,
    }),
  });
  let payload: unknown;
  try {
    payload = await response.json();
  } catch (cause) {
    throw new VmHostLeaseError("receipt_mismatch", "host lease gateway returned invalid JSON", cause);
  }
  if (!response.ok) throw new VmHostLeaseError("provider_mismatch", `host lease gateway rejected ${input.operation}`, { status: response.status, payload });
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new VmHostLeaseError("receipt_mismatch", "host lease gateway returned a non-object receipt");
  const value = payload as Record<string, unknown>;
  return {
    providerLeaseId: typeof value.providerLeaseId === "string" ? value.providerLeaseId : typeof value.leaseId === "string" ? value.leaseId : null,
    expiresAtMs: typeof value.expiresAtMs === "number" ? value.expiresAtMs : typeof value.expiresAt === "number" ? value.expiresAt : null,
    generation: typeof value.generation === "number" ? value.generation : null,
    metadata: value.metadata && typeof value.metadata === "object" && !Array.isArray(value.metadata) ? value.metadata as Record<string, unknown> : {},
  };
}
