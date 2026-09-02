#!/usr/bin/env bun
/**
 * Derive sized snapshots from one baked devbox snapshot.
 *
 * A Freestyle VM boots at its snapshot's size and resize is grow-only, so the
 * bake happens once on the smallest ladder shape and every larger size is
 * "boot the master, resize to the ladder row, snapshot, delete". Each derived
 * snapshot then boots straight into its shape: no account-level size
 * override, nothing to grow at create.
 *
 * Usage:
 *   FREESTYLE_API_KEY=... bun scripts/derive-devbox-sizes.ts <master-snapshot-id> <slug-prefix>
 *       [--sizes sm,md,lg,xl,2xl] [--out <json>] [--replace-slug]
 *
 * Prints one line per size and a final JSON `{ sizes: { <name>: { imageId, slug, size } } }`
 * (also written to --out). Every derived VM is booted once more from its own
 * snapshot and checked (nproc, memory, root filesystem, the cmux-tui-daemon
 * and cmux-desktop units) before its id is reported; a failed check aborts.
 *
 * The master must be at or below every requested size (bake on
 * freestyle/ubuntu-sm for the full ladder). `sm` is the master itself when
 * the master already has that shape, so it is recorded without a second
 * snapshot.
 */
import { Freestyle, type FirewallSpec } from "freestyle";
import { writeFileSync } from "node:fs";
import {
  VM_IMAGE_SIZE_NAMES,
  isVmImageSizeName,
  vmImageSize,
  type VmImageSize,
  type VmImageSizeName,
} from "../services/vms/images/sizes";
import { argValue, devboxParkDaemonCommand, hasFlag } from "./devbox-image-common";

const apiKey = process.env.FREESTYLE_API_KEY;
const stackToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN;
const teamId = process.env.FREESTYLE_TEAM_ID;
const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
const fs = (() => {
  if (apiKey) return new Freestyle({ apiKey, baseUrl });
  if (stackToken && teamId) return new Freestyle({ stackAccessToken: stackToken, teamId, baseUrl });
  throw new Error("set FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID");
})();

const master = process.argv[2];
const slugPrefix = process.argv[3];
if (!master || master.startsWith("--") || !slugPrefix || slugPrefix.startsWith("--")) {
  throw new Error("usage: bun scripts/derive-devbox-sizes.ts <master-snapshot-id> <slug-prefix> [--sizes sm,md,lg,xl,2xl] [--out <json>] [--replace-slug]");
}
const requested = (argValue("--sizes") ?? VM_IMAGE_SIZE_NAMES.join(",")).split(",").map((s) => s.trim()).filter(Boolean);
for (const name of requested) {
  if (!isVmImageSizeName(name)) throw new Error(`--sizes: unknown size ${name}; expected ${VM_IMAGE_SIZE_NAMES.join(", ")}`);
}
const sizes = requested as VmImageSizeName[];
const replaceSlug = hasFlag("--replace-slug");

const FIREWALL: FirewallSpec = { rules: [{ action: "allow", source: {}, destination: { public: true } }] };
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Exec = { exec: (options: { command: string; timeoutMs?: number; linuxUser?: string }) => Promise<{ stdout?: string | null; stderr?: string | null; statusCode?: number | null }> };
async function sh(vm: Exec, command: string, timeoutMs = 120_000): Promise<{ code: number; out: string }> {
  const r = await vm.exec({ command, timeoutMs, linuxUser: "root" });
  return { code: r.statusCode ?? 124, out: `${r.stdout ?? ""}${r.stderr ?? ""}`.trim() };
}

/** What the guest sees; disk is the root filesystem after the grow. */
async function measure(vm: Exec): Promise<{ cpu: number; memoryMb: number; rootMb: number; units: string }> {
  const r = await sh(vm, "echo cpu=$(nproc); echo mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo); echo root=$(df -BM --output=size / | tail -1 | tr -dc 0-9); echo units=$(systemctl is-active cmux-tui-daemon cmux-desktop 2>/dev/null | tr '\\n' ',')");
  const get = (key: string) => r.out.match(new RegExp(`${key}=([^\\n]*)`))?.[1] ?? "";
  return { cpu: Number(get("cpu")), memoryMb: Number(get("mem")), rootMb: Number(get("root")), units: get("units") };
}

/** Guest memory is a little under the allocation (kernel reservations); the root fs a little under the disk. */
function fits(actual: { cpu: number; memoryMb: number; rootMb: number }, size: VmImageSize): string | null {
  if (actual.cpu < size.cpu) return `cpu ${actual.cpu} < ${size.cpu}`;
  if (actual.memoryMb < size.memoryMb * 0.9) return `memory ${actual.memoryMb} MiB < ${size.memoryMb} MiB`;
  if (actual.rootMb < size.storageMb * 0.85) return `root fs ${actual.rootMb} MiB < ${size.storageMb} MiB (disk not grown?)`;
  return null;
}

async function assignSlug(snapshotId: string, slug: string): Promise<string | null> {
  try {
    await fs.vms.snapshots.update(snapshotId, { slug });
    return slug;
  } catch (error) {
    if (!replaceSlug) {
      console.warn(`  slug ${slug} not assigned (${String(error).slice(0, 120)}); pass --replace-slug to move it`);
      return null;
    }
    const { snapshots } = await fs.vms.snapshots.list();
    const holder = snapshots.find((candidate) => candidate.slug === slug && candidate.id !== snapshotId);
    if (!holder) throw error;
    await fs.vms.snapshots.update(holder.id, { slug: "" });
    await fs.vms.snapshots.update(snapshotId, { slug });
    return slug;
  }
}

const result: Record<string, { imageId: string; slug: string | null; size: VmImageSize; measured: unknown }> = {};

// The master's own shape, so a size it already has is recorded without a copy.
const probe = await fs.vms.create({ snapshotId: master, displayName: `${slugPrefix} size-probe`, firewall: FIREWALL });
const masterShape = await measure(probe.vm);
await probe.vm.delete();
console.log(`master ${master}: ${masterShape.cpu} vCPU, ${masterShape.memoryMb} MiB, root ${masterShape.rootMb} MiB`);

for (const name of sizes) {
  const size = vmImageSize(name);
  const slug = name === "md" ? slugPrefix : `${slugPrefix}-${name}`;
  const t0 = Date.now();
  let imageId: string;

  if (masterShape.cpu === size.cpu && Math.abs(masterShape.memoryMb - size.memoryMb) < size.memoryMb * 0.1 && masterShape.rootMb >= size.storageMb * 0.85) {
    imageId = master;
    console.log(`${name}: master already has this shape; reusing ${master}`);
  } else {
    if (masterShape.cpu > size.cpu || masterShape.memoryMb > size.memoryMb) {
      throw new Error(`${name}: master (${masterShape.cpu} vCPU, ${masterShape.memoryMb} MiB) is larger than the target; resize is grow-only, bake on a smaller base`);
    }
    const { vm } = await fs.vms.create({ snapshotId: master, displayName: `${slugPrefix} derive ${name}`, firewall: FIREWALL });
    try {
      await vm.resize({ cpu: size.cpu, memory: size.memoryMb, storage: size.storageMb });
      // The disk grows in place while the guest runs; wait for the root fs to
      // reflect it, then let the daemon units settle before the snapshot.
      let grown: Awaited<ReturnType<typeof measure>> | null = null;
      for (let i = 0; i < 30; i += 1) {
        const m = await measure(vm);
        if (!fits(m, size)) { grown = m; break; }
        await sleep(2000);
      }
      if (!grown) {
        const m = await measure(vm);
        throw new Error(`${name}: resize did not take: ${fits(m, size)} (${JSON.stringify(m)})`);
      }
      // A resized clone runs a live daemon bound to its own instance id; park
      // it so the derived snapshot, like the master, carries no identity.
      const parked = await sh(vm, devboxParkDaemonCommand(), 120_000);
      if (parked.code !== 0) throw new Error(`${name}: could not park the cmux-tui daemon before the snapshot: ${parked.out.slice(-500)}`);
      await sh(vm, "sync");
      const snap = await vm.snapshot({ displayName: `cmux devbox ${slug} (${size.cpu} vCPU · ${size.memoryMb} MiB · ${size.storageMb} MiB)` });
      if (!snap.snapshotId) throw new Error(`${name}: snapshot response carried no id`);
      imageId = snap.snapshotId;
    } finally {
      await vm.delete().catch(() => {});
    }
  }

  // Boot the derived snapshot itself: the shape must survive the round trip.
  const check = await fs.vms.create({ snapshotId: imageId, displayName: `${slugPrefix} verify ${name}`, firewall: FIREWALL });
  let measured: Awaited<ReturnType<typeof measure>>;
  try {
    measured = await measure(check.vm);
    const problem = fits(measured, size);
    if (problem) throw new Error(`${name}: derived snapshot ${imageId} boots wrong: ${problem}`);
    if (!measured.units.includes("active")) throw new Error(`${name}: units not active after boot: ${measured.units}`);
    // The parked daemon must come back by itself on the derived shape, bound
    // to this machine and listening dual-stack.
    let daemon = { code: 1, out: "" };
    for (let i = 0; i < 30 && daemon.code !== 0; i += 1) {
      daemon = await sh(check.vm, "env HOME=/root /root/.cmux/bin/cmux-tui server status --session cloud >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6 && test -s /etc/cmux/daemon-instance-id && echo daemon-up", 30_000);
      if (daemon.code !== 0) await sleep(1000);
    }
    if (daemon.code !== 0) throw new Error(`${name}: cmux-tui daemon did not come up on the derived snapshot ${imageId}: ${daemon.out.slice(-300)}`);
  } finally {
    await check.vm.delete().catch(() => {});
  }

  const assigned = imageId === master ? null : await assignSlug(imageId, slug);
  result[name] = { imageId, slug: assigned, size, measured };
  console.log(`${name}: ${imageId} (${measured.cpu} vCPU, ${measured.memoryMb} MiB, root ${measured.rootMb} MiB, units ${measured.units}) ${((Date.now() - t0) / 1000).toFixed(0)}s`);
}

const out = { master, sizes: result };
console.log(JSON.stringify(out, null, 2));
const outPath = argValue("--out");
if (outPath) writeFileSync(outPath, `${JSON.stringify(out, null, 2)}\n`);
