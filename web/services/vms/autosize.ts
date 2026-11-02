/**
 * Auto-sizing: a handed-off task gets its machine size from what it needs, so
 * the person never picks a machine type (leo-workspace design/cloud-work-mode.md,
 * "Auto-sizing"). Pure: no I/O, no clock.
 *
 * It is the fleet's sizing model (manaflow-ai/cmuxterm-hq build-fleet), over
 * cloud machine shapes:
 * - A task's need is a grant from a declarative table (TASK_NEEDS), keyed by
 *   what the fleet measured for the same kind of work (ci_step_mem.go memory
 *   grants, ci_step_cpu.go core demands, codex-lane-hosts profiles).
 * - Once the same repo and task kind has measured runs, they replace the
 *   table, by the controller's rules: memory and disk are p95 of the peak plus
 *   a 20% margin, rounded up to whole GiB (ci_step_mem.go); cores are p90 of
 *   the measured busy cores, rounded up (ci_step_cpu.go: the Release compile's
 *   p90 3.26 cores is its 4-core demand).
 * - The machine is the smallest shape that covers every need, from the one
 *   shape ladder (images/sizes.ts) cut to the plan's sizes.
 */
import { VM_IMAGE_SIZES, type VmImageSize } from "./images/sizes";

export const AUTOSIZE_TASK_KINDS = ["chat", "build", "test"] as const;
export type AutosizeTaskKind = (typeof AUTOSIZE_TASK_KINDS)[number];

export const AUTOSIZE_TOOLCHAINS = ["swift", "rust", "node", "unknown"] as const;
export type AutosizeToolchain = (typeof AUTOSIZE_TOOLCHAINS)[number];

/** What a task needs on top of the agent session: memory in MiB and busy cores. */
export type AutosizeNeed = { readonly memoryMb: number; readonly cpus: number; readonly why: string };

const GIB = 1024;

/**
 * The agent session itself (agent, acpmux, the guest's own services). The
 * fleet's light-step grant: lints, pins and webview steps measured under 1 GiB
 * and are granted 2 GiB, on 2 cores (cpubudget ClassDefault "light"). The
 * codex-lane-hosts sample agrees: 3-4 agent lanes used about 2 GiB in all.
 */
export const AUTOSIZE_SESSION_NEED: AutosizeNeed = { memoryMb: 2 * GIB, cpus: 2, why: "fleet light-step grant" };

/**
 * A task's need beyond the session, by kind and toolchain: the fleet's
 * measured grant for the same work. Memory from ci_step_mem.go (p95 of
 * measured peak growth plus 20%), cores from ci_step_cpu.go (measured core
 * use per step: Release compile 4, Rust check 8, Swift suites 6, webview
 * tests 6). A step the fleet has no script for takes its isolated grant, on 8
 * cores (codex-lane-hosts: a build selects e2-standard-8). A chat (agent
 * turns, reads, edits) is light work whatever the repo.
 */
export const TASK_NEEDS: Readonly<Record<Exclude<AutosizeTaskKind, "chat">, Readonly<Record<AutosizeToolchain, AutosizeNeed>>>> = {
  build: {
    swift: { memoryMb: 13 * GIB, cpus: 4, why: "check-release-compile.sh grant" },
    rust: { memoryMb: 15 * GIB, cpus: 8, why: "cmux-tui-rust-check.sh grant" },
    node: { memoryMb: 2 * GIB, cpus: 6, why: "webview tests grant" },
    unknown: { memoryMb: 8 * GIB, cpus: 8, why: "isolated-step grant" },
  },
  test: {
    swift: { memoryMb: 11 * GIB, cpus: 6, why: "package-test-lane.sh grant" },
    rust: { memoryMb: 15 * GIB, cpus: 8, why: "cmux-tui-rust-check.sh grant" },
    node: { memoryMb: 2 * GIB, cpus: 6, why: "webview tests grant" },
    unknown: { memoryMb: 8 * GIB, cpus: 8, why: "isolated-step grant" },
  },
};
export const CHAT_NEED: AutosizeNeed = { memoryMb: 0, cpus: 0, why: "agent turns only" };

/** A repo's toolchain from the file names at its root; the first match wins (a Swift app with a webview is a Swift build). */
export const TOOLCHAIN_MARKERS: readonly { readonly toolchain: Exclude<AutosizeToolchain, "unknown">; readonly files: readonly RegExp[] }[] = [
  { toolchain: "rust", files: [/^Cargo\.toml$/] },
  { toolchain: "swift", files: [/^Package\.swift$/, /\.xcodeproj$/, /\.xcworkspace$/] },
  { toolchain: "node", files: [/^package\.json$/] },
];

/**
 * Disk a checkout needs per MiB of repo: the checkout, its git objects, its
 * dependencies and build output. Not measured yet; a run's measured peak disk
 * replaces it as soon as one exists.
 */
export const DISK_PER_REPO_MB = 4;
/** The fleet's margin over a measured p95 peak (ci_step_mem.go). */
export const MEASURED_MARGIN = 1.2;
/** The newest runs a pick reads; older ones describe an older repo. */
export const MAX_MEASURED_RUNS = 20;

/** One earlier run of the same repo and task kind, as its machine recorded it. */
export type MeasuredRun = {
  /** The shape it ran on (disk when known). */
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly storageMb?: number;
  /** Its peaks; absent when no sample reached the control plane. */
  readonly peakMemoryMb?: number;
  /** Mean busy cores over the run (cores x cpu%). Peaks of a 250 ms sample say little about cores. */
  readonly meanBusyCpus?: number;
  readonly peakDiskMb?: number;
  /** It ran out of memory or disk. The next pick goes above the shape it had on that axis. */
  readonly ranShort?: "memory" | "disk";
};

export type AutosizeInput = {
  readonly taskKind: AutosizeTaskKind;
  readonly repo?: { readonly key?: string; readonly sizeMb?: number; readonly rootFiles?: readonly string[] };
  readonly gpu?: boolean;
  /** Newest first. */
  readonly measuredRuns?: readonly MeasuredRun[];
  /** The memory sizes the plan may create (entitlements memoryOptionsMbForPlan). */
  readonly planMemoryOptionsMb: readonly number[];
};

export type AutosizePick = {
  readonly ok: true;
  readonly size: VmImageSize;
  /** The hand-off's size fields (backend handoffs: size {vcpus, memoryGb, pick, reason}). */
  readonly vcpus: number;
  readonly memoryGb: number;
  readonly pick: string;
  readonly reason: string;
  /** No shape the plan allows covers the need; the largest it allows was picked. */
  readonly capped: boolean;
};
export type AutosizeRefusal = { readonly ok: false; readonly code: "gpu_unavailable" | "no_plan_sizes"; readonly message: string };

export const shapeLabel = (size: Pick<VmImageSize, "cpu" | "memoryMb">) => `${size.cpu} vCPU · ${Math.round(size.memoryMb / GIB)} GB`;

export function toolchainFromRootFiles(files: readonly string[] | undefined): AutosizeToolchain {
  for (const marker of TOOLCHAIN_MARKERS) {
    if (files?.some((file) => marker.files.some((pattern) => pattern.test(file)))) return marker.toolchain;
  }
  return "unknown";
}

/** Nearest-rank percentile (p95 with fewer than 20 values is the largest). */
const percentile = (values: readonly number[], p: number) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * p) - 1]!;
const withMargin = (mb: number) => Math.ceil((mb * MEASURED_MARGIN) / GIB) * GIB;

/** Need from measured runs, per axis that has measurements; null axes fall back to the table. */
function measuredNeed(runs: readonly MeasuredRun[]) {
  const pick = (values: (number | undefined)[], p = 0.95) => {
    const known = values.filter((v): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0);
    return known.length ? percentile(known, p) : null;
  };
  const memory = pick(runs.map((run) => (run.ranShort === "memory" ? undefined : run.peakMemoryMb)));
  const cpus = pick(runs.map((run) => run.meanBusyCpus), 0.9);
  const disk = pick(runs.map((run) => (run.ranShort === "disk" ? undefined : run.peakDiskMb)));
  // A run that ran short used all it had on that axis and wanted more. Whatever
  // the other runs say, the need there is above the largest shape that ran
  // short, so one failure is never outvoted by the percentile.
  const floor = (axis: "memory" | "disk", of: (run: MeasuredRun) => number | undefined) =>
    Math.max(0, ...runs.filter((run) => run.ranShort === axis).map((run) => (of(run) ?? 0) + 1));
  const withFloor = (measured: number | null, min: number) => (min > 1 ? Math.max(measured ?? 0, min) : measured);
  return {
    memoryMb: withFloor(memory === null ? null : withMargin(memory), floor("memory", (run) => run.memoryMb)),
    cpus: cpus === null ? null : Math.ceil(cpus),
    diskMb: withFloor(disk === null ? null : withMargin(disk), floor("disk", (run) => run.storageMb ?? run.peakDiskMb)),
  };
}

/**
 * Picks the machine for a task: the smallest shape the plan allows that covers
 * its memory, cores and disk. The reason is one line for the chat header,
 * e.g. "4 vCPU · 16 GB, picked from 3 earlier runs".
 */
export function pickMachineSize(input: AutosizeInput): AutosizePick | AutosizeRefusal {
  if (input.gpu) return { ok: false, code: "gpu_unavailable", message: "No cloud machine has a GPU yet." };
  const allowed = VM_IMAGE_SIZES.filter((size) => input.planMemoryOptionsMb.includes(size.memoryMb));
  if (allowed.length === 0) return { ok: false, code: "no_plan_sizes", message: "The plan offers no machine size." };

  const toolchain = toolchainFromRootFiles(input.repo?.rootFiles);
  const task = input.taskKind === "chat" ? CHAT_NEED : TASK_NEEDS[input.taskKind][toolchain];
  const tableMemoryMb = AUTOSIZE_SESSION_NEED.memoryMb + task.memoryMb;
  const tableCpus = Math.max(AUTOSIZE_SESSION_NEED.cpus, task.cpus);
  const repoMb = input.repo?.sizeMb !== undefined && Number.isFinite(input.repo.sizeMb) && input.repo.sizeMb > 0 ? input.repo.sizeMb : 0;
  const tableDiskMb = repoMb * DISK_PER_REPO_MB;

  const runs = (input.measuredRuns ?? []).slice(0, MAX_MEASURED_RUNS);
  const measured = measuredNeed(runs);
  const measuredAxes = [measured.memoryMb, measured.cpus, measured.diskMb].some((v) => v !== null);
  const need = {
    memoryMb: measured.memoryMb ?? tableMemoryMb,
    cpus: Math.max(1, measured.cpus ?? tableCpus),
    diskMb: measured.diskMb ?? tableDiskMb,
  };

  const fits = allowed.find((size) => size.memoryMb >= need.memoryMb && size.cpu >= need.cpus && size.storageMb >= need.diskMb);
  const size = fits ?? allowed[allowed.length - 1]!;
  const basis = measuredAxes
    ? `picked from ${runs.length} earlier run${runs.length === 1 ? "" : "s"}`
    : input.taskKind === "chat"
      ? "picked for agent turns"
      : `picked for a ${toolchain === "unknown" ? "" : `${toolchain[0]!.toUpperCase()}${toolchain.slice(1)} `}${input.taskKind}`;
  const reason = `${shapeLabel(size)}, ${basis}${fits ? "" : ", the largest your plan allows"}`;
  return {
    ok: true,
    size,
    vcpus: size.cpu,
    memoryGb: size.memoryMb / GIB,
    pick: size.name,
    reason,
    capped: !fits,
  };
}

/** The create body's `autosize` field, validated; null when absent, a string when invalid (the field error). */
export function parseAutosizeRequest(value: unknown): { readonly taskKind: AutosizeTaskKind; readonly repo?: AutosizeInput["repo"]; readonly gpu: boolean } | null | string {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) return "`autosize` must be an object.";
  const v = value as Record<string, unknown>;
  const taskKind = v.taskKind === undefined ? "chat" : v.taskKind;
  if (typeof taskKind !== "string" || !(AUTOSIZE_TASK_KINDS as readonly string[]).includes(taskKind)) {
    return `\`autosize.taskKind\` must be one of ${AUTOSIZE_TASK_KINDS.join(", ")}.`;
  }
  if (v.gpu !== undefined && typeof v.gpu !== "boolean") return "`autosize.gpu` must be a boolean.";
  const repo = parseAutosizeRepo(v.repo);
  if (typeof repo === "string") return repo;
  return { taskKind: taskKind as AutosizeTaskKind, repo, gpu: v.gpu === true };
}

const validRepoSizeMb = (value: unknown) => value === undefined || (typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 16 * 1024 * 1024);
const validRootFiles = (value: unknown) =>
  value === undefined || (Array.isArray(value) && value.length <= 500 && value.every((f) => typeof f === "string" && f.length <= 255));

function parseAutosizeRepo(value: unknown): AutosizeInput["repo"] | string {
  if (value === undefined) return undefined;
  if (value === null || typeof value !== "object" || Array.isArray(value)) return "`autosize.repo` must be an object.";
  const r = value as Record<string, unknown>;
  if (!validRepoSizeMb(r.sizeMb)) return "`autosize.repo.sizeMb` must be a non-negative number of MiB.";
  if (!validRootFiles(r.rootFiles)) return "`autosize.repo.rootFiles` must be at most 500 file names.";
  if (r.key !== undefined && (typeof r.key !== "string" || !REPO_KEY.test(r.key))) {
    return "`autosize.repo.key` must name the repo, e.g. github.com/owner/name.";
  }
  return { key: (r.key as string | undefined)?.toLowerCase(), sizeMb: r.sizeMb as number | undefined, rootFiles: r.rootFiles as string[] | undefined };
}

/** A repo's identity across runs: host/owner/name, as the client's remote names it. */
const REPO_KEY = /^[A-Za-z0-9][A-Za-z0-9._~:@/-]{0,199}$/;

/**
 * What a VM created by a pick records in its metadata, so a later pick of the
 * same repo and task kind reads it with the peaks its guest reported
 * (resourceUsage.ts VM_RESOURCE_PEAK_KEY) as one measured run.
 */
export const AUTOSIZE_METADATA_KEY = "cmuxAutosize";
export type AutosizeTag = {
  readonly repoKey: string;
  readonly taskKind: AutosizeTaskKind;
  readonly pick: string;
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly storageMb: number;
};
export const autosizeTag = (repoKey: string, taskKind: AutosizeTaskKind, pick: AutosizePick): AutosizeTag =>
  ({ repoKey, taskKind, pick: pick.pick, vcpus: pick.size.cpu, memoryMb: pick.size.memoryMb, storageMb: pick.size.storageMb });

const finite = (value: unknown): number | undefined => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined);

/** A run whose peak reached this share of its memory or disk ran short on it (no OOM signal reaches the control plane yet). */
export const RAN_SHORT_FRACTION = 0.95;

/**
 * One measured run from a VM's metadata: its tag and its peaks. Null when the
 * VM has no tag or no sample ever reached the control plane.
 */
export function measuredRunFromMetadata(metadata: Readonly<Record<string, unknown>>, peakKey: string): MeasuredRun | null {
  const tag = metadata[AUTOSIZE_METADATA_KEY] as Record<string, unknown> | undefined;
  const peak = metadata[peakKey] as Record<string, unknown> | undefined;
  if (!tag || typeof tag !== "object" || !peak || typeof peak !== "object") return null;
  const vcpus = finite(tag.vcpus);
  const memoryMb = finite(tag.memoryMb);
  if (!vcpus || !memoryMb) return null;
  const storageMb = finite(tag.storageMb);
  const peakMemoryMb = finite(peak.memoryUsedMb);
  const peakDiskMb = finite(peak.diskUsedMb);
  const cpuSum = finite(peak.cpuPercentSum);
  const cpuSamples = finite(peak.cpuSamples);
  const meanBusyCpus = cpuSum !== undefined && cpuSamples ? (cpuSum / cpuSamples / 100) * vcpus : undefined;
  const ranShort = peakMemoryMb !== undefined && peakMemoryMb >= memoryMb * RAN_SHORT_FRACTION
    ? "memory" as const
    : peakDiskMb !== undefined && storageMb && peakDiskMb >= storageMb * RAN_SHORT_FRACTION ? "disk" as const : undefined;
  return { vcpus, memoryMb, storageMb, peakMemoryMb, meanBusyCpus, peakDiskMb, ...(ranShort ? { ranShort } : {}) };
}
