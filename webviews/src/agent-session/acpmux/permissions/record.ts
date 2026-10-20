// What became of a single permission card (an ask outside the grouped panel, PermissionCard.tsx),
// read back from acpmux's `permission_decision` record: the transcript keeps a one-line receipt
// once the card goes (direct.ts, the `permissionRecord` row), so a reload shows it again. The
// grouped panel keeps its own receipt (permissions/Panel.tsx).
import type { AcpmuxPermission } from "../model";

/// The transcript row of a single permission card's answer.
export const PERMISSION_RECORD = "permissionRecord";

export type PermissionDecision = "allowed" | "allowedAlways" | "denied" | "cancelled";

/// How `outcome` answered `permission`: by the chosen option's ACP kind, else (an older agent
/// without kinds) its id and name, as PermissionCard.tsx `permissionOptionKind` reads them.
export function permissionDecision(permission: AcpmuxPermission, outcome: unknown): PermissionDecision {
  const value = outcome as { outcome?: unknown; optionId?: unknown } | undefined;
  if (value?.outcome !== "selected" || typeof value.optionId !== "string") return "cancelled";
  const option = permission.options.find((candidate) => candidate.id === value.optionId);
  const kind = option?.kind?.toLowerCase();
  if (kind?.startsWith("reject")) return "denied";
  if (kind === "allow_once") return "allowed";
  if (kind?.startsWith("allow")) return "allowedAlways";
  const named = `${value.optionId} ${option?.name ?? ""}`.toLowerCase();
  if (/deny|reject|decline/.test(named)) return "denied";
  if (/always|forever|permanent|chat|session/.test(named)) return "allowedAlways";
  return "allowed";
}

/// The receipt's words for each decision, `{action}` the ask's title.
export const DECISION_TEXT = {
  allowed: "permission.receipt.allowed",
  allowedAlways: "permission.receipt.allowedAlways",
  denied: "permission.receipt.denied",
  cancelled: "permission.receipt.cancelled",
} as const satisfies Record<PermissionDecision, string>;
