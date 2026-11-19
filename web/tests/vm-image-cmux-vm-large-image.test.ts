import { describe, expect, test } from "bun:test";
import { bakeOptionsFromArgv } from "../scripts/cmux-vm-image/bake";
import type { Vm } from "../scripts/cmux-vm-image/guest";
import { type GuestShape, growToShape, LARGE_IMAGE_SHAPE, largeImageName, parseGuestShape, ROOT_DEVICE_COMMAND, shapeProblems } from "../scripts/cmux-vm-image/large-image";
import { bootShapeCheck, identityChecks } from "../scripts/cmux-vm-image/large-smoke";
import { historyEntry } from "../scripts/cmux-vm-image/promote-record";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";

// The large image (large-image.ts): the bake's second snapshot, at the default Cloud chat start size. These run
// the grow and the judgments on fakes; the provider half runs only in cloud-vm-image-bake.yml.

const SM: GuestShape = { cpu: 2, memoryMb: 3915, rootMb: 15990 };
// What a guest shows at md (plans/cmux-next/cloud-automation.md 19: 4 vCPU, 8,011 MiB, 32,078 MiB root).
const MD: GuestShape = { cpu: 4, memoryMb: 8011, rootMb: 32078 };

describe("LARGE_IMAGE_SHAPE", () => {
  test("is the catalog size md, the platform's chat start shape", () => {
    expect(LARGE_IMAGE_SHAPE).toEqual({ vcpu: 4, memGiB: 8, diskGiB: 32 });
    expect(Object.isFrozen(LARGE_IMAGE_SHAPE)).toBe(true);
  });

  test("the large snapshot is named after the image, and still a cmuxnp-dev-vmimg- name", () => {
    expect(largeImageName("cmuxnp-dev-vmimg-ci-4242-1")).toBe("cmuxnp-dev-vmimg-ci-4242-1-large");
  });
});

describe("shapeProblems", () => {
  test("a guest at the large size passes", () => {
    expect(shapeProblems(MD)).toEqual([]);
    expect(shapeProblems(parseGuestShape("4\n8011\n32078\n"))).toEqual([]);
  });

  test("the small image's own size names every axis", () => {
    expect(shapeProblems(SM)).toEqual(["2 vCPU, want 4", "memory 3915 MiB, want 7373 to 8192", "root filesystem 15990 MiB, want 29492 to 32768"]);
  });

  test("a disk that grew under a filesystem that did not is a problem", () => {
    expect(shapeProblems({ ...MD, rootMb: 15990 })).toEqual(["root filesystem 15990 MiB, want 29492 to 32768"]);
  });

  test("a machine bigger than the large size is not the large image either", () => {
    expect(shapeProblems({ cpu: 4, memoryMb: 16008, rootMb: 64200 })).toHaveLength(2);
    expect(shapeProblems({ ...MD, cpu: 8 })).toEqual(["8 vCPU, want 4"]);
  });

  test("an unreadable shape fails closed", () => {
    expect(shapeProblems(parseGuestShape(""))).toHaveLength(3);
  });
});

/** A VM whose guest shows `shapes` in order (the last one repeats) and records its resize calls. */
function fakeVm(shapes: GuestShape[]) {
  const calls: Array<Record<string, number>> = [];
  let reads = 0;
  let clock = 0;
  const vm = { resize: async (options: Record<string, number>) => { calls.push(options); clock += 200; } } as unknown as Vm;
  return {
    vm,
    calls,
    reads: () => reads,
    deps: {
      shape: async () => shapes[Math.min(reads++, shapes.length - 1)]!,
      sleep: async (ms: number) => { clock += ms; },
      now: () => clock,
    },
  };
}

describe("growToShape", () => {
  test("grows vCPU and memory, then disk, and waits until the guest shows all three", async () => {
    // Before, then right after the calls the filesystem still has its old size, then the full shape.
    const fake = fakeVm([SM, { ...MD, rootMb: 15990 }, MD]);
    const grow = await growToShape(fake.vm, LARGE_IMAGE_SHAPE, fake.deps);
    expect(fake.calls).toEqual([{ cpu: 4, memory: 8192 }, { storage: 32768 }]);
    expect(grow).toMatchObject({ before: SM, after: MD, cpuMemoryCallMs: 200, storageCallMs: 200, callMs: 400, guestViewMs: 900 });
  });

  test("throws when the guest never shows the size, so no snapshot is taken", async () => {
    const fake = fakeVm([SM, { ...MD, rootMb: 15990 }]);
    await expect(growToShape(fake.vm, LARGE_IMAGE_SHAPE, { ...fake.deps, budgetMs: 5_000 })).rejects.toThrow(/did not reach 4 vCPU \/ 8 GiB \/ 32 GiB: root filesystem 15990 MiB/);
    expect(fake.reads()).toBeGreaterThan(5);
  });

  test("the guest steps are /bin/sh", () => {
    expect(guestShellProblems(ROOT_DEVICE_COMMAND).refused).toEqual([]);
  });
});

describe("bake.ts --large", () => {
  test("is off by default and on with the flag", () => {
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t"]).large).toBe(false);
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--large"]).large).toBe(true);
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--layered", "--defer-inventory", "--large"])).toMatchObject({ layered: true, large: true });
  });

  for (const other of ["--promotion", "--prod-copy", "--team-vm", "--dev-tree"]) {
    test(`refuses ${other}: the large image is a dev snapshot of the personal Cloud image`, () => {
      expect(() => bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--large", other])).toThrow(/--large is for dev snapshots of the personal Cloud image/);
    });
  }
});

describe("large smoke judgments", () => {
  test("every clone must show the large size on its first read", () => {
    expect(bootShapeCheck([MD, MD])).toMatchObject({ ok: true });
    expect(bootShapeCheck([MD, SM])).toMatchObject({ ok: false });
    expect(bootShapeCheck([MD, SM]).detail).toContain("clone 2: 2 vCPU, want 4");
    expect(bootShapeCheck([])).toMatchObject({ ok: false });
  });

  test("two clones are bound to their own instance with their own identity and host key", () => {
    const id = (n: string) => ({ instance: `i-${n}`, bound: `i-${n}`, "identity-present": "1", daemon: `d${n}`.repeat(8), sshkey: `SHA256:${n}` });
    expect(Object.values(identityChecks([id("a"), id("b")])).every((c) => c.ok)).toBe(true);
    // The builder's own identity in the snapshot: both clones would carry it.
    const shared = identityChecks([id("a"), { ...id("b"), daemon: id("a").daemon, sshkey: id("a").sshkey }]);
    expect(shared["daemon-identity-differs"]!.ok).toBe(false);
    expect(shared["ssh-host-key-differs"]!.ok).toBe(false);
    expect(identityChecks([id("a"), { ...id("b"), bound: "i-a" }])["daemon-bound"]!.ok).toBe(false);
    expect(identityChecks([id("a")])["daemon-identity-differs"]!.ok).toBe(false);
  });
});

describe("a candidate that records the large image", () => {
  const snapshot = `sh-${"1".repeat(32)}`;
  const base = { schema: 1, env: "dev", var: "CLOUD_FREESTYLE_SNAPSHOT", snapshot: "cmuxnp-dev-vmimg-ci-4242-1", snapshot_id: snapshot, lock_sha256: "f".repeat(64), run: 4242, smoke: { result: "PASSED" } };
  const large = { snapshot: "cmuxnp-dev-vmimg-ci-4242-1-large", snapshot_id: `sh-${"2".repeat(32)}`, size: { vcpu: 4, mem_gib: 8, disk_gib: 32 }, smoke: { result: "PASSED" } };

  test("is recorded as today's entry plus `large`: every field a reader knows is unchanged", () => {
    const without = historyEntry(base, snapshot, "4242");
    const withLarge = historyEntry({ ...base, large }, snapshot, "4242");
    expect(withLarge).toEqual({ ...without, large });
    expect(withLarge.snapshot_id).toBe(snapshot);
  });
});
