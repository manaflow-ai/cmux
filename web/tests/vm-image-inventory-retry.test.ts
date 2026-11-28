import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { INVENTORY_STEP_BUDGET_MS, inventoryFailure } from "../scripts/cmux-vm-image/bake";
import { STEP_TIMEOUT_MS, StepLog, type Vm } from "../scripts/cmux-vm-image/guest";
import { INVENTORY_TRIES, retriesInventory } from "../scripts/cmux-vm-image/inventory";

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
