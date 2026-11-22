import { type StringKey, translate } from "../i18n";
import { servesOperation } from "../operations";

export const PERMISSION_GROUP_OPS = {
  groups: "_acpmux/permission_groups",
  respond: "_acpmux/permission_group_respond",
  revoke: "_acpmux/permission_chat_revoke",
} as const;

export type PermissionDecision = "allow_once" | "allow_chat" | "deny";
export type PermissionGroupState = "collecting" | "pending" | "resolved" | "cancelled";
export type PermissionItemState = "pending" | "resolved" | "cancelled";

export type PermissionGroupItem = {
  permissionId: string;
  request: Record<string, unknown>;
  state: PermissionItemState;
};

export type PermissionGroup = {
  groupId: string;
  sessionId: string;
  turnId: string | null;
  revision: number;
  state: PermissionGroupState;
  items: PermissionGroupItem[];
  decisions: PermissionDecision[];
  decision: PermissionDecision | null;
};

export type PermissionCoverage = {
  label: "acp_requests_only";
  isolation: "unverified";
  detail: string;
};

export type PermissionGroupList = {
  groups: PermissionGroup[];
  chatAllowance: { active: boolean; expires: "session_stop_or_daemon_restart" };
  coverage: PermissionCoverage;
  batching: {
    windowMs: number;
    maxItems: number;
    maxPendingGroups: number;
    maxReceipts: number;
  };
};

export type PermissionGroupReceipt = { group: PermissionGroup; replayed: boolean };
export type PermissionChatRevokeReceipt = { active: false };
export type PermissionClientState = {
  supported: boolean;
  ready: boolean;
  groups: PermissionGroup[];
  chatAllowance: boolean;
  loading: boolean;
  busy: boolean;
  error?: string;
  uncertain?: boolean;
};

export function supportsPermissionGroups(initialized: unknown): boolean {
  return Object.values(PERMISSION_GROUP_OPS).every((operation) => servesOperation(initialized, operation));
}

function record(value: unknown, message: StringKey = "error.invalid.permissionResponse"): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(translate(message));
  return value as Record<string, unknown>;
}

function nonemptyText(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(translate("error.invalid.permissionField", { field }));
  return value;
}

function integer(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)
    throw new Error(translate("error.invalid.permissionField", { field }));
  return value;
}

function decision(value: unknown): PermissionDecision {
  if (value !== "allow_once" && value !== "allow_chat" && value !== "deny")
    throw new Error(translate("error.invalid.permissionDecision"));
  return value;
}

function uniqueDecisions(value: unknown): PermissionDecision[] {
  if (!Array.isArray(value)) throw new Error(translate("error.invalid.permissionDecisions"));
  const choices = value.map(decision);
  if (new Set(choices).size !== choices.length) throw new Error(translate("error.invalid.permissionDecisions"));
  return choices;
}

function group(value: unknown): PermissionGroup {
  const raw = record(value);
  const state = raw.state;
  if (!(["collecting", "pending", "resolved", "cancelled"] as const).includes(state as PermissionGroupState))
    throw new Error(translate("error.invalid.permissionGroupState"));
  if (!Array.isArray(raw.items)) throw new Error(translate("error.invalid.permissionGroupItems"));
  const items = raw.items.map((entry) => {
    const item = record(entry, "error.invalid.permissionItem");
    const itemState = item.state;
    if (!(["pending", "resolved", "cancelled"] as const).includes(itemState as PermissionItemState))
      throw new Error(translate("error.invalid.permissionItemState"));
    return {
      permissionId: nonemptyText(item.permissionId, "permission id"),
      request: record(item.request, "error.invalid.permissionRequest"),
      state: itemState as PermissionItemState,
    };
  });
  const selected = raw.decision === null ? null : decision(raw.decision);
  return {
    groupId: nonemptyText(raw.groupId, "group id"),
    sessionId: nonemptyText(raw.sessionId, "session id"),
    turnId: raw.turnId === null ? null : nonemptyText(raw.turnId, "turn id"),
    revision: integer(raw.revision, "revision"),
    state: state as PermissionGroupState,
    items,
    decisions: uniqueDecisions(raw.decisions),
    decision: selected,
  };
}

export function permissionGroup(value: unknown): PermissionGroup {
  return group(value);
}

export function permissionGroups(value: unknown): PermissionGroupList {
  const raw = record(value);
  if (!Array.isArray(raw.groups)) throw new Error(translate("error.invalid.permissionGroups"));
  const allowance = record(raw.chatAllowance, "error.invalid.permissionAllowance");
  if (typeof allowance.active !== "boolean" || allowance.expires !== "session_stop_or_daemon_restart")
    throw new Error(translate("error.invalid.permissionAllowance"));
  const coverage = record(raw.coverage, "error.invalid.permissionCoverage");
  if (
    coverage.label !== "acp_requests_only" ||
    coverage.isolation !== "unverified" ||
    typeof coverage.detail !== "string"
  )
    throw new Error(translate("error.invalid.permissionCoverage"));
  const batching = record(raw.batching, "error.invalid.permissionBatching");
  return {
    groups: raw.groups.map(group),
    chatAllowance: { active: allowance.active, expires: allowance.expires },
    coverage: { label: coverage.label, isolation: coverage.isolation, detail: coverage.detail },
    batching: {
      windowMs: integer(batching.windowMs, "batching"),
      maxItems: integer(batching.maxItems, "batching"),
      maxPendingGroups: integer(batching.maxPendingGroups, "batching"),
      maxReceipts: integer(batching.maxReceipts, "batching"),
    },
  };
}

export function permissionGroupReceipt(value: unknown): PermissionGroupReceipt {
  const raw = record(value);
  if (typeof raw.replayed !== "boolean") throw new Error(translate("error.invalid.permissionReceipt"));
  return { group: group(raw.group), replayed: raw.replayed };
}

export function permissionChatRevokeReceipt(value: unknown): PermissionChatRevokeReceipt {
  const raw = record(value);
  if (raw.active !== false) throw new Error(translate("error.invalid.permissionRevokeReceipt"));
  return { active: false };
}

export type PermissionErrorInput = {
  code?: unknown;
  message?: unknown;
  userMessage?: unknown;
  data?: unknown;
  details?: unknown;
  retryable?: unknown;
  origin?: unknown;
};

export class PermissionRpcError extends Error {
  readonly code: string;
  readonly reason?: string;
  readonly details?: unknown;
  readonly retryable?: boolean;
  readonly origin?: "native" | "session_host";
  readonly uncertain: boolean;
  readonly group?: PermissionGroup;

  constructor(input: PermissionErrorInput | string, fallbackMessage?: string) {
    const raw: PermissionErrorInput = typeof input === "string" ? { code: input, message: fallbackMessage } : input;
    const data = raw.data && typeof raw.data === "object" ? (raw.data as Record<string, unknown>) : undefined;
    const details = raw.details ?? data?.details;
    const reason =
      (data && typeof data.reason === "string" && data.reason) ||
      (details && typeof details === "object" && typeof (details as { reason?: unknown }).reason === "string"
        ? (details as { reason: string }).reason
        : undefined);
    super(
      typeof raw.userMessage === "string"
        ? raw.userMessage
        : typeof raw.message === "string"
          ? raw.message
          : typeof data?.message === "string"
            ? data.message
            : translate("error.permissionFailed"),
    );
    this.name = "PermissionRpcError";
    this.code =
      typeof raw.code === "string" ? raw.code : typeof raw.code === "number" ? String(raw.code) : "operation.failed";
    this.reason = reason;
    this.details = details;
    this.retryable = typeof raw.retryable === "boolean" ? raw.retryable : undefined;
    this.origin = raw.origin === "native" || raw.origin === "session_host" ? raw.origin : undefined;
    this.uncertain =
      this.code === "mutation.indeterminate" || (this.origin === "native" && this.code === "native.timed_out");
    if (data?.group !== undefined) {
      try {
        this.group = permissionGroup(data.group);
      } catch {
        /* A malformed recovery snapshot is never trusted. */
      }
    }
  }
}
