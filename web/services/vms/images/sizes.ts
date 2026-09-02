/**
 * Machine sizes: Freestyle's t-shirt ladder, verbatim from
 * `freestyle-vms/catalog/snapshots.json` (the file that seeds both its dev and
 * production platforms). A Freestyle VM always boots at its snapshot's size,
 * so cmux keeps one snapshot per size, derived from a single bake by
 * resize + snapshot (`scripts/derive-devbox-sizes.ts`). Freestyle pins these
 * shapes to its plan caps (Free `md`, Hobby `lg`, Pro `2xl`), and a size a
 * plan cannot boot is simply not creatable by it, so inventing shapes
 * outside the ladder buys nothing.
 *
 * `md` is Freestyle's bare default slug (`freestyle/ubuntu`); the others keep
 * Freestyle's suffixes.
 */
export type VmImageSizeName = "sm" | "md" | "lg" | "xl" | "2xl";

export type VmImageSize = {
  readonly name: VmImageSizeName;
  readonly cpu: number;
  /** MiB, the unit the Freestyle API and cmux's plan knobs both use. */
  readonly memoryMb: number;
  /** MiB (a "64 GB" disk is 65536, matching how Freestyle counts). */
  readonly storageMb: number;
  /** The Freestyle base snapshot with this exact shape. */
  readonly freestyleBase: string;
};

export const VM_IMAGE_SIZES: readonly VmImageSize[] = [
  { name: "sm", cpu: 2, memoryMb: 4096, storageMb: 16384, freestyleBase: "freestyle/ubuntu-sm" },
  { name: "md", cpu: 4, memoryMb: 8192, storageMb: 32768, freestyleBase: "freestyle/ubuntu" },
  { name: "lg", cpu: 8, memoryMb: 16384, storageMb: 65536, freestyleBase: "freestyle/ubuntu-lg" },
  { name: "xl", cpu: 16, memoryMb: 32768, storageMb: 131072, freestyleBase: "freestyle/ubuntu-xl" },
  { name: "2xl", cpu: 32, memoryMb: 65536, storageMb: 131072, freestyleBase: "freestyle/ubuntu-2xl" },
];

export const VM_IMAGE_SIZE_NAMES: readonly VmImageSizeName[] = VM_IMAGE_SIZES.map((size) => size.name);

export function isVmImageSizeName(value: unknown): value is VmImageSizeName {
  return typeof value === "string" && (VM_IMAGE_SIZE_NAMES as readonly string[]).includes(value);
}

export function vmImageSize(name: VmImageSizeName): VmImageSize {
  const size = VM_IMAGE_SIZES.find((candidate) => candidate.name === name);
  if (!size) throw new Error(`unknown machine size ${name}`);
  return size;
}

/** Ladder order, so "smallest that fits" is a plain scan. */
export function vmImageSizeRank(name: VmImageSizeName): number {
  return VM_IMAGE_SIZE_NAMES.indexOf(name);
}

/**
 * The smallest ladder size whose memory is at least `memoryMb` (the plan's
 * size), or null when the request is above the ladder. cmux's plan knobs are
 * expressed in memory only; vCPU and disk follow the ladder row.
 */
export function pickVmImageSizeForMemory(memoryMb: number): VmImageSize | null {
  return VM_IMAGE_SIZES.find((size) => size.memoryMb >= memoryMb) ?? null;
}
