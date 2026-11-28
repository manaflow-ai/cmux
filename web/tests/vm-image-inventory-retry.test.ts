import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { INVENTORY_STEP_BUDGET_MS, inventoryFailure, SYFT_GOMEMLIMIT, SYFT_MEMORY_MAX, sbomScanCommand } from "../scripts/cmux-vm-image/bake";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";
import {
  STEP_TIMEOUT_MS,
  StepLog,
  type Vm,
  DETACHED_WAKE_AFTER_FAILED_POLLS,
  wakeVm,
} from "../scripts/cmux-vm-image/guest";
import {
  INVENTORY_TRIES,
  retriesInventory,
  collectWithRetries,
  INVENTORY_SHAPE,
  growForInventory,
} from "../scripts/cmux-vm-image/inventory";
import type { GuestShape } from "../scripts/cmux-vm-image/large-image";

describe("image inventory retries a cut connection, not a failed step", () => {
  test("the provider closing the exec's connection is retried (run 42410303540)", () => {
    const reset = new TypeError("ECONNRESET: The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()");
    expect(retriesInventory(reset, 1)).toBe(true);
    expect(retriesInventory(new Error("fetch failed"), 1)).toBe(true);
    expect(retriesInventory(new Error("upstream answered 502"), 2)).toBe(true);
  });

  test("a step that ran and failed is not retried", () => {
    expect(retriesInventory(new Error("step sbom failed"), 1)).toBe(false);
    expect(retriesInventory(new Error("step file-manifest failed"), 1)).toBe(false);
    expect(retriesInventory(new Error("no bake-*.json in /tmp/out"), 1)).toBe(false);
  });

  test("the last try is final", () => {
    expect(retriesInventory(new Error("ECONNRESET"), INVENTORY_TRIES)).toBe(false);
  });
});

describe("image inventory reads the provider status and lets a failed step win", () => {
  test("a provider 502/503/504 is retried from its status, whatever its message says", () => {
    for (const status of [502, 503, 504]) {
      const error = Object.assign(new Error("The service is temporarily overloaded, try again later"), { status });
      expect(retriesInventory(error, 1)).toBe(true);
    }
    expect(retriesInventory(Object.assign(new Error("Bad request"), { status: 400 }), 1)).toBe(false);
  });

  test("a step that ran and failed wins over the other step's cut connection", () => {
    const reset = new TypeError("ECONNRESET: The socket connection was closed unexpectedly");
    const stepFailed = new Error("step sbom failed");
    const settled: PromiseSettledResult<string>[] = [{ status: "rejected", reason: reset }, { status: "rejected", reason: stepFailed }];
    const failure = inventoryFailure(settled);
    expect(failure).toBe(stepFailed);
    expect(retriesInventory(failure, 1)).toBe(false);
    expect(inventoryFailure([{ status: "rejected", reason: reset }, { status: "fulfilled", value: "ok" }])).toBe(reset);
    expect(inventoryFailure([{ status: "fulfilled", value: "a" }, { status: "fulfilled", value: "b" }])).toBeUndefined();
  });
});

describe("image inventory steps run detached and outlast a cut poll (rolls 45779971043, 45829777164, 45883186922)", () => {
  test("a client TimeoutError is retried: the call never reached a guest verdict", () => {
    const timedOut = new DOMException("The operation timed out.", "TimeoutError");
    expect(retriesInventory(timedOut, 1)).toBe(true);
    expect(retriesInventory(new Error("TimeoutError: The operation timed out."), 2)).toBe(true);
    expect(retriesInventory(timedOut, INVENTORY_TRIES)).toBe(false);
  });

  test("the budget sits about twice over the slowest measured finish (scan 278 s, manifest 232 s)", () => {
    expect(INVENTORY_STEP_BUDGET_MS).toBeGreaterThanOrEqual(2 * 278_000);
    // The old bounds the rolls hit: the 280 s guest timeout and the 300 s exec cap.
    expect(INVENTORY_STEP_BUDGET_MS).toBeGreaterThan(STEP_TIMEOUT_MS);
  });

  /** A guest whose status file appears after `pollsUntilDone` polls; `failPolls` polls throw like a cut poll. */
  function fakeGuest(opts: { pollsUntilDone: number; failPolls?: number; status?: number; stdout?: string }) {
    const commands: string[] = [];
    let polls = 0;
    const vm = {
      exec: async ({ command }: { command: string; timeoutMs?: number }) => {
        commands.push(command);
        expect(command).not.toContain("undefined");
        if (command.includes("nohup setsid sh -c")) return { statusCode: 0, stdout: "started\n", stderr: "" };
        if (command.includes("/status 2>/dev/null")) {
          polls++;
          if (polls <= (opts.failPolls ?? 0)) throw new DOMException("The operation timed out.", "TimeoutError");
          return { statusCode: 0, stdout: polls >= opts.pollsUntilDone ? `${opts.status ?? 0}\n` : "", stderr: "" };
        }
        return { statusCode: 0, stdout: `${opts.stdout ?? "syft-secs 300"}\n--cmux-detached-stderr--\nwarn\n`, stderr: "" };
      },
    } as unknown as Vm;
    return { vm, commands, polls: () => polls };
  }

  function clock(stepMs: number) {
    let t = 0;
    return { now: () => t, sleep: async () => { t += stepMs; } };
  }

  test("a step past the old 300 s exec cap finishes, and a poll that timed out is just polled again", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "inv-"));
    const L = new StepLog(path.join(dir, "inv.log"));
    const guest = fakeGuest({ pollsUntilDone: 40, failPolls: 25 });
    const c = clock(10_000);
    const out = await L.detachedStep(guest.vm, "sbom", "echo hi", { dir: "/tmp/cmux-out/job-sbom", budgetMs: 600_000, ...c });
    expect(out.trim()).toBe("syft-secs 300");
    expect(L.steps).toEqual([{ label: "sbom", secs: 400 }]);
    expect(guest.polls()).toBe(40);
    expect(guest.commands[0]).toContain("timeout -k 10 600 sh /tmp/cmux-out/job-sbom/cmd.sh");
    // Past half its budget: the workflow turns SLOW_STEP into a warning before the bound is reached.
    expect(readFileSync(path.join(dir, "inv.log"), "utf8")).toContain("SLOW_STEP [sbom] 400.0s of its 600s budget");
  });

  test("the guest's timeout (124) is a failed step, not retried", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "inv-"));
    const L = new StepLog(path.join(dir, "inv.log"));
    const guest = fakeGuest({ pollsUntilDone: 3, status: 124 });
    const error = await L.detachedStep(guest.vm, "file-manifest", "true", { dir: "/tmp/x", budgetMs: 600_000, ...clock(10_000) }).catch((e: unknown) => e);
    expect(String(error)).toContain("step file-manifest failed");
    expect(retriesInventory(error, 1)).toBe(false);
    expect(readFileSync(path.join(dir, "inv.log"), "utf8")).toContain("its 600 s budget ran out");
  });

  test("polls that fail past the budget surface the provider's error, which inventory.ts retries", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "inv-"));
    const L = new StepLog(path.join(dir, "inv.log"));
    const guest = fakeGuest({ pollsUntilDone: 1_000, failPolls: 1_000 });
    const error = await L.detachedStep(guest.vm, "sbom", "true", { dir: "/tmp/x", budgetMs: 60_000, ...clock(10_000) }).catch((e: unknown) => e);
    expect((error as { name?: string }).name).toBe("TimeoutError");
    expect(retriesInventory(error, 1)).toBe(true);
  });
});

describe("the SBOM scan cannot wedge its builder, and a silent builder is not retried (roll 46078031124)", () => {
  test("syft runs under the Go memory limit and the cgroup cap, and the guest's /bin/sh accepts it", () => {
    const command = sbomScanCommand("/tmp/cmux-out", ["/home/cmux/dev"]);
    expect(guestShellProblems(command).refused).toEqual([]);
    expect(command).toContain(`GOMEMLIMIT=${SYFT_GOMEMLIMIT}`);
    expect(command).toContain(`-p MemoryMax=${SYFT_MEMORY_MAX} -p MemorySwapMax=0`);
    expect(command).toContain("--exclude './home/cmux/dev/**'");
  });

  function runScan(syftBody: string): { status: number; stdout: string; stderr: string; gz: boolean } {
    const out = mkdtempSync(path.join(tmpdir(), "sbom-"));
    mkdirSync(`${out}-syft`, { recursive: true });
    writeFileSync(`${out}-syft/syft`, `#!/bin/sh\n${syftBody}\n`);
    chmodSync(`${out}-syft/syft`, 0o755);
    // No systemd-run on PATH: the guest without it still gets the Go limit.
    const r = spawnSync("/bin/sh", ["-c", sbomScanCommand(out, [])], { encoding: "utf8", env: { PATH: "/usr/bin:/bin" } as unknown as NodeJS.ProcessEnv });
    return { status: r.status ?? -1, stdout: r.stdout, stderr: r.stderr, gz: existsSync(`${out}/sbom.cdx.json.gz`) };
  }

  test("a scan that finishes is gzipped and timed, with the limit it ran under", () => {
    const r = runScan('[ "$GOMEMLIMIT" = 1800MiB ] || exit 3; for a; do case "$a" in cyclonedx-json=*) echo "{}" > "${a#cyclonedx-json=}";; esac; done');
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("syft-cap  gomemlimit 1800MiB");
    expect(r.stdout).toMatch(/syft-secs \d+/);
    expect(r.gz).toBe(true);
  });

  test("a syft the cap killed fails the step at once with the reason", () => {
    const r = runScan("kill -9 $$");
    expect(r.status).toBe(137);
    expect(r.stderr).toContain(`syft killed (status 137): its ${SYFT_MEMORY_MAX} memory cap`);
    expect(r.stdout).not.toContain("syft-secs");
  });
});

describe("image inventory wakes a builder the provider paused (roll 46078031124)", () => {
  function provider(state: string) {
    const calls: string[] = [];
    return {
      calls,
      vm: {
        data: async () => { calls.push("data"); return { state }; },
        start: async () => { calls.push("start"); return { state: "running" }; },
      } as unknown as Pick<Vm, "data" | "start">,
    };
  }

  test("a paused or stopped builder is started and its state logged", async () => {
    for (const state of ["paused", "stopped", "pausing"]) {
      const p = provider(state);
      const lines: string[] = [];
      expect(await wakeVm(p.vm, (l) => lines.push(l), "b")).toBe(state);
      expect(p.calls).toEqual(["data", "start"]);
      expect(lines.join("\n")).toContain(`VM_STATE [b] ${state}: starting it`);
    }
  });

  test("a running builder is left alone, but its state still logged", async () => {
    const p = provider("running");
    const lines: string[] = [];
    await wakeVm(p.vm, (l) => lines.push(l), "b");
    expect(p.calls).toEqual(["data"]);
    expect(lines).toEqual(["VM_STATE [b] running"]);
  });

  test("detachedStep wakes the VM after a run of failed polls, and the step then finishes", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "inv-"));
    const L = new StepLog(path.join(dir, "inv.log"));
    let paused = true;
    let wakes = 0;
    let t = 0;
    const vm = {
      exec: async ({ command }: { command: string }) => {
        if (command.includes("nohup setsid sh -c")) return { statusCode: 0, stdout: "started\n", stderr: "" };
        if (paused) throw new DOMException("The operation timed out.", "TimeoutError");
        if (command.includes("/status 2>/dev/null")) return { statusCode: 0, stdout: "0\n", stderr: "" };
        return { statusCode: 0, stdout: "syft-secs 120\n--cmux-detached-stderr--\n", stderr: "" };
      },
    } as unknown as Vm;
    const out = await L.detachedStep(vm, "sbom", "true", {
      dir: "/tmp/x", budgetMs: 600_000, now: () => t, sleep: async () => { t += 10_000; },
      wake: async () => { wakes++; paused = false; },
    });
    expect(out.trim()).toBe("syft-secs 120");
    expect(wakes).toBe(1);
    expect(DETACHED_WAKE_AFTER_FAILED_POLLS).toBeLessThanOrEqual(3);
  });

  test("a wake that throws is logged and polling goes on to the provider's error", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "inv-"));
    const L = new StepLog(path.join(dir, "inv.log"));
    let t = 0;
    const vm = {
      exec: async ({ command }: { command: string }) => {
        if (command.includes("nohup setsid sh -c")) return { statusCode: 0, stdout: "started\n", stderr: "" };
        throw new DOMException("The operation timed out.", "TimeoutError");
      },
    } as unknown as Vm;
    const error = await L.detachedStep(vm, "sbom", "true", {
      dir: "/tmp/x", budgetMs: 60_000, now: () => t, sleep: async () => { t += 10_000; },
      wake: async () => { throw new Error("401"); },
    }).catch((e: unknown) => e);
    expect((error as { name?: string }).name).toBe("TimeoutError");
    expect(readFileSync(path.join(dir, "inv.log"), "utf8")).toContain("WARN [sbom] wake after 2 failed polls: Error: 401");
  });
});

describe("collectWithRetries: a builder that stops answering (roll 46078031124)", () => {
  const timedOut = () => Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });
  const builder = { vm: { id: "builder" } as unknown as Vm, vmId: "vm-builder" };
  const clone = { vm: { id: "clone" } as unknown as Vm, vmId: "vm-clone" };

  test("retries on a clone of the snapshot once the builder does not answer", async () => {
    const ran: string[] = [];
    const lines: string[] = [];
    const inventory: Record<string, unknown> = {};
    await collectWithRetries(builder, inventory, (l) => lines.push(l), {
      collect: async (vm, attempt) => {
        ran.push(`${(vm as unknown as { id: string }).id}:${attempt}`);
        if ((vm as unknown as { id: string }).id === "builder") throw timedOut();
      },
      answers: async () => false,
      clone: async () => clone,
    });
    // Before: all three tries on the builder, each timing out (1546.8 s, components=none).
    expect(ran).toEqual(["builder:1", "clone:2"]);
    expect(inventory.error).toBeUndefined();
    expect(inventory.inventoryClone).toBe("vm-clone");
    expect(lines.some((l) => l.includes("did not answer an exec"))).toBe(true);
  });

  test("stays on a builder that still answers", async () => {
    const ran: string[] = [];
    let clones = 0;
    await collectWithRetries(builder, {}, () => {}, {
      collect: async (vm, attempt) => {
        ran.push(`${(vm as unknown as { id: string }).id}:${attempt}`);
        if (attempt === 1) throw new Error("ECONNRESET");
      },
      answers: async () => true,
      clone: async () => { clones++; return clone; },
    });
    expect(ran).toEqual(["builder:1", "builder:2"]);
    expect(clones).toBe(0);
  });

  test("a step that ran and failed is not retried, on any VM", async () => {
    let tries = 0;
    await expect(collectWithRetries(builder, {}, () => {}, {
      collect: async () => { tries++; throw new Error("step sbom failed"); },
      answers: async () => false,
      clone: async () => clone,
    })).rejects.toThrow("step sbom failed");
    expect(tries).toBe(1);
  });

  test("without a snapshot id it retries on the builder as before, up to INVENTORY_TRIES", async () => {
    let tries = 0;
    await expect(collectWithRetries(builder, {}, () => {}, {
      collect: async () => { tries++; throw timedOut(); },
      answers: async () => false,
    })).rejects.toThrow("timed out");
    expect(tries).toBe(INVENTORY_TRIES);
  });
});

describe("image inventory grows its builder before the scan (rolls 46085354594, 46090412457)", () => {
  const fakeVm = (calls: unknown[], fail = false) =>
    ({ resize: async (req: unknown) => { calls.push(req); if (fail) throw new Error("resize refused"); } }) as unknown as Vm;

  test("a base-size builder is grown to 4 vCPU / 8 GiB", async () => {
    const calls: unknown[] = [];
    const lines: string[] = [];
    const shapes = [{ cpu: 2, memoryMb: 3915, rootMb: 15955 }, { cpu: 4, memoryMb: 8011, rootMb: 15955 }];
    await growForInventory(fakeVm(calls), (l) => lines.push(l), async () => shapes.shift() as GuestShape);
    expect(calls).toEqual([{ cpu: INVENTORY_SHAPE.cpu, memory: INVENTORY_SHAPE.memoryMb }]);
    expect(lines[0]).toContain('"cpu":4');
  });

  test("a builder a large-image bake already grew is left as it is (resize only grows)", async () => {
    const calls: unknown[] = [];
    const lines: string[] = [];
    await growForInventory(fakeVm(calls), (l) => lines.push(l), async () => ({ cpu: 8, memoryMb: 32000, rootMb: 64000 }));
    expect(calls).toEqual([]);
    expect(lines[0]).toContain("kept");
  });

  test("more vCPU than the shape keeps its vCPU when only memory is short", async () => {
    const calls: unknown[] = [];
    await growForInventory(fakeVm(calls), () => {}, async () => ({ cpu: 8, memoryMb: 3915, rootMb: 15955 }));
    expect(calls).toEqual([{ cpu: 8, memory: 8192 }]);
  });

  test("a failed resize is logged and the scan runs at the size it has", async () => {
    const lines: string[] = [];
    await growForInventory(fakeVm([], true), (l) => lines.push(l), async () => ({ cpu: 2, memoryMb: 3915, rootMb: 15955 }));
    expect(lines[0]).toStartWith("WARN inventory resize");
  });
});
