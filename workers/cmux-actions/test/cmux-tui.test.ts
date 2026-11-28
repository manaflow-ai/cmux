/**
 * Exact plan of cmux-tui.yml, the proof target (DESIGN.md section 18): which
 * jobs run for a focused dispatch, which legs are Linux, and how the local
 * reusable workflow cmux-tui-build-package.yml is inlined.
 *
 * The input is the frozen copy under test/fixtures/cmux-tui (cmux-tui.yml,
 * cmux-tui-build-package.yml and setup-cmux-tui-rust, taken from main at
 * 4419961c2466), not the live workflow, so the expectations hold on every
 * branch. workflows.test.ts covers the live cmux-tui.yml: it parses and plans
 * every trigger with zero errors. Refresh the fixture only to cover new
 * engine behavior, and update the expectations with it.
 */

import { describe, expect, it } from "vitest";
import { type SimulatedJob, simulateRun, workflowDispatchEvent } from "../src/plan/index.ts";
import { parseWorkflow, type Workflow } from "../src/workflow/model.ts";
import { fixtureTree, REPOSITORY, SHA_A } from "./support/repo.ts";

const PATH = ".github/workflows/cmux-tui.yml";

const files = fixtureTree("cmux-tui");

const workflow = (): Workflow => {
  const text = files.read(PATH);
  if (text === undefined) throw new Error(`missing fixture ${PATH}`);
  return parseWorkflow(text, PATH);
};

const PLAN_BUILD_OUTPUTS = {
  matrix: JSON.stringify({ include: [{ target: "aarch64-apple-darwin", runner: "blacksmith-6vcpu-macos-15" }] }),
  linux_package_matrix: JSON.stringify({ include: [] }),
};

const plan = (mode: "focused" | "full", fail: ReadonlySet<string> = new Set()) => {
  const dispatch = workflowDispatchEvent({
    repository: REPOSITORY,
    ref: "refs/heads/feat-x",
    sha: SHA_A,
    workflow: workflow(),
    inputs: { commit: SHA_A, mode, test_filter: mode === "focused" ? "journal" : "", request_id: "r1" },
  });
  return simulateRun(workflow(), {
    event: dispatch.event,
    inputs: dispatch.inputs,
    files,
    outcome: (job) => ({
      result: fail.has(job.key) ? "failure" : "success",
      ...(job.key === "build-artifacts/plan-build" ? { outputs: PLAN_BUILD_OUTPUTS } : {}),
    }),
  });
};

const row = (job: SimulatedJob) => [job.key, job.name, job.status, job.label?.kind ?? null] as const;

describe("cmux-tui.yml focused dispatch", () => {
  it("plans the documented job graph", () => {
    const simulation = plan("focused");
    expect(simulation.errors).toEqual([]);
    expect(simulation.jobs.map(row)).toEqual([
      ["validate-inputs", "validate exact commit request", "run", "linux"],
      ["msrv-check", "Rust MSRV (1.91)", "run", "linux"],
      ["web-frontend", "web-frontend", "skipped", null],
      ["lint(0)", "lint (macos)", "run", "unsupported"],
      ["lint(1)", "lint (linux)", "run", "linux"],
      ["valgrind-leak-check-shard", "valgrind-leak-check (startup)", "skipped", null],
      ["valgrind-leak-check", "valgrind-leak-check", "skipped", null],
      ["test(0)", "test (macos)", "run", "unsupported"],
      ["test(1)", "test (linux)", "run", "linux"],
      ["test-windows", "test (windows)", "skipped", null],
      ["cdp-browser-smoke", "CDP browser smoke (${{ matrix.os }})", "skipped", null],
      ["bindings-e2e", "bindings-e2e", "skipped", null],
      ["build-artifacts/plan-build", "release-path dogfood artifacts / select binary targets", "run", "linux"],
      ["build-artifacts/build(0)", "release-path dogfood artifacts / build aarch64-apple-darwin", "run", "unsupported"],
      ["build-artifacts/build-windows", "release-path dogfood artifacts / build x86_64-pc-windows-gnu", "skipped", null],
      ["build-artifacts/package", "release-path dogfood artifacts / package distributions", "skipped", null],
      [
        "build-artifacts/verify-linux-packages",
        "release-path dogfood artifacts / verify Linux package entrypoints (${{ matrix.architecture }})",
        "skipped",
        null,
      ],
      ["build-artifacts/attest-npm-packages", "release-path dogfood artifacts / attest native npm package binaries", "skipped", null],
      ["hosted-verification", "focused hosted verification", "run", "linux"],
    ]);
  });

  it("sizes the proof jobs like Blacksmith and finds nothing blocking them", () => {
    const simulation = plan("focused");
    for (const key of ["lint(1)", "test(1)", "validate-inputs"]) {
      const job = simulation.jobs.find((item) => item.key === key);
      expect(job?.label, key).toEqual({ kind: "linux", label: "blacksmith-4vcpu-ubuntu-2404", vcpus: 4, memoryGiB: 16 });
      expect(job?.unsupported, key).toEqual([]);
      expect(job?.matrix ?? null, key).toEqual(key === "validate-inputs" ? null : { os: "linux", runner: "blacksmith-4vcpu-ubuntu-2404" });
    }
    const mac = simulation.jobs.find((item) => item.key === "lint(0)");
    expect(mac?.unsupported).toEqual(["macOS runners are not supported"]);
  });

  it("still runs the always() gate when a test leg fails", () => {
    const simulation = plan("focused", new Set(["test(1)"]));
    const gate = simulation.jobs.find((item) => item.key === "hosted-verification");
    expect(gate?.status).toBe("run");
  });
});

describe("cmux-tui.yml full dispatch", () => {
  it("runs the full-mode jobs and keeps Windows and macOS legs off cmux VMs", () => {
    const simulation = plan("full");
    expect(simulation.errors).toEqual([]);
    const byKey = new Map(simulation.jobs.map((job) => [job.key, job]));
    expect(byKey.get("web-frontend")?.status).toBe("run");
    expect(byKey.get("valgrind-leak-check-shard")?.label?.kind).toBe("linux");
    expect(byKey.get("valgrind-leak-check")?.status).toBe("run");
    expect(byKey.get("test-windows")?.unsupported).toEqual(["Windows runners are not supported"]);
    expect(byKey.get("cdp-browser-smoke(1)")?.name).toBe("CDP browser smoke (linux)");
    expect(byKey.get("bindings-e2e")?.label?.kind).toBe("linux");
    expect(byKey.get("build-artifacts/build-windows")?.status).toBe("run");
  });

  it("still runs the always() valgrind summary when the shard fails", () => {
    const simulation = plan("full", new Set(["valgrind-leak-check-shard"]));
    expect(simulation.jobs.find((item) => item.key === "valgrind-leak-check")?.status).toBe("run");
  });
});
