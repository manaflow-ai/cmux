import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { isProviderFault, onFreshMachines, reachabilityKey } from "../scripts/check-devbox-image-reachable";

describe("devbox reachability run key", () => {
  const defaults = [
    { version: "base-sm", imageId: "sh-aaa" },
    { version: "base-md", imageId: "sh-bbb" },
  ];

  test("the same images and client repeat a key, so CI can skip the run", () => {
    expect(reachabilityKey(defaults, "client-1")).toBe(reachabilityKey(defaults, "client-1"));
  });

  test("order of the defaults does not change the key", () => {
    expect(reachabilityKey([...defaults].reverse(), "client-1")).toBe(reachabilityKey(defaults, "client-1"));
  });

  test("a promoted image is a new pair to test", () => {
    const promoted = [{ version: "base-sm", imageId: "sh-ccc" }, defaults[1]!];
    expect(reachabilityKey(promoted, "client-1")).not.toBe(reachabilityKey(defaults, "client-1"));
  });

  test("a new cmux-tui release is a new pair to test", () => {
    // This is the case with no commit behind it: files.cmux.com moves and the
    // manifest does not, which is exactly what the daily run is for.
    expect(reachabilityKey(defaults, "client-2")).not.toBe(reachabilityKey(defaults, "client-1"));
  });
});


test("reachability cache includes the probe implementation and runs when it changes", () => {
  const workflow = readFileSync(new URL("../../.github/workflows/cloud-vm-image-reachability.yml", import.meta.url), "utf8");
  const key = workflow.split("\n").find((line) => line.trim().startsWith("key: devbox-reachable-"))!;
  expect(key).toContain("hashFiles(");
  for (const file of ["web/scripts/check-devbox-image-reachable.ts", "web/scripts/devbox-image-common.ts", "web/services/vms/drivers/cmuxTuiDaemon.ts"]) {
    expect(key).toContain(file);
    // Every probe dependency must trigger both a pull-request and main check.
    expect(workflow.split("  push:")[1]!.split("  schedule:")[0]).toContain(`- ${file}`);
  }
});

describe("devbox reachability provider faults", () => {
  const fault = (status: number, code: string) => Object.assign(new Error(code), { status, code });
  const noSleep = async () => {};

  test("the provider failures main's red runs hit are retried on a fresh machine", () => {
    expect(isProviderFault(fault(429, "INFRASTRUCTURE_OVERLOADED"))).toBe(true);
    expect(isProviderFault(fault(404, "BACKGROUND_REQUEST_NOT_FOUND"))).toBe(true);
    expect(isProviderFault(fault(409, "VM_NON_RESPONSIVE"))).toBe(true);
    expect(isProviderFault(new DOMException("The operation timed out.", "TimeoutError"))).toBe(true);
  });

  test("an image or client failure is a real red, never retried", () => {
    expect(isProviderFault(new Error("live client 9b73ef6697 could not reach the daemon baked from 9f9ba71cc135…: "))).toBe(false);
    expect(isProviderFault(fault(400, "BAD_REQUEST"))).toBe(false);
    expect(isProviderFault(fault(404, "SNAPSHOT_NOT_FOUND"))).toBe(false);
    expect(isProviderFault(undefined)).toBe(false);
  });

  test("a provider fault gets a fresh machine and the second machine's answer stands", async () => {
    const seen: number[] = [];
    const result = await onFreshMachines(async (n) => {
      seen.push(n);
      if (n === 1) throw fault(404, "BACKGROUND_REQUEST_NOT_FOUND");
      return "reachable";
    }, 3, 1, noSleep);
    expect(result).toBe("reachable");
    expect(seen).toEqual([1, 2]);
  });

  test("a real failure stops at the first machine", async () => {
    let calls = 0;
    await expect(onFreshMachines(async () => {
      calls += 1;
      throw new Error("baked client could not reach the daemon");
    }, 3, 1, noSleep)).rejects.toThrow("baked client could not reach the daemon");
    expect(calls).toBe(1);
  });

  test("provider faults on every machine surface after the last attempt", async () => {
    let calls = 0;
    await expect(onFreshMachines(async () => {
      calls += 1;
      throw fault(429, "INFRASTRUCTURE_OVERLOADED");
    }, 3, 1, noSleep)).rejects.toThrow("INFRASTRUCTURE_OVERLOADED");
    expect(calls).toBe(3);
  });
});
