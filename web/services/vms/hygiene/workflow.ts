import * as Effect from "effect/Effect";
import { VmNotFoundError } from "../errors";
import { VmProviderGateway } from "../providerGateway";
import { requireUserVm } from "../workflows";
import { machineHygieneCommand } from "./command";

/** Long enough for du over a large home; the route's maxDuration covers it. */
export const MACHINE_HYGIENE_TIMEOUT_MS = 180_000;
/** cmux-machine-hygiene's exit code when another --apply run holds its lock. */
export const MACHINE_HYGIENE_BUSY_EXIT = 4;

export type MachineHygieneItem = {
  readonly category: string;
  readonly path: string;
  readonly kb: number;
  readonly action: "would-delete" | "deleted" | "skipped";
  readonly reason?: string;
};

export type MachineHygieneReport = {
  readonly version: 1;
  readonly mode: "dry-run" | "apply";
  readonly home: string;
  readonly diskUsedPctBefore: number | null;
  readonly diskUsedPctAfter: number | null;
  readonly reclaimableKb: number;
  readonly items: readonly MachineHygieneItem[];
};

export type MachineHygieneOutcome =
  | { readonly kind: "report"; readonly report: MachineHygieneReport }
  /** Cleanup never wakes a machine; the caller resumes it first. */
  | { readonly kind: "not-running"; readonly status: string }
  /** Another --apply run on this machine holds the script's lock. */
  | { readonly kind: "busy" }
  | { readonly kind: "failed"; readonly exitCode: number; readonly detail: string };

const ACTIONS = new Set(["would-delete", "deleted", "skipped"]);

function isItem(value: unknown): value is MachineHygieneItem {
  if (!value || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return typeof item.category === "string" && typeof item.path === "string" && typeof item.kb === "number" &&
    typeof item.action === "string" && ACTIONS.has(item.action) &&
    (item.reason === undefined || typeof item.reason === "string");
}

const nullableNumber = (value: unknown) => value === null || typeof value === "number";

/**
 * The script's JSON report, or null when stdout is not a version-1 report in
 * the expected mode. A dry-run request that comes back in apply mode, or
 * carries a deleted item, is rejected rather than reported.
 */
export function parseMachineHygieneReport(stdout: string, expectedMode: "dry-run" | "apply"): MachineHygieneReport | null {
  const line = stdout.trim().split("\n").pop() ?? "";
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  const report = parsed as Record<string, unknown>;
  if (report.version !== 1 || report.mode !== expectedMode || typeof report.home !== "string") return null;
  if (typeof report.reclaimableKb !== "number" || !Array.isArray(report.items) || !report.items.every(isItem)) return null;
  if (!nullableNumber(report.diskUsedPctBefore) || !nullableNumber(report.diskUsedPctAfter)) return null;
  if (expectedMode === "dry-run" && report.items.some((item) => (item as MachineHygieneItem).action === "deleted")) return null;
  return report as unknown as MachineHygieneReport;
}

/**
 * Runs cmux-machine-hygiene on one of the caller's own machines through exec.
 * Dry-run unless `apply` is true. Only the machine's owner may run it, and
 * only on a running machine: a paused one answers `not-running` without
 * being woken.
 */
export function runMachineHygiene(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly apply: boolean;
}) {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    // Team access is not enough: cleanup deletes files, so only the owner.
    if (vm.userId !== input.userId) return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    if (vm.status !== "running") return { kind: "not-running", status: vm.status } satisfies MachineHygieneOutcome;
    if (providers.getStatus) {
      const live = yield* providers.getStatus(vm.provider, input.providerVmId);
      if (live !== "running") return { kind: "not-running", status: live } satisfies MachineHygieneOutcome;
    }
    const result = yield* providers.exec(vm.provider, input.providerVmId, machineHygieneCommand({ apply: input.apply }), {
      timeoutMs: MACHINE_HYGIENE_TIMEOUT_MS,
      providerMetadata: vm.providerMetadata,
    });
    if (result.exitCode === MACHINE_HYGIENE_BUSY_EXIT) return { kind: "busy" } satisfies MachineHygieneOutcome;
    const report = result.exitCode === 0
      ? parseMachineHygieneReport(result.stdout, input.apply ? "apply" : "dry-run")
      : null;
    if (!report) {
      return { kind: "failed", exitCode: result.exitCode, detail: result.stderr.trim().slice(-500) } satisfies MachineHygieneOutcome;
    }
    return { kind: "report", report } satisfies MachineHygieneOutcome;
  });
}

/**
 * The request body: `apply` is absent, false, or exactly true. Anything else
 * (a string "true", a number) is refused, so apply can only be an explicit,
 * separate action.
 */
export function parseMachineHygieneRequest(body: unknown): { readonly apply: boolean } | null {
  if (body === undefined || body === null) return { apply: false };
  if (typeof body !== "object" || Array.isArray(body)) return null;
  const apply = (body as { apply?: unknown }).apply;
  if (apply === undefined || apply === false) return { apply: false };
  return apply === true ? { apply: true } : null;
}
