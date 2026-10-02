import {
  CHECKPOINT_OPS,
  checkpointList,
  checkpointRecord,
  mutationEnvelope,
  CheckpointRpcError,
  supportsCheckpointCapability,
  type Checkpoint,
  type CheckpointCapability,
  type CheckpointList,
  type CheckpointTarget,
  type MutationEnvelope,
} from "./protocol";

export type { CheckpointTarget } from "./protocol";
export type Request = (method: string, params: Record<string, unknown>) => Promise<unknown>;
export interface CheckpointPersistence {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
}
export type CheckpointClientState = {
  target?: CheckpointTarget;
  supported: boolean;
  capabilities?: CheckpointCapability;
  list?: CheckpointList;
  record?: Checkpoint;
  busy?: "listing" | "creating" | "pinning" | "unpinning";
  error?: CheckpointRpcError;
};
export type CreateInput = {
  expected_repository_id?: string;
  expected_worktree_id?: string;
  include_untracked?: string[] | "eligible";
  exclude_paths?: string[];
  reason?: "manual" | "handoff";
  limits?: { max_bytes?: number; max_files?: number };
};
export type PinInput = { checkpoint_id: string; pin_id: string; reason: string };
export type UnpinInput = { checkpoint_id: string; pin_id: string };
export type CapabilityReader = () => Promise<CheckpointCapability>;
export type CheckpointClientOptions = {
  persistence?: CheckpointPersistence;
  key?: () => string;
  capabilities?: CapabilityReader;
  onChange?: () => void;
};

type StoredMutation = { idempotency_key: string; attempted: boolean };
type MutationOperation = "create" | "pin" | "unpin";
const fallbackValues = new Map<string, unknown>();
const defaultPersistence: CheckpointPersistence = {
  async get(key) {
    try {
      const value = (globalThis as { localStorage?: Storage }).localStorage?.getItem(key);
      return value === null || value === undefined ? fallbackValues.get(key) : JSON.parse(value);
    } catch {
      return fallbackValues.get(key);
    }
  },
  async set(key, value) {
    fallbackValues.set(key, value);
    try {
      (globalThis as { localStorage?: Storage }).localStorage?.setItem(key, JSON.stringify(value));
    } catch {
      /* private storage or test runtime */
    }
  },
  async delete(key) {
    fallbackValues.delete(key);
    try {
      (globalThis as { localStorage?: Storage }).localStorage?.removeItem(key);
    } catch {
      /* private storage or test runtime */
    }
  },
};

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${stable(item)}`)
      .join(",")}}`;
  return JSON.stringify(value) ?? "null";
}
function requestError(error: unknown): CheckpointRpcError {
  if (error instanceof CheckpointRpcError) return error;
  if (error && typeof error === "object" && ("code" in error || "origin" in error)) {
    const raw = error as Record<string, unknown>;
    return new CheckpointRpcError({
      code: raw.code,
      userMessage: raw.userMessage ?? raw.message,
      details: raw.details,
      retryable: raw.retryable,
      origin: raw.origin,
    });
  }
  return new CheckpointRpcError({
    code: "operation.failed",
    userMessage: error instanceof Error ? error.message : "Request failed",
  });
}
function targetParams(target: CheckpointTarget): Record<string, unknown> {
  const params = { ...target } as Record<string, unknown>;
  if (typeof params.cwd !== "string" || params.cwd.length === 0)
    throw new CheckpointRpcError("validation.invalid", "A working directory is required.");
  return params;
}
function isNotFound(error: unknown): boolean {
  return requestError(error).code === "resource.not_found";
}

/** A small projection/controller for daemon-owned checkpoint records. It never derives record fields locally. */
export class CheckpointClient {
  state: CheckpointClientState = { supported: true };
  private request: Request;
  private persistence: CheckpointPersistence;
  private key: () => string;
  private capabilityReader: CapabilityReader;
  private online = true;
  private generation = 0;
  private listeners = new Set<() => void>();
  constructor(
    request: Request,
    persistenceOrOptions: CheckpointPersistence | CheckpointClientOptions = defaultPersistence,
    key?: () => string,
    capabilities?: CapabilityReader,
  ) {
    this.request = request;
    const options = "get" in persistenceOrOptions ? undefined : persistenceOrOptions;
    this.persistence =
      options?.persistence ?? ("get" in persistenceOrOptions ? persistenceOrOptions : defaultPersistence);
    this.key = key ?? options?.key ?? (() => crypto.randomUUID());
    this.capabilityReader = capabilities ?? options?.capabilities ?? (async () => ({ checkpoints: true }));
    this.onChange = options?.onChange;
  }
  private onChange?: () => void;
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  getSnapshot(): CheckpointClientState {
    return this.state;
  }
  private changed(): void {
    this.onChange?.();
    for (const listener of this.listeners) listener();
  }
  select(target?: CheckpointTarget): void {
    this.generation += 1;
    this.state = { supported: this.state.supported, capabilities: this.state.capabilities, target };
    this.changed();
  }
  setCatalog(_catalog: unknown, _expectedSha?: string): void {
    /* v1.1 has no runtime catalog read; retained for generated callers */
  }
  async refreshCapabilities(): Promise<boolean> {
    try {
      const capabilities = await this.capabilityReader();
      this.state = {
        ...this.state,
        capabilities,
        supported: supportsCheckpointCapability(capabilities),
        error: undefined,
      };
      this.changed();
      return this.state.supported;
    } catch (error) {
      this.state = { ...this.state, supported: false, error: requestError(error) };
      this.changed();
      return false;
    }
  }
  setOnline(online: boolean): void {
    this.online = online;
    if (!online) this.state = { ...this.state, busy: undefined };
    this.changed();
  }
  private requireReady(mutation = false): CheckpointTarget {
    if (!this.state.supported)
      throw new CheckpointRpcError("operation.unsupported", "Checkpoint capture is unavailable.");
    if (mutation && !this.online)
      throw new CheckpointRpcError(
        {
          code: "operation.failed",
          userMessage: "Checkpoint capture is unavailable while offline.",
          details: { reason: "offline" },
        },
        undefined,
        "offline",
      );
    const target = this.state.target;
    if (!target) throw new CheckpointRpcError("validation.invalid", "Select an agent working directory first.");
    if (target.hostKind === "cloud")
      throw new CheckpointRpcError(
        {
          code: "operation.failed",
          userMessage: "Cloud sessions do not expose local checkpoints.",
          details: { reason: "cloud_unsupported" },
        },
        undefined,
        "cloud_unsupported",
      );
    targetParams(target);
    return target;
  }
  private async call(method: string, params: Record<string, unknown>): Promise<unknown> {
    try {
      return await this.request(method, params);
    } catch (error) {
      const parsed = requestError(error);
      if (parsed.code === "operation.unsupported") {
        this.state = { ...this.state, supported: false, error: parsed };
        this.changed();
      }
      throw parsed;
    }
  }
  async list(params: { include_candidates?: boolean; cursor?: string; limit?: number } = {}): Promise<CheckpointList> {
    const target = this.requireReady();
    const generation = this.generation;
    this.state = { ...this.state, busy: "listing", error: undefined };
    this.changed();
    try {
      const result = checkpointList(await this.call(CHECKPOINT_OPS.list, { ...targetParams(target), ...params }));
      if (generation === this.generation && target.cwd === this.state.target?.cwd)
        this.state = { ...this.state, list: result };
      return result;
    } catch (error) {
      const parsed = requestError(error);
      if (generation === this.generation) this.state = { ...this.state, error: parsed };
      throw parsed;
    } finally {
      if (generation === this.generation) {
        this.state = { ...this.state, busy: undefined };
        this.changed();
      }
    }
  }
  async get(params: { checkpoint_id?: string; idempotency_key?: string }): Promise<Checkpoint> {
    if ((params.checkpoint_id === undefined) === (params.idempotency_key === undefined))
      throw new CheckpointRpcError("validation.invalid", "Use exactly one checkpoint lookup.");
    const target = this.requireReady();
    return checkpointRecord(await this.call(CHECKPOINT_OPS.get, { ...targetParams(target), ...params }));
  }
  private mutationStorageKey(
    operation: MutationOperation,
    target: CheckpointTarget,
    body: Record<string, unknown>,
  ): string {
    return `cmux.checkpoint.mutation:${operation}:${stable({ target, body })}`;
  }
  private async mutationKey(
    operation: MutationOperation,
    target: CheckpointTarget,
    body: Record<string, unknown>,
  ): Promise<{ storageKey: string; record: StoredMutation }> {
    const storageKey = this.mutationStorageKey(operation, target, body);
    const stored = await this.persistence.get(storageKey);
    if (stored && typeof stored === "object" && typeof (stored as StoredMutation).idempotency_key === "string")
      return { storageKey, record: stored as StoredMutation };
    const record = { idempotency_key: this.key(), attempted: false };
    await this.persistence.set(storageKey, record);
    return { storageKey, record };
  }
  private async reconcile(
    operation: MutationOperation,
    target: CheckpointTarget,
    body: Record<string, unknown>,
    key: string,
  ): Promise<MutationEnvelope<Checkpoint> | undefined> {
    try {
      const lookup = operation === "create" ? { idempotency_key: key } : { checkpoint_id: String(body.checkpoint_id) };
      const found = checkpointRecord(await this.call(CHECKPOINT_OPS.get, { ...targetParams(target), ...lookup }));
      if (operation === "create") return { result: found, revision: found.revision, replayed: true };
    } catch (error) {
      if (!isNotFound(error)) throw requestError(error);
    }
    return undefined;
  }
  private async mutate(
    operation: MutationOperation,
    body: Record<string, unknown>,
    busy: CheckpointClientState["busy"],
  ): Promise<MutationEnvelope<Checkpoint>> {
    const target = this.requireReady(true);
    const generation = this.generation;
    const { storageKey, record } = await this.mutationKey(operation, target, body);
    if (record.attempted) {
      const reconciled = await this.reconcile(operation, target, body, record.idempotency_key);
      if (reconciled) {
        await this.persistence.delete(storageKey);
        if (generation === this.generation) this.state = { ...this.state, record: reconciled.result };
        return reconciled;
      }
    }
    const params = { ...targetParams(target), ...body, idempotency_key: record.idempotency_key };
    await this.persistence.set(storageKey, { ...record, attempted: true });
    this.state = { ...this.state, busy, error: undefined };
    this.changed();
    try {
      const result = mutationEnvelope<Checkpoint>(await this.call(CHECKPOINT_OPS[operation], params));
      await this.persistence.delete(storageKey);
      if (generation === this.generation) this.state = { ...this.state, record: checkpointRecord(result.result) };
      return { ...result, result: checkpointRecord(result.result) };
    } catch (error) {
      const parsed = requestError(error);
      if (!parsed.uncertain) await this.persistence.delete(storageKey);
      if (generation === this.generation) this.state = { ...this.state, error: parsed };
      throw parsed;
    } finally {
      if (generation === this.generation) {
        this.state = { ...this.state, busy: undefined };
        this.changed();
      }
    }
  }
  async create(input: CreateInput = {}): Promise<MutationEnvelope<Checkpoint>> {
    const body: Record<string, unknown> = { ...input };
    if (body.include_untracked === undefined) body.include_untracked = [];
    return this.mutate("create", body, "creating");
  }
  async pin(input: PinInput): Promise<MutationEnvelope<Checkpoint>> {
    return this.mutate("pin", input as Record<string, unknown>, "pinning");
  }
  async unpin(input: UnpinInput): Promise<MutationEnvelope<Checkpoint>> {
    if (input.pin_id.startsWith("handoff:") || input.pin_id.startsWith("restore:"))
      throw new CheckpointRpcError(
        {
          code: "operation.failed",
          userMessage: "Managed checkpoint pins cannot be removed.",
          details: { reason: "managed_pin" },
        },
        undefined,
        "managed_pin",
      );
    return this.mutate("unpin", input as Record<string, unknown>, "unpinning");
  }
}
