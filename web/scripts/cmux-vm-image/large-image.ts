/**
 * The large image: a second snapshot of the same bake, at the size a default Cloud chat start asks for, so such
 * a machine boots at full size with no resize call after its create (plans/cmux-next/cloud-automation.md 18).
 *
 * A snapshot keeps its source VM's size and resize only grows, so the bake snapshots its builder twice: first as
 * it is (the base's 2 vCPU / 4 GiB / 16 GB, the image every create boots today), then grown to LARGE_IMAGE_SHAPE.
 * Nothing but the resize and read-only checks runs on the builder between the two, so both hold the same tree.
 *
 * This file only makes and checks the image. Which image a create boots is not decided here: the cmux-vm Worker
 * and cmux-platform keep booting the small image and growing it until they are taught to pick this one by the
 * size a create asks for.
 */
import { run, sleep, type Vm } from "./guest";

/**
 * The large image's size: the catalog size `md`, 4 vCPU / 8 GiB of memory / 32 GiB of disk. It mirrors
 * cmux-platform's CHAT_START_SHAPE (src/server/machines/MachineSizes.ts), the size a Cloud chat start asks for
 * and every prewarmed spare is made at, which is being lowered to md together with the app's default machine.
 * Change it only together with that constant: a large image at any other size makes every default start resize
 * again (a smaller one) or boot bigger than was asked (a larger one; nothing shrinks).
 */
export const LARGE_IMAGE_SHAPE = Object.freeze({ vcpu: 4, memGiB: 8, diskGiB: 32 });
export type ImageShape = { vcpu: number; memGiB: number; diskGiB: number };

/**
 * The large snapshot's name and slug: the small image's name plus this suffix. Not a catalog size name (sm, md,
 * lg): the size is LARGE_IMAGE_SHAPE and is recorded beside the name.
 */
export const LARGE_IMAGE_SUFFIX = "-large";
export const largeImageName = (name: string): string => `${name}${LARGE_IMAGE_SUFFIX}`;

/** What the guest reports: vCPUs, MemTotal in MiB and the root filesystem's size in MiB. */
export type GuestShape = { cpu: number; memoryMb: number; rootMb: number };

export const GUEST_SHAPE_COMMAND = "nproc; awk '/MemTotal/{print int($2/1024)}' /proc/meminfo; df -BM --output=size / | tail -1 | tr -dc 0-9";

export function parseGuestShape(stdout: string): GuestShape {
  const [cpu, memoryMb, rootMb] = stdout.trim().split("\n").map((line) => Number(line.trim()));
  return { cpu: cpu ?? Number.NaN, memoryMb: memoryMb ?? Number.NaN, rootMb: rootMb ?? Number.NaN };
}

/**
 * The guest reports a little less than the provider's size: the kernel keeps some memory (8,011 of 8,192 MiB at
 * md) and ext4 its metadata (32,078 of 32,768 MiB at md; cloud-automation.md 19). At least this share of the
 * asked size must show, and never more than the asked size.
 */
export const GUEST_SHAPE_FLOOR = 0.9;

/** Why a guest's shape is not `want`; empty when it is. A root filesystem below the floor has not filled its disk. */
export function shapeProblems(shape: GuestShape, want: ImageShape = LARGE_IMAGE_SHAPE): string[] {
  const problems: string[] = [];
  const within = (label: string, got: number, wantMb: number) => {
    if (!(got >= wantMb * GUEST_SHAPE_FLOOR && got <= wantMb)) problems.push(`${label} ${got} MiB, want ${Math.ceil(wantMb * GUEST_SHAPE_FLOOR)} to ${wantMb}`);
  };
  if (shape.cpu !== want.vcpu) problems.push(`${shape.cpu} vCPU, want ${want.vcpu}`);
  within("memory", shape.memoryMb, want.memGiB * 1024);
  within("root filesystem", shape.rootMb, want.diskGiB * 1024);
  return problems;
}

export async function guestShape(vm: Vm): Promise<GuestShape> {
  return parseGuestShape((await run(vm, GUEST_SHAPE_COMMAND, 30_000)).stdout);
}

/** The root device and filesystem sizes in bytes, for the record. Reports only: shapeProblems is the judge. */
export const ROOT_DEVICE_COMMAND =
  'dev="$(findmnt -no SOURCE / 2>/dev/null || true)"; echo "root-device=${dev:-unknown} device-bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo unknown) fs-bytes=$(df -B1 --output=size / | tail -1 | tr -dc 0-9)"';

/** How long the guest may take to show the new size after the resize calls (the md probe took about 1.3 s). */
export const GROW_BUDGET_MS = 120_000;

export type GrowRecord = { before: GuestShape; after: GuestShape; startedAt: string; cpuMemoryCallMs: number; storageCallMs: number; callMs: number; guestViewMs: number };

/**
 * Grows a running VM to `want` in two provider calls (vCPU and memory, then disk; a slow sample names its phase,
 * as probes.ts resizeProbe does) and waits until the guest shows the size, the root filesystem included. Throws
 * when it does not within the budget: a snapshot taken then would not be the large image.
 */
export async function growToShape(
  vm: Vm,
  want: ImageShape = LARGE_IMAGE_SHAPE,
  deps: { shape?: (vm: Vm) => Promise<GuestShape>; sleep?: (ms: number) => Promise<unknown>; now?: () => number; budgetMs?: number } = {},
): Promise<GrowRecord> {
  const shape = deps.shape ?? guestShape;
  const now = deps.now ?? Date.now;
  const before = await shape(vm);
  const t0 = now();
  const startedAt = new Date(t0).toISOString();
  await vm.resize({ cpu: want.vcpu, memory: want.memGiB * 1024 });
  const cpuMemoryCallMs = now() - t0;
  const t1 = now();
  await vm.resize({ storage: want.diskGiB * 1024 });
  const storageCallMs = now() - t1;
  const callMs = now() - t0;
  let after = await shape(vm);
  while (shapeProblems(after, want).length > 0) {
    if (now() - t0 >= (deps.budgetMs ?? GROW_BUDGET_MS)) throw new Error(`the builder did not reach ${want.vcpu} vCPU / ${want.memGiB} GiB / ${want.diskGiB} GiB: ${shapeProblems(after, want).join("; ")}`);
    await (deps.sleep ?? sleep)(500);
    after = await shape(vm);
  }
  return { before, after, startedAt, cpuMemoryCallMs, storageCallMs, callMs, guestViewMs: now() - t0 };
}

/**
 * The large image's entry in the bake record (bake-<name>.json `large`), beside the small image's own fields. The
 * workflow copies name, id and size into the dev channel candidate's `large` member once the large smoke passed.
 */
export type LargeImageRecord = { name: string; snapshotId: string; size: ImageShape; grow: GrowRecord; rootDevice: string; snapshotMs: number; ms: number };
