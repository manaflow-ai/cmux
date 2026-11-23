import { describe, expect, test } from "bun:test";
import { inventoryFailure } from "../scripts/cmux-vm-image/bake";
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
