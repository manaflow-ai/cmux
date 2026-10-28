// What became of a single permission card (an ask outside the grouped panel, PermissionCard.tsx),
// read back from acpmux's `permission_decision` record: the transcript keeps a one-line receipt
// once the card goes (direct.ts, the `permissionRecord` row), so a reload shows it again. The
// grouped panel keeps its own receipt (permissions/Panel.tsx). An ask a chat in Full access answered
// unasked (acpmux's `permission_auto` with `fullAccess`) leaves the same line: "Approved: … (Full
// access)".
import type { AcpmuxPermission } from "../model";
import { permissionOptionKind } from "./prompt";

/// The transcript row of a single permission card's answer.
export const PERMISSION_RECORD = "permissionRecord";

/// How an ask was answered. `answered` is an option neither its ACP kind nor its name places (a
/// custom choice, or one the ask no longer lists): the receipt names it rather than guess.
export type PermissionDecision =
  | { kind: "allowed" | "allowedAlways" | "denied" | "cancelled" | "fullAccess" }
  | { kind: "answered"; option: string };

/// How `outcome` answered `permission`, read as the card reads its options (`permissionOptionKind`).
export function permissionDecision(permission: AcpmuxPermission, outcome: unknown): PermissionDecision {
  const value = outcome as { outcome?: unknown; optionId?: unknown } | undefined;
  if (value?.outcome !== "selected" || typeof value.optionId !== "string") return { kind: "cancelled" };
  const option = permission.options.find((candidate) => candidate.id === value.optionId);
  switch (option && permissionOptionKind(option)) {
    case "allow_once":
      return { kind: "allowed" };
    case "allow_always":
    case "allow_chat":
      return { kind: "allowedAlways" };
    case "deny":
      return { kind: "denied" };
    default:
      return { kind: "answered", option: option?.name.trim() || value.optionId };
  }
}

/// The receipt's words for each decision: `{action}` the ask's title, `{option}` the option named.
export const DECISION_TEXT = {
  allowed: "permission.receipt.allowed",
  allowedAlways: "permission.receipt.allowedAlways",
  denied: "permission.receipt.denied",
  cancelled: "permission.receipt.cancelled",
  answered: "permission.receipt.answered",
  fullAccess: "permission.receipt.fullAccess",
} as const satisfies Record<PermissionDecision["kind"], string>;
