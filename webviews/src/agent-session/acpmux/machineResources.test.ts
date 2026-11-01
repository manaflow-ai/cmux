import { describe, expect, test } from "bun:test";
import { machineLoadWarning, peerResourcesFromStatus } from "./machineResources";

const health = (load: number, freeBytes = 12e9, over: string[] = [], loadLimit = 10) => ({
  load: [load, 2, 1],
  cpus: 16,
  ram: { freeBytes },
  pressure: { cores: 10, load_limit: loadLimit, ok: over.length === 0, over },
});
const read = (value: unknown) => peerResourcesFromStatus({ peers: [{ name: "worker", health: value }] }).worker;

describe("cached machine load warnings", () => {
  test("warns at the CPU budget, without clamping overloaded cores", () => {
    expect(machineLoadWarning(read(health(14)))).toEqual({ kind: "load", busy: 14, cores: 10 });
    expect(machineLoadWarning(read(health(10)))).toEqual({ kind: "load", busy: 10, cores: 10 });
    expect(machineLoadWarning(read(health(9.9)))).toBeUndefined();
  });
  test("uses the host budget overrides for CPU and RAM", () => {
    expect(machineLoadWarning(read(health(14, 12e9, [], 20)))).toBeUndefined();
    expect(machineLoadWarning(read(health(5, 1.2e9, ["available RAM 7% < 15%"])))).toEqual({
      kind: "memory",
      freeGB: 1.2,
    });
    // A host that disabled its RAM threshold stays quiet, even with very little free RAM.
    expect(machineLoadWarning(read(health(5, 1e6)))).toBeUndefined();
  });
  test("fine, missing, malformed and unsupported readings stay quiet", () => {
    expect(machineLoadWarning(read(health(3)))).toBeUndefined();
    for (const value of [
      undefined,
      {},
      { ...health(14), unsupported: true },
      health(NaN),
      health(Infinity),
      health(-1),
      health(14, -1),
    ]) {
      expect(machineLoadWarning(read(value))).toBeUndefined();
    }
    expect(peerResourcesFromStatus({})).toEqual({});
  });
  test("switching the setting off suppresses either warning", () => {
    expect(machineLoadWarning(read(health(14)), false)).toBeUndefined();
    expect(machineLoadWarning(read(health(3, 1.2e9, ["available RAM 7% < 10%"])), false)).toBeUndefined();
  });
});
