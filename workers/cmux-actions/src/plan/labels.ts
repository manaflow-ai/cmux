/**
 * Maps an evaluated `runs-on` value to a cmux VM size, or marks the job
 * unsupported (macOS, Windows, ARM, unknown labels). See DESIGN.md section 7.
 * Memory assumes 4 GiB per vCPU (experiment-only E4, unconfirmed).
 */

import { isArray, isObject, type Value } from "../expr/value.ts";

export type LabelDecision =
  | { readonly kind: "linux"; readonly label: string; readonly vcpus: number; readonly memoryGiB: number }
  | { readonly kind: "unsupported"; readonly label: string; readonly reason: string };

export const MAX_VCPUS = 32;
const GIB_PER_VCPU = 4;

const linux = (label: string, vcpus: number): LabelDecision => ({
  kind: "linux",
  label,
  vcpus,
  memoryGiB: vcpus * GIB_PER_VCPU,
});

export const resolveLabel = (label: string): LabelDecision => {
  const normalized = label.trim().toLowerCase();
  if (/(^|-)(arm|arm64|aarch64)($|-)/.test(normalized)) {
    return { kind: "unsupported", label, reason: "ARM runners are not supported" };
  }
  if (normalized.includes("macos")) return { kind: "unsupported", label, reason: "macOS runners are not supported" };
  if (normalized.includes("windows")) return { kind: "unsupported", label, reason: "Windows runners are not supported" };
  if (normalized === "ubuntu-latest" || normalized === "ubuntu-24.04") return linux(label, 4);
  const blacksmith = /^blacksmith-(\d+)vcpu-ubuntu-(2404|2204)$/.exec(normalized);
  if (blacksmith !== null) {
    const vcpus = Number(blacksmith[1]);
    if (vcpus > MAX_VCPUS) return { kind: "unsupported", label, reason: `more than ${MAX_VCPUS} vCPUs` };
    return linux(label, vcpus);
  }
  return { kind: "unsupported", label, reason: `unknown runner label '${label}'` };
};

/** `runs-on` may be a label, a list of labels (all must match), or a group mapping. */
export const resolveRunsOn = (runsOn: Value): LabelDecision => {
  if (typeof runsOn === "string") {
    if (runsOn.trim() === "") return { kind: "unsupported", label: "", reason: "runs-on is empty" };
    return resolveLabel(runsOn);
  }
  if (isArray(runsOn)) {
    const labels = runsOn.filter((label): label is string => typeof label === "string");
    if (labels.length === 0) return { kind: "unsupported", label: "", reason: "runs-on has no labels" };
    const decisions = labels.filter((label) => label !== "self-hosted").map(resolveLabel);
    const blocked = decisions.find((decision) => decision.kind === "unsupported");
    if (blocked !== undefined) return blocked;
    return decisions[0] ?? { kind: "unsupported", label: labels.join(","), reason: "only self-hosted" };
  }
  if (isObject(runsOn)) return { kind: "unsupported", label: JSON.stringify(runsOn), reason: "runner groups are not supported" };
  return { kind: "unsupported", label: String(runsOn), reason: "runs-on is not a label" };
};
