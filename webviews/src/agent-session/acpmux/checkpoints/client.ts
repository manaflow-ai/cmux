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
  busy?: "listing" | "creating" | "pinning" | "unpinning" | "recovering";
  pending?: StoredMutation;
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

type StoredMutation = { idempotency_key: string; attempted: boolean; operation: MutationOperation; body: Record<string, unknown> };
type MutationOperation = "create" | "pin" | "unpin";
const defaultPersistence: CheckpointPersistence = {
  async get(key) {
    const value = globalThis.localStorage?.getItem(key);
    return value === null || value === undefined ? undefined : JSON.parse(value);
  },
  async set(key, value) {
    if (!globalThis.localStorage) throw new CheckpointRpcError({code: "native.invalid_request", origin: "native"});
    globalThis.localStorage.setItem(key, JSON.stringify(value));
  },
  async delete(key) {
    globalThis.localStorage?.removeItem(key);
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
  state: CheckpointClientState = { supported: false };
  private request: Request;
  private persistence: CheckpointPersistence;
  private key: () => string;
  private capabilityReader: CapabilityReader;
  private online = true;
  private generation = 0;
  private mutationActive = false;
  private capabilityGeneration = 0;
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
    this.capabilityReader = capabilities ?? options?.capabilities ?? (async () => ({ checkpoints: false }));
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
  beginReview(): boolean {
    if (this.mutationActive || this.state.busy) return false;
    this.state = { ...this.state, record: undefined, list: undefined, error: undefined };
    this.changed();
    return true;
  }
  async refreshCapabilities(): Promise<boolean> {
    const generation = ++this.capabilityGeneration;
    try {
      const capabilities = await this.capabilityReader();
      if (generation !== this.capabilityGeneration) return this.state.supported;
      this.state = {
        ...this.state,
        capabilities,
        supported: supportsCheckpointCapability(capabilities),
        error: undefined,
      };
      this.changed();
      return this.state.supported;
    } catch (error) {
      if (generation !== this.capabilityGeneration) return this.state.supported;
      this.state = { ...this.state, supported: false, error: requestError(error) };
      this.changed();
      return false;
    }
  }
  setOnline(online: boolean): void {
    this.online = online;
    if (!online) {
      this.capabilityGeneration++;
      this.state = { ...this.state, supported: false };
    }
    this.changed();
  }
  private requireReady(): CheckpointTarget {
    if (!this.online)
      throw new CheckpointRpcError(
        {
          code: "operation.failed",
          userMessage: "Checkpoint capture is unavailable while offline.",
          details: { reason: "offline" },
        },
        undefined,
        "offline",
      );
    if (!this.state.supported)
      throw new CheckpointRpcError("operation.unsupported", "Checkpoint capture is unavailable.");
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
  private mutationStorageKey(target: CheckpointTarget): string {
    return `cmux.checkpoint.pending:${stable(target)}`;
  }
  private async mutationKey(
    operation: MutationOperation, target: CheckpointTarget, body: Record<string, unknown>,
  ): Promise<{ storageKey: string; record: StoredMutation }> {
    const storageKey = this.mutationStorageKey(target);
    const stored = await this.persistence.get(storageKey);
    if (stored && typeof stored === "object" && typeof (stored as StoredMutation).idempotency_key === "string") {
      const record = stored as StoredMutation;
      if (record.operation !== operation || stable(record.body) !== stable(body))
        throw new CheckpointRpcError({ code: "idempotency.conflict", origin: "native" });
      return { storageKey, record };
    }
    const record = { idempotency_key: this.key(), attempted: false, operation, body };
    await this.persistence.set(storageKey, record);
    return { storageKey, record };
  }
  /** Opening the review only reads the saved intent. Retry is an explicit user action. */
  async recoverPending(): Promise<void> {
    const target = this.requireReady();
    const generation = this.generation;
    const value = await this.persistence.get(this.mutationStorageKey(target));
    if (generation !== this.generation || !value || typeof value !== "object") return;
    const pending = value as StoredMutation;
    if (!pending.body || typeof pending.idempotency_key !== "string" || !["create", "pin", "unpin"].includes(pending.operation)) return;
    this.state = { ...this.state, pending, busy: "recovering", error: undefined };
    this.changed();
    try {
      const result = pending.attempted
        ? await this.reconcile(pending.operation, target, pending.body, pending.idempotency_key)
        : undefined;
      if (result) {
        await this.persistence.delete(this.mutationStorageKey(target));
        if (generation === this.generation) this.state = { ...this.state, pending: undefined, record: result.result };
      }
    } catch (error) {
      if (generation === this.generation) this.state = { ...this.state, error: requestError(error) };
      throw error;
    } finally {
      if (generation === this.generation) { this.state = { ...this.state, busy: undefined }; this.changed(); }
    }
  }
  async retry(): Promise<MutationEnvelope<Checkpoint>> {
    const pending = this.state.pending;
    if (!pending) throw new CheckpointRpcError({code: "validation.invalid", origin: "native"});
    return this.mutate(pending.operation, pending.body, pending.operation === "create" ? "creating" : pending.operation === "pin" ? "pinning" : "unpinning");
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
    operation: MutationOperation, body: Record<string, unknown>, busy: CheckpointClientState["busy"],
  ): Promise<MutationEnvelope<Checkpoint>> {
    const target = this.requireReady();
    if (this.mutationActive || this.state.busy)
      throw new CheckpointRpcError({code: "operation.failed", origin: "native", details: {reason: "repository_busy"}});
    this.mutationActive = true;
    const generation = this.generation;
    this.state = { ...this.state, busy, error: undefined };
    this.changed();
    let storageKey: string | undefined;
    try {
      const saved = await this.mutationKey(operation, target, body);
      storageKey = saved.storageKey;
      const record = saved.record;
      if (generation !== this.generation || !this.online) throw new CheckpointRpcError({code: "native.not_connected", origin: "native"});
      this.state = { ...this.state, pending: record };
      if (record.attempted) {
        const reconciled = await this.reconcile(operation, target, body, record.idempotency_key);
        if (reconciled) {
          await this.persistence.delete(storageKey);
          if (generation === this.generation) this.state = { ...this.state, record: reconciled.result, pending: undefined };
          return reconciled;
        }
      }
      const params = { ...targetParams(target), ...body, idempotency_key: record.idempotency_key };
      await this.persistence.set(storageKey, { ...record, attempted: true });
      if (generation !== this.generation || !this.online) throw new CheckpointRpcError({code: "native.not_connected", origin: "native"});
      const result = mutationEnvelope<Checkpoint>(await this.call(CHECKPOINT_OPS[operation], params));
      const parsedRecord = checkpointRecord(result.result);
      await this.persistence.delete(storageKey);
      if (generation === this.generation) this.state = { ...this.state, record: parsedRecord, pending: undefined };
      return { ...result, result: parsedRecord };
    } catch (error) {
      const parsed = requestError(error);
      if (!parsed.uncertain && storageKey) await this.persistence.delete(storageKey);
      if (generation === this.generation) this.state = { ...this.state, error: parsed, pending: parsed.uncertain ? this.state.pending : undefined };
      throw parsed;
    } finally {
      this.mutationActive = false;
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
