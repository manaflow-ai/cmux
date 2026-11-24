// The rows a VM's size shows in the chat (cmuxterm-hq RFD 0133, items 1, 2 and 9), as acpmux sends
// them (cmux-tui/crates/acpmux/src/resize_row.rs decides every button, size, plan and rate). These
// are its JSON shapes; the pane only draws them (ResizeRow.tsx).

export type Size = { vcpu: number; memGiB: number };
export type Plan = "plus" | "pro" | "max";

export type First =
  | { kind: "resize"; to: Size; hourlyCents: number }
  | { kind: "upgrade"; plan: Plan; to: Size; hourlyCents: number };

export type Why =
  | {
      kind: "project";
      project: "chromium" | "llvm" | "rustc";
      command: string;
      short: ("disk" | "memory")[];
      needsDiskGb: number;
      needsMemoryGb: number | null;
      diskFreeGb: number;
      memoryGb: number;
      hoursHere?: number;
      hoursBurst?: number;
      burstCents?: number;
      burstVcpu?: number;
    }
  | { kind: "bigCheckout"; command: string; checkoutGib: number; memoryFreeGib: number }
  | { kind: "pressure"; memUsedGib: number; memTotalGib: number; busyMinutes: number | null };

export type WarningRow = { why: Why; now: Size; first: First; backTo: Size };

export type AutoSizeRow = {
  act: "grew" | "shrank" | "heldAtPlanLimit";
  reason: "memory" | "cpu" | "disk" | "oomKill" | "idle";
  from: Size;
  to: Size;
  hourlyCents: number;
  upgrade?: First;
  undoAtPause: boolean;
};

/// What a click asks for: the resize route, a plan upgrade, `cmux vm run --sync`, a mute for the
/// job, or the shrink back at the next pause.
export type ResizeAction =
  | { kind: "resize"; to: Size }
  | { kind: "upgrade"; plan: Plan }
  | { kind: "buildMachine" }
  | { kind: "carryOn" }
  | { kind: "undoAtPause"; to: Size };

export const PLAN_NAMES: Record<Plan, string> = { plus: "Plus", pro: "Pro", max: "Max" };
export const PROJECT_NAMES: Record<"chromium" | "llvm" | "rustc", string> = {
  chromium: "Chromium",
  llvm: "LLVM",
  rustc: "rustc",
};

export function isWarning(row: WarningRow | AutoSizeRow): row is WarningRow {
  return "why" in row;
}
