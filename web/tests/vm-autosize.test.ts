import { describe, expect, test } from "bun:test";
import {
  AUTOSIZE_SESSION_NEED,
  MAX_MEASURED_RUNS,
  TASK_NEEDS,
  autosizeTag,
  measuredRunFromMetadata,
  parseAutosizeRequest,
  pickMachineSize,
  toolchainFromRootFiles,
  type AutosizeInput,
  type MeasuredRun,
} from "../services/vms/autosize";
import { VM_MEMORY_OPTIONS_MB } from "../services/vms/entitlements";
import { VM_IMAGE_SIZES } from "../services/vms/images/sizes";

// Auto-sizing picks a handed-off task's machine from its needs: the fleet's
// grants for the task's kind and toolchain until the repo has measured runs,
// then p95 of their peaks plus 20%, on the smallest shape the plan allows.

const PRO = [4096, 8192, 16384];
const MAX = VM_MEMORY_OPTIONS_MB;

function pick(input: Partial<AutosizeInput> & Pick<AutosizeInput, "taskKind">) {
  const result = pickMachineSize({ planMemoryOptionsMb: PRO, ...input });
  if (!result.ok) throw new Error(result.message);
  return result;
}

describe("pickMachineSize from the table (no earlier runs)", () => {
  test("agent turns get the smallest shape", () => {
    const result = pick({ taskKind: "chat" });
    expect(result).toMatchObject({ pick: "sm", vcpus: 2, memoryGb: 4, capped: false, reason: "2 vCPU · 4 GB, picked for agent turns" });
  });

  test("a Swift build gets the release-compile grant plus the session", () => {
    const result = pick({ taskKind: "build", repo: { rootFiles: ["Package.swift", "README.md"] } });
    expect(result).toMatchObject({ pick: "lg", vcpus: 8, memoryGb: 16, reason: "8 vCPU · 16 GB, picked for a Swift build" });
  });

  test("a Node test needs little memory but the webview tests' 6 cores", () => {
    expect(pick({ taskKind: "test", repo: { rootFiles: ["package.json"] } })).toMatchObject({ pick: "lg", reason: "8 vCPU · 16 GB, picked for a Node test" });
  });

  test("a build of an unknown toolchain gets the isolated-step grant", () => {
    const result = pick({ taskKind: "build", repo: { rootFiles: ["Makefile"] } });
    expect(result).toMatchObject({ pick: "lg", reason: "8 vCPU · 16 GB, picked for a build" });
  });

  test("a Rust build above the plan gets the plan's largest, and says so", () => {
    const pro = pick({ taskKind: "build", repo: { rootFiles: ["Cargo.toml"] } });
    expect(pro).toMatchObject({ pick: "lg", capped: true, reason: "8 vCPU · 16 GB, picked for a Rust build, the largest your plan allows" });
    const max = pick({ taskKind: "build", repo: { rootFiles: ["Cargo.toml"] }, planMemoryOptionsMb: MAX });
    expect(max).toMatchObject({ pick: "lgx", vcpus: 12, memoryGb: 24, capped: false });
  });

  test("a large repo needs the disk for its checkout and build", () => {
    // 10 GiB of repo: 40 GiB of disk, past md's 32 GiB.
    expect(pick({ taskKind: "chat", repo: { sizeMb: 10 * 1024 } }).pick).toBe("lg");
    expect(pick({ taskKind: "chat", repo: { sizeMb: 1024 } }).pick).toBe("sm");
  });

  test("every table row fits the largest shape", () => {
    const largest = VM_IMAGE_SIZES[VM_IMAGE_SIZES.length - 1]!;
    for (const byToolchain of Object.values(TASK_NEEDS)) {
      for (const need of Object.values(byToolchain)) {
        expect(AUTOSIZE_SESSION_NEED.memoryMb + need.memoryMb).toBeLessThanOrEqual(largest.memoryMb);
        expect(Math.max(AUTOSIZE_SESSION_NEED.cpus, need.cpus)).toBeLessThanOrEqual(largest.cpu);
      }
    }
  });
});

describe("pickMachineSize from measured runs", () => {
  const run = (peakMemoryMb: number, meanBusyCpus: number, extra: Partial<MeasuredRun> = {}): MeasuredRun =>
    ({ vcpus: 8, memoryMb: 16384, peakMemoryMb, meanBusyCpus, ...extra });

  test("p95 of the peaks plus 20% replaces the table", () => {
    // 7000 MiB * 1.2 = 8400 -> 9 GiB: past md's 8 GiB.
    const result = pick({ taskKind: "build", repo: { rootFiles: ["Package.swift"] }, measuredRuns: [run(5000, 2.5), run(6000, 3), run(7000, 3.2)] });
    expect(result).toMatchObject({ pick: "lg", reason: "8 vCPU · 16 GB, picked from 3 earlier runs" });
  });

  test("measured runs can shrink a pick", () => {
    const result = pick({ taskKind: "build", repo: { rootFiles: ["Package.swift"] }, measuredRuns: [run(3000, 1.5)] });
    expect(result).toMatchObject({ pick: "sm", reason: "2 vCPU · 4 GB, picked from 1 earlier run" });
  });

  test("busy cores raise the shape when memory would not", () => {
    // 3000 MiB fits sm, but 3.5 busy cores -> 4 cores needs md.
    expect(pick({ taskKind: "chat", measuredRuns: [run(3000, 3.5)] }).pick).toBe("md");
    // 4.2 -> 5 cores needs lg.
    expect(pick({ taskKind: "chat", measuredRuns: [run(3000, 4.2)] }).pick).toBe("lg");
  });

  test("cores take no margin: a run averaging 2 cores stays on 2 vCPU", () => {
    expect(pick({ taskKind: "chat", measuredRuns: [run(2000, 2)] }).pick).toBe("sm");
  });

  test("a run that ran short sends the next pick above the shape it had", () => {
    // It had md (8 GiB) and ran short: 8 GiB * 1.2 -> 10 GiB, so lg.
    const result = pick({ taskKind: "chat", measuredRuns: [{ vcpus: 4, memoryMb: 8192, ranShort: "memory" }] });
    expect(result.pick).toBe("lg");
  });

  test("measured peak disk replaces the per-repo estimate", () => {
    expect(pick({ taskKind: "chat", repo: { sizeMb: 10 * 1024 }, measuredRuns: [run(1000, 1, { peakDiskMb: 6000 })] }).pick).toBe("sm");
  });

  test("an axis with no measurement keeps the table", () => {
    // Cores measured, memory not: the Swift build's 15 GiB stands.
    expect(pick({ taskKind: "build", repo: { rootFiles: ["Package.swift"] }, measuredRuns: [{ vcpus: 8, memoryMb: 16384, meanBusyCpus: 1 }] }).pick).toBe("lg");
  });

  test("one run that ran short is never outvoted by the percentile", () => {
    const fine = Array.from({ length: 19 }, () => run(2000, 1));
    const result = pick({ taskKind: "chat", measuredRuns: [...fine, { vcpus: 4, memoryMb: 8192, ranShort: "memory" }] });
    expect(result.pick).toBe("lg");
  });

  test("a run that ran out of disk raises the disk, and says so when no shape has more", () => {
    // md (32 GiB disk) ran out of disk: lg has 64 GiB.
    expect(pick({ taskKind: "chat", measuredRuns: [{ vcpus: 4, memoryMb: 8192, storageMb: 32768, peakDiskMb: 30000, ranShort: "disk" }] }).pick).toBe("lg");
    // xl (128 GiB) ran out: 2xl has the same 128 GiB, so no shape fits.
    const result = pick({ taskKind: "chat", planMemoryOptionsMb: MAX, measuredRuns: [{ vcpus: 16, memoryMb: 32768, storageMb: 131072, ranShort: "disk" }] });
    expect(result).toMatchObject({ pick: "2xl", capped: true });
    expect(result.reason).toEndWith(", the largest your plan allows");
  });

  test("only the newest runs count", () => {
    const newest = Array.from({ length: MAX_MEASURED_RUNS }, () => run(2000, 1));
    const result = pick({ taskKind: "build", measuredRuns: [...newest, run(60000, 30)] });
    expect(result).toMatchObject({ pick: "sm", reason: `2 vCPU · 4 GB, picked from ${MAX_MEASURED_RUNS} earlier runs` });
  });
});

describe("pickMachineSize refusals", () => {
  test("a GPU is refused until a provider has one", () => {
    expect(pickMachineSize({ taskKind: "chat", gpu: true, planMemoryOptionsMb: MAX })).toMatchObject({ ok: false, code: "gpu_unavailable" });
  });

  test("a plan with no sizes is refused", () => {
    expect(pickMachineSize({ taskKind: "chat", planMemoryOptionsMb: [] })).toMatchObject({ ok: false, code: "no_plan_sizes" });
  });
});

describe("toolchainFromRootFiles", () => {
  test("Rust wins over a package.json, Swift is found by project bundles", () => {
    expect(toolchainFromRootFiles(["package.json", "Cargo.toml"])).toBe("rust");
    expect(toolchainFromRootFiles(["App.xcodeproj", "package.json"])).toBe("swift");
    expect(toolchainFromRootFiles(["package.json"])).toBe("node");
    expect(toolchainFromRootFiles([])).toBe("unknown");
    expect(toolchainFromRootFiles(undefined)).toBe("unknown");
  });
});

describe("parseAutosizeRequest", () => {
  test("absent is null; taskKind defaults to chat", () => {
    expect(parseAutosizeRequest(undefined)).toBeNull();
    expect(parseAutosizeRequest({})).toEqual({ taskKind: "chat", repo: undefined, gpu: false });
    expect(parseAutosizeRequest({ taskKind: "build", repo: { sizeMb: 12, rootFiles: ["Cargo.toml"] }, gpu: true }))
      .toEqual({ taskKind: "build", repo: { sizeMb: 12, rootFiles: ["Cargo.toml"] }, gpu: true });
  });

  test("the repo key is lowercased", () => {
    expect(parseAutosizeRequest({ repo: { key: "GitHub.com/Manaflow-AI/cmux" } })).toMatchObject({ repo: { key: "github.com/manaflow-ai/cmux" } });
  });

  test("invalid fields are a field error", () => {
    for (const value of [[], "build", { taskKind: "deploy" }, { taskKind: null }, { gpu: "yes" }, { repo: [] }, { repo: { sizeMb: -1 } }, { repo: { rootFiles: [1] } },
      { repo: { key: "" } }, { repo: { key: "has space" } }, { repo: { key: 7 } }]) {
      expect(typeof parseAutosizeRequest(value)).toBe("string");
    }
  });
});

describe("measuredRunFromMetadata", () => {
  const sm = pickMachineSize({ taskKind: "chat", planMemoryOptionsMb: PRO });
  if (!sm.ok) throw new Error(sm.message);
  const tag = autosizeTag("github.com/o/r", "chat", sm);

  test("a tagged VM's peaks are one run; CPU is the mean busy cores", () => {
    const peak = { providerVmId: "p", memoryUsedMb: 3500, diskUsedMb: 9000, cpuPercentSum: 150, cpuSamples: 2 };
    expect(measuredRunFromMetadata({ cmuxAutosize: tag, cmuxResourcePeak: peak }, "cmuxResourcePeak"))
      .toEqual({ vcpus: 2, memoryMb: 4096, storageMb: 16384, peakMemoryMb: 3500, meanBusyCpus: 1.5, peakDiskMb: 9000 });
  });

  test("a run that filled its shape picks the next one up", () => {
    // 3500 of 4096 MiB * 1.2 -> 5 GiB: md.
    const run = measuredRunFromMetadata({ cmuxAutosize: tag, cmuxResourcePeak: { memoryUsedMb: 3500 } }, "cmuxResourcePeak")!;
    expect(pick({ taskKind: "chat", measuredRuns: [run] }).pick).toBe("md");
  });

  test("a peak at 95% of the shape ran short on that axis, so the percentile cannot outvote it", () => {
    const fine = Array.from({ length: 19 }, () => measuredRunFromMetadata({ cmuxAutosize: tag, cmuxResourcePeak: { memoryUsedMb: 1000 } }, "cmuxResourcePeak")!);
    const oom = measuredRunFromMetadata({ cmuxAutosize: tag, cmuxResourcePeak: { memoryUsedMb: 3950 } }, "cmuxResourcePeak")!;
    const full = measuredRunFromMetadata({ cmuxAutosize: tag, cmuxResourcePeak: { memoryUsedMb: 1000, diskUsedMb: 16000 } }, "cmuxResourcePeak")!;
    expect(oom.ranShort).toBe("memory");
    expect(full.ranShort).toBe("disk");
    expect(pick({ taskKind: "chat", measuredRuns: [...fine, oom] }).pick).toBe("md");
    expect(pick({ taskKind: "chat", measuredRuns: [...fine, full] }).pick).toBe("md");
  });

  test("no tag, no peaks, or a broken tag is no run", () => {
    expect(measuredRunFromMetadata({ cmuxResourcePeak: { memoryUsedMb: 1 } }, "cmuxResourcePeak")).toBeNull();
    expect(measuredRunFromMetadata({ cmuxAutosize: tag }, "cmuxResourcePeak")).toBeNull();
    expect(measuredRunFromMetadata({ cmuxAutosize: { ...tag, vcpus: "2" }, cmuxResourcePeak: {} }, "cmuxResourcePeak")).toBeNull();
  });
});
