import { describe, expect, test } from "bun:test";
import { bakeOptionsFromArgv } from "../scripts/cmux-vm-image/bake";
import type { Vm } from "../scripts/cmux-vm-image/guest";
import { type GuestShape, growToShape, LARGE_IMAGE_SHAPE, largeImageName, MEMORY_GUARD_REFRESH_COMMAND, memoryGuardProblems, parseGuestShape, ROOT_DEVICE_COMMAND, shapeProblems } from "../scripts/cmux-vm-image/large-image";
import { bootShapeCheck, identityChecks } from "../scripts/cmux-vm-image/large-smoke";
import { historyEntry } from "../scripts/cmux-vm-image/promote-record";
import { guestShellProblems } from "../scripts/cmux-vm-image/shell-check";

// The large image (large-image.ts): the bake's second snapshot, at the default Cloud chat start size. These run
// the grow and the judgments on fakes; the provider half runs only in cloud-vm-image-bake.yml.

const SM: GuestShape = { cpu: 2, memoryMb: 3915, rootMb: 15990 };
// About what a guest shows at 2 vCPU / 4 GiB / 20 GiB: a little under 4,096 MiB of memory and 20,480 MiB of root.
const LARGE: GuestShape = { cpu: 2, memoryMb: 3915, rootMb: 19990 };
// The catalog size md (plans/cmux-next/cloud-automation.md 19): the nearest ladder size, and not this image's.
const LADDER_M: GuestShape = { cpu: 4, memoryMb: 8011, rootMb: 32078 };

describe("LARGE_IMAGE_SHAPE", () => {
  test("is the platform's chat start shape, 2 vCPU / 4 GiB / 20 GiB", () => {
    expect(LARGE_IMAGE_SHAPE).toEqual({ vcpu: 2, memGiB: 4, diskGiB: 20 });
    expect(Object.isFrozen(LARGE_IMAGE_SHAPE)).toBe(true);
  });

  test("the large snapshot is named after the image, and still a cmuxnp-dev-vmimg- name", () => {
    expect(largeImageName("cmuxnp-dev-vmimg-ci-4242-1")).toBe("cmuxnp-dev-vmimg-ci-4242-1-large");
  });
});

describe("shapeProblems", () => {
  test("a guest at the large size passes", () => {
    expect(shapeProblems(LARGE)).toEqual([]);
    expect(shapeProblems(parseGuestShape("2\n3915\n19990\n"))).toEqual([]);
  });

  test("the small image's own size names every axis", () => {
    expect(shapeProblems(SM)).toEqual(["root filesystem 15990 MiB, want 18432 to 20480"]);
  });

  test("the catalog size md is not the large image: same vCPUs, half the memory and disk", () => {
    expect(shapeProblems(LADDER_M)).toEqual(["4 vCPU, want 2", "memory 8011 MiB, want 3687 to 4096", "root filesystem 32078 MiB, want 18432 to 20480"]);
  });

  test("a disk that grew under a filesystem that did not is a problem", () => {
    expect(shapeProblems({ ...LARGE, rootMb: 15990 })).toEqual(["root filesystem 15990 MiB, want 18432 to 20480"]);
  });

  test("a machine bigger than the large size is not the large image either", () => {
    expect(shapeProblems({ cpu: 4, memoryMb: 32100, rootMb: 128500 })).toHaveLength(2);
    expect(shapeProblems({ ...LARGE, cpu: 8 })).toEqual(["8 vCPU, want 4"]);
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
  test("grows only the disk when the base already has the vCPUs and memory, and waits until the guest shows all three", async () => {
    // Before, then right after the calls the filesystem still has its old size, then the full shape.
    const fake = fakeVm([SM, { ...LARGE, rootMb: 15990 }, LARGE]);
    const grow = await growToShape(fake.vm, LARGE_IMAGE_SHAPE, fake.deps);
    expect(fake.calls).toEqual([{ storage: 20480 }]);
    expect(grow).toMatchObject({ before: SM, after: LARGE, cpuMemoryCallMs: 0, storageCallMs: 200, callMs: 200, guestViewMs: 700 });
  });

  test("grows vCPU and memory, then disk, when the builder is smaller than the image", async () => {
    const tiny: GuestShape = { cpu: 1, memoryMb: 1900, rootMb: 15990 };
    const fake = fakeVm([tiny, { ...LARGE, rootMb: 15990 }, LARGE]);
    await growToShape(fake.vm, LARGE_IMAGE_SHAPE, fake.deps);
    expect(fake.calls).toEqual([{ cpu: 2, memory: 4096 }, { storage: 20480 }]);
  });

  test("throws when the guest never shows the size, so no snapshot is taken", async () => {
    const fake = fakeVm([SM, { ...LARGE, rootMb: 15990 }]);
    await expect(growToShape(fake.vm, LARGE_IMAGE_SHAPE, { ...fake.deps, budgetMs: 5_000 })).rejects.toThrow(/did not reach 2 vCPU \/ 4 GiB \/ 20 GiB: root filesystem 15990 MiB/);
    expect(fake.reads()).toBeGreaterThan(5);
  });

  test("the guest steps are /bin/sh", () => {
    expect(guestShellProblems(ROOT_DEVICE_COMMAND).refused).toEqual([]);
    expect(guestShellProblems(MEMORY_GUARD_REFRESH_COMMAND).refused).toEqual([]);
  });
});

describe("memory guards after the grow", () => {
  test("the reload comes before the read, so the limit read is the one the snapshot keeps", () => {
    expect(MEMORY_GUARD_REFRESH_COMMAND.startsWith("systemctl daemon-reload && ")).toBe(true);
  });

  test("a user.slice limit still at 90% of the small size is refused", () => {
    // What the first large bake's clones showed: the small size's limit on a grown machine.
    expect(memoryGuardProblems("user-slice-max=3694657536\nmemtotal=8400146432\n")).toEqual(["user.slice memory.max 3694657536 of 8400146432 bytes (want 90%)"]);
    expect(memoryGuardProblems("user-slice-max=3694657536\nmemtotal=16785604608\n")).toHaveLength(1);
  });

  test("a limit that followed the memory passes", () => {
    expect(memoryGuardProblems("user-slice-max=15107043328\nmemtotal=16785604608\n")).toEqual([]);
  });

  test("no limit, or an unreadable answer, fails closed", () => {
    expect(memoryGuardProblems("user-slice-max=max\nmemtotal=16785604608\n")).toHaveLength(1);
    expect(memoryGuardProblems("")).toHaveLength(1);
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
    expect(bootShapeCheck([LARGE, LARGE])).toMatchObject({ ok: true });
    expect(bootShapeCheck([LARGE, SM])).toMatchObject({ ok: false });
    expect(bootShapeCheck([LARGE, SM]).detail).toContain("clone 2: 2 vCPU, want 4");
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
  const large = { snapshot: "cmuxnp-dev-vmimg-ci-4242-1-large", snapshot_id: `sh-${"2".repeat(32)}`, size: { vcpu: 2, mem_gib: 4, disk_gib: 20 }, smoke: { result: "PASSED" } };

  test("is recorded as today's entry plus `large`: every field a reader knows is unchanged", () => {
    const without = historyEntry(base, snapshot, "4242");
    const withLarge = historyEntry({ ...base, large }, snapshot, "4242");
    expect(withLarge).toEqual({ ...without, large });
    expect(withLarge.snapshot_id).toBe(snapshot);
  });
});
