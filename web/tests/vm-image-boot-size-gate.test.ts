import { describe, expect, test } from "bun:test";
import { BASE_BOOT_LIMIT, oversizedBoot } from "../scripts/cmux-vm-image/boot-size";

// smoke.ts boots-at-base-size: a clone of the image, read before the resize probe grows it, is at most the chat start
// size. An image whose snapshot carries a grown builder's size would boot every default create larger than asked.
describe("boots-at-base-size", () => {
  test("a clone at the base size passes (bake 45914212699's clone: 2 vCPU, 3915 MiB, root 15955 MiB)", () => {
    expect(oversizedBoot({ cpu: 2, memoryMb: 3915, rootMb: 15955 })).toBeNull();
    expect(oversizedBoot({ cpu: BASE_BOOT_LIMIT.cpu, memoryMb: BASE_BOOT_LIMIT.memoryMb, rootMb: BASE_BOOT_LIMIT.rootMb })).toBeNull();
  });

  test("a clone over it on any axis is refused, naming the axes", () => {
    expect(oversizedBoot({ cpu: 16, memoryMb: 32587, rootMb: 128828 })).toContain("cpu, memoryMb, rootMb");
    expect(oversizedBoot({ cpu: 2, memoryMb: 3915, rootMb: 32078 })).toContain("on rootMb:");
    expect(oversizedBoot({ cpu: Number.NaN, memoryMb: 3915, rootMb: 15955 })).toContain("on cpu:");
  });
});
