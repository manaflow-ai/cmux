import {
  PERMISSION_GROUP_OPS,
  PermissionRpcError,
  permissionChatRevokeReceipt,
  permissionGroupReceipt,
  permissionGroups,
  type PermissionDecision,
  type PermissionClientState,
  type PermissionGroupList,
} from "./protocol";

export type Request = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export interface PermissionStorage {
  get(key: string): unknown | Promise<unknown>;
  set(key: string, value: unknown): void | Promise<void>;
  delete(key: string): void | Promise<void>;
}

export type { PermissionClientState } from "./protocol";

type PendingDecision = {
  sessionId: string;
  groupId: string;
  revision: number;
  decisionKey: string;
  decision: PermissionDecision;
};

const memoryStorage = new Map<string, unknown>();
const defaultStorage: PermissionStorage = {
  get(key) {
    try {
      const value = globalThis.sessionStorage?.getItem(key);
      return value === null || value === undefined ? memoryStorage.get(key) : JSON.parse(value);
    } catch {
      return memoryStorage.get(key);
    }
  },
  set(key, value) {
    memoryStorage.set(key, value);
    try {
      globalThis.sessionStorage?.setItem(key, JSON.stringify(value));
    } catch {
      // Private browsing and test environments may not provide writable sessionStorage.
    }
  },
  delete(key) {
    memoryStorage.delete(key);
    try {
      globalThis.sessionStorage?.removeItem(key);
    } catch {
      // There is no durable receipt to remove when sessionStorage is unavailable.
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

function key(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }
}

function asError(error: unknown): PermissionRpcError {
  if (error instanceof PermissionRpcError) return error;
  if (error && typeof error === "object") {
    const raw = error as Record<string, unknown>;
    return new PermissionRpcError({
      code: raw.code,
      message: raw.message,
      userMessage: raw.userMessage,
      data: raw.data,
      details: raw.details,
      retryable: raw.retryable,
      origin: raw.origin,
    });
  }
  return new PermissionRpcError({
    code: "operation.failed",
    message: error instanceof Error ? error.message : "Permission request failed",
  });
}

function localError(code: string, message: string, reason?: string): PermissionRpcError {
  return new PermissionRpcError({ code, message, data: reason ? { reason } : undefined });
}

function isPendingDecision(value: unknown): value is PendingDecision {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Record<string, unknown>;
  return (
    typeof item.sessionId === "string" &&
    typeof item.groupId === "string" &&
    typeof item.revision === "number" &&
    Number.isSafeInteger(item.revision) &&
    item.revision >= 0 &&
    typeof item.decisionKey === "string" &&
    (item.decision === "allow_once" || item.decision === "allow_chat" || item.decision === "deny")
  );
}

/** Client-side projection for daemon-owned grouped permission asks. */
export class PermissionGroupClient {
  state: PermissionClientState = {
    supported: false,
    ready: false,
    groups: [],
    chatAllowance: false,
    loading: false,
    busy: false,
  };

  private readonly request: Request;
  private readonly changed: () => void;
  private readonly storage: PermissionStorage;
  private sessionId?: string;
  private generation = 0;
  private refreshSerial = 0;
  private authoritative = false;
  private pendingRevoke = false;
  private mutationInFlight = false;

  constructor(request: Request, changed: () => void, storage: PermissionStorage = defaultStorage) {
    this.request = request;
    this.changed = changed;
    this.storage = storage;
  }

  configure(supported: boolean): void {
    this.state = {
      supported,
      ready: false,
      groups: supported ? this.state.groups : [],
      chatAllowance: supported ? this.state.chatAllowance : false,
      loading: false,
      busy: false,
      error: undefined,
      uncertain: supported ? this.state.uncertain : undefined,
    };
    this.authoritative = false;
    this.refreshSerial += 1;
    this.changed();
  }

  select(sessionId?: string): void {
    if (sessionId === this.sessionId) return;
    this.generation += 1;
    this.refreshSerial += 1;
    this.sessionId = sessionId;
    this.authoritative = false;
    this.pendingRevoke = false;
    this.state = {
      supported: this.state.supported,
      ready: false,
      groups: [],
      chatAllowance: false,
      loading: false,
      busy: false,
      error: undefined,
      uncertain: undefined,
    };
    this.changed();
  }

  private session(): string {
    if (!this.state.supported) throw localError("operation.unsupported", "Grouped permissions are unavailable.");
    if (!this.sessionId) throw localError("validation.invalid", "Select a session first.");
    return this.sessionId;
  }

  private storageKey(sessionId: string): string {
    return `cmux.permission.group:${sessionId}`;
  }

  private async savedPending(sessionId: string): Promise<PendingDecision | undefined> {
    const value = await this.storage.get(this.storageKey(sessionId));
    return isPendingDecision(value) ? value : undefined;
  }

  private async savePending(pending: PendingDecision): Promise<void> {
    await this.storage.set(this.storageKey(pending.sessionId), pending);
  }

  private async clearPending(sessionId: string): Promise<void> {
    await this.storage.delete(this.storageKey(sessionId));
  }

  private markFailure(error: PermissionRpcError, generation: number): void {
    if (generation !== this.generation) return;
    if (error.code === "operation.unsupported" || error.code === "-32601") {
      this.state.supported = false;
      this.authoritative = false;
    }
    this.state.error = error.message;
    this.state.uncertain = error.uncertain || this.state.uncertain;
    this.changed();
  }

  async refresh(): Promise<void> {
    const sessionId = this.session();
    const generation = this.generation;
    const refreshSerial = ++this.refreshSerial;
    const wasUncertain = this.state.uncertain;
    const wasError = this.state.error;
    this.state = { ...this.state, ready: false, loading: true, error: undefined };
    this.changed();
    try {
      const result: PermissionGroupList = permissionGroups(
        await this.request(PERMISSION_GROUP_OPS.groups, { sessionId }),
      );
      if (generation !== this.generation || refreshSerial !== this.refreshSerial || this.sessionId !== sessionId)
        return;
      this.authoritative = true;
      if (result.groups.some((group) => group.sessionId !== sessionId))
        throw new PermissionRpcError({
          code: "operation.failed",
          message: "The permission server returned a group for another session.",
          data: { reason: "invalid_scope" },
        });
      this.state = {
        ...this.state,
        ready: true,
        groups: result.groups,
        chatAllowance: result.chatAllowance.active,
        uncertain: wasUncertain,
        error: wasUncertain ? wasError : undefined,
      };
      const pending = await this.savedPending(sessionId);
      if (generation !== this.generation || refreshSerial !== this.refreshSerial || this.sessionId !== sessionId)
        return;
      if (
        pending &&
        result.groups.some(
          (group) => group.groupId === pending.groupId && (group.state === "resolved" || group.state === "cancelled"),
        )
      ) {
        await this.clearPending(sessionId);
        this.state = { ...this.state, uncertain: false, error: undefined };
      }
    } catch (error) {
      const parsed = asError(error);
      if (generation === this.generation && refreshSerial === this.refreshSerial) {
        this.authoritative = false;
        this.state = { ...this.state, ready: false };
        this.markFailure(parsed, generation);
      }
      throw parsed;
    } finally {
      if (generation === this.generation && refreshSerial === this.refreshSerial) {
        this.state = { ...this.state, loading: false };
        this.changed();
      }
    }
  }

  private requireAuthoritative(allowMutation = false): string {
    const sessionId = this.session();
    if (!this.authoritative) throw this.notReady();
    if (!allowMutation && (this.state.busy || this.mutationInFlight))
      throw localError("operation.failed", "A permission decision is already being sent.", "busy");
    return sessionId;
  }

  private notReady(): PermissionRpcError {
    const error = localError(
      "operation.failed",
      "Read the current permission groups before answering.",
      "read_required",
    );
    this.state = { ...this.state, error: error.message };
    this.changed();
    return error;
  }

  private selectionChanged(): PermissionRpcError {
    return localError(
      "operation.failed",
      "The selected session changed. Read its permissions before answering.",
      "selection_changed",
    );
  }

  private async sendDecision(pending: PendingDecision, generation: number): Promise<void> {
    this.state = { ...this.state, busy: true, error: undefined };
    this.changed();
    try {
      let rawReceipt: unknown;
      rawReceipt = await this.request(PERMISSION_GROUP_OPS.respond, {
        sessionId: pending.sessionId,
        groupId: pending.groupId,
        revision: pending.revision,
        decisionKey: pending.decisionKey,
        decision: pending.decision,
      });
      let receipt: ReturnType<typeof permissionGroupReceipt>;
      try {
        receipt = permissionGroupReceipt(rawReceipt);
      } catch {
        // The daemon may have committed before a malformed reply reached the page.
        throw new PermissionRpcError({
          code: "mutation.indeterminate",
          message: "The permission answer may have been applied. Read before retrying.",
          origin: "session_host",
        });
      }
      if (receipt.group.sessionId !== pending.sessionId || receipt.group.groupId !== pending.groupId)
        throw new PermissionRpcError({
          code: "mutation.indeterminate",
          message: "The permission answer returned a different group. Read before retrying.",
          origin: "session_host",
        });
      await this.clearPending(pending.sessionId);
      if (generation === this.generation && this.sessionId === pending.sessionId) {
        this.state = {
          ...this.state,
          groups: this.state.groups.map((group) => (group.groupId === receipt.group.groupId ? receipt.group : group)),
          uncertain: false,
          error: undefined,
        };
      }
    } catch (error) {
      const parsed = asError(error);
      if (!parsed.uncertain) await this.clearPending(pending.sessionId);
      this.markFailure(parsed, generation);
      throw parsed;
    } finally {
      if (generation === this.generation) {
        this.state = { ...this.state, busy: false };
        this.changed();
      }
    }
  }

  async respond(groupId: string, revision: number, decision: PermissionDecision): Promise<void> {
    const sessionId = this.requireAuthoritative();
    const generation = this.generation;
    if (!Number.isSafeInteger(revision) || revision < 0)
      throw localError("validation.invalid", "Invalid group revision.");
    const group = this.state.groups.find((candidate) => candidate.groupId === groupId);
    if (!group) throw localError("resource.not_found", "Permission group was not found.");
    if (this.mutationInFlight)
      throw localError("operation.failed", "A permission decision is already being sent.", "busy");
    this.mutationInFlight = true;
    this.state = { ...this.state, busy: true, error: undefined };
    this.changed();
    try {
      const existing = await this.savedPending(sessionId);
      if (generation !== this.generation || sessionId !== this.sessionId) throw this.selectionChanged();
      const body = { sessionId, groupId, revision, decision };
      let pending: PendingDecision;
      if (existing) {
        if (
          existing.sessionId !== sessionId ||
          stable({
            sessionId: existing.sessionId,
            groupId: existing.groupId,
            revision: existing.revision,
            decision: existing.decision,
          }) !== stable(body)
        )
          throw localError("idempotency.conflict", "Another permission decision is awaiting retry.");
        pending = existing;
      } else {
        pending = { ...body, decisionKey: key() };
        await this.savePending(pending);
        if (generation !== this.generation || sessionId !== this.sessionId) throw this.selectionChanged();
      }
      await this.sendDecision(pending, generation);
    } catch (error) {
      const parsed = asError(error);
      if (generation === this.generation && sessionId === this.sessionId) this.markFailure(parsed, generation);
      throw parsed;
    } finally {
      this.mutationInFlight = false;
      if (generation === this.generation && this.state.busy) {
        this.state = { ...this.state, busy: false };
        this.changed();
      }
    }
  }

  async retry(): Promise<void> {
    if (this.mutationInFlight)
      throw localError("operation.failed", "A permission decision is already being sent.", "busy");
    const sessionId = this.session();
    const generation = this.generation;
    this.mutationInFlight = true;
    try {
      const pending = await this.savedPending(sessionId);
      if (generation !== this.generation || sessionId !== this.sessionId) throw this.selectionChanged();
      if (this.pendingRevoke) {
        await this.refresh();
        if (generation !== this.generation || sessionId !== this.sessionId) throw this.selectionChanged();
        await this.sendRevoke(generation, true);
        return;
      }
      if (!pending) throw localError("validation.invalid", "There is no permission decision to retry.");
      await this.refresh();
      if (generation !== this.generation || sessionId !== this.sessionId) throw this.selectionChanged();
      const group = this.state.groups.find((candidate) => candidate.groupId === pending.groupId);
      if (!group) throw localError("resource.not_found", "Permission group was not found.");
      if ((group.state === "resolved" || group.state === "cancelled") && group.revision >= pending.revision) {
        await this.clearPending(sessionId);
        this.state = { ...this.state, uncertain: false, error: undefined };
        this.changed();
        return;
      }
      if (group.revision !== pending.revision) {
        await this.clearPending(sessionId);
        const error = new PermissionRpcError({
          code: "revision.conflict",
          message: "The permission group changed. Review it again before retrying.",
          data: { reason: "stale_revision", group },
        });
        this.state = { ...this.state, uncertain: false, error: error.message };
        this.changed();
        throw error;
      }
      await this.sendDecision(pending, this.generation);
    } finally {
      this.mutationInFlight = false;
      if (generation === this.generation && this.state.busy && !this.state.loading) {
        this.state = { ...this.state, busy: false };
        this.changed();
      }
    }
  }

  private async sendRevoke(generation: number, alreadyLocked = false): Promise<void> {
    const sessionId = this.requireAuthoritative(alreadyLocked);
    if (!alreadyLocked) {
      if (this.mutationInFlight)
        throw localError("operation.failed", "A permission decision is already being sent.", "busy");
      this.mutationInFlight = true;
    }
    this.state = { ...this.state, busy: true, error: undefined };
    this.changed();
    try {
      permissionChatRevokeReceipt(await this.request(PERMISSION_GROUP_OPS.revoke, { sessionId }));
      if (generation === this.generation) {
        this.pendingRevoke = false;
        this.state = { ...this.state, chatAllowance: false, uncertain: false, error: undefined };
      }
    } catch (error) {
      const parsed = asError(error);
      if (generation === this.generation) {
        this.pendingRevoke = parsed.uncertain;
        this.markFailure(parsed, generation);
      }
      throw parsed;
    } finally {
      if (generation === this.generation) {
        this.state = { ...this.state, busy: false };
        this.changed();
      }
      if (!alreadyLocked) this.mutationInFlight = false;
    }
  }

  async revoke(): Promise<void> {
    this.requireAuthoritative();
    await this.sendRevoke(this.generation);
  }

  disconnected(): void {
    this.generation += 1;
    this.refreshSerial += 1;
    this.authoritative = false;
    this.state = {
      ...this.state,
      ready: false,
      loading: true,
      busy: false,
      error: "Permission groups are disconnected. Refresh before answering.",
      uncertain: this.state.uncertain,
    };
    this.changed();
  }
}
