/**
 * Bring a running Cloud machine onto the cmux guest kernel (guest-kernel.ts), keeping its disk.
 *
 * Usage (from web/):
 *   bun ../images/cmux-vm/guest-kernel-install.ts --vm <vm-id> --bake-json <out-dir>/bake-<name>.json
 *       [--switch-now] [--out-dir <dir>]
 *
 * The kernel comes from a bake's output (the workflow artifact holds `vmlinuz-<release>` next to
 * `bake-<name>.json`, whose guestKernel.sha256 it must match). The script writes the kernel, the
 * cmux-guest-kernel script, its shutdown hook and units, checks that the machine runs the provider
 * kernel the lock's kernel was configured from (or a cmux kernel installed earlier, which this
 * replaces), clears the switch attempt count and loads the kernel once without switching.
 *
 * Without --switch-now nothing running changes: the machine switches at its next cold boot (power
 * off and start). --switch-now switches at once: systemd stops every unit cleanly and the machine
 * comes back on the cmux kernel in about 10 to 20 s, with its files intact and every process,
 * terminal and session ended. Only with the owner's consent.
 */
import { mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { argValue, freestyleClient, hasFlag, run, StepLog, type Vm } from "./guest";
import {
  GUEST_KERNEL_CLI,
  GUEST_KERNEL_DIRS_COMMAND,
  GUEST_KERNEL_IMAGE,
  guestKernelConfigCheckCommand,
  guestKernelFiles,
  guestKernelInstallCommand,
  guestKernelProblems,
  sha256Hex,
  switchToGuestKernel,
} from "./guest-kernel";
import { readInputsLock, sq } from "./lock";

/** A kernel the bake built: guest-kernel.ts builds with KBUILD_BUILD_HOST=cmux-vm-image, which /proc/version names. */
export function isCmuxKernelVersion(procVersion: string): boolean {
  return /^Linux version \S+ \(cmux@cmux-vm-image\)/.test(procVersion);
}

export type InstallOptions = { vmId: string; bakeJson: string; switchNow: boolean; outDir: string };

/** The kernel a bake built: its bytes, checked against the bake result's sha256 and release. */
export function bakedKernel(bakeJson: string, release: string): { bytes: Uint8Array; sha256: string } {
  const bake = JSON.parse(readFileSync(bakeJson, "utf8")) as { guestKernel?: { release?: string; sha256?: string } };
  const recorded = bake.guestKernel;
  if (!recorded?.sha256 || recorded.release !== release) throw new Error(`${bakeJson} records kernel ${recorded?.release ?? "none"}, the lock pins ${release}`);
  const bytes = new Uint8Array(readFileSync(path.join(path.dirname(bakeJson), `vmlinuz-${release}`)));
  const sha256 = sha256Hex(bytes);
  if (sha256 !== recorded.sha256) throw new Error(`vmlinuz-${release} sha256 ${sha256} is not the bake's ${recorded.sha256}`);
  return { bytes, sha256 };
}

async function writeRootFile(vm: Vm, target: string, bytes: Uint8Array, mode: number): Promise<void> {
  await vm.fs.writeFile(target, bytes, { mode });
  const r = await run(vm, `chown root:root ${sq(target)} && chmod ${mode.toString(8)} ${sq(target)}`);
  if (r.code !== 0) throw new Error(`chown ${target}: ${r.stderr.slice(-300)}`);
}

export async function install(options: InstallOptions): Promise<string> {
  const lock = readInputsLock();
  const kernel = bakedKernel(options.bakeJson, lock.kernel.version);
  mkdirSync(options.outDir, { recursive: true });
  const L = new StepLog(path.join(options.outDir, `guest-kernel-install-${options.vmId}.log`));
  const vm = freestyleClient().vms.ref(options.vmId) as unknown as Vm;
  // The provider kernel, or a cmux kernel (an upgrade in place). A cmux kernel is known by the
  // build host in its version string, not by the release file, which a failed upgrade has already
  // replaced.
  const [running, version = ""] = (await L.step(vm, "running-kernel", "uname -r && cat /proc/version")).trim().split("\n");
  const provider = lock.base.fingerprint.kernelRelease;
  if (running !== provider && !isCmuxKernelVersion(version)) {
    throw new Error(`${options.vmId} runs kernel ${running}, neither the provider's ${provider} nor an installed cmux kernel`);
  }
  await L.step(vm, "kernel-config-check", guestKernelConfigCheckCommand(lock.kernel, provider));
  await L.step(vm, "kernel-dirs", GUEST_KERNEL_DIRS_COMMAND);
  await writeRootFile(vm, GUEST_KERNEL_IMAGE, kernel.bytes, 0o644);
  for (const file of guestKernelFiles()) await writeRootFile(vm, file.path, file.bytes, file.mode);
  await L.step(vm, "kernel-install", guestKernelInstallCommand(lock.kernel, kernel.sha256));
  if (options.switchNow) {
    await switchToGuestKernel(vm, L, lock.kernel.version);
    const problems = guestKernelProblems(lock.kernel, await L.step(vm, "kernel-status", `${GUEST_KERNEL_CLI} status`));
    if (problems.length > 0) throw new Error(`after the switch: ${problems.join("; ")}`);
    return `${options.vmId}: running ${lock.kernel.version}`;
  }
  return `${options.vmId}: ${lock.kernel.version} installed; the machine switches at its next cold boot (or rerun with --switch-now)`;
}

export function optionsFromArgv(argv = process.argv): InstallOptions {
  const vmId = argValue("--vm", argv);
  const bakeJson = argValue("--bake-json", argv);
  if (!vmId || !bakeJson) throw new Error("usage: guest-kernel-install.ts --vm <vm-id> --bake-json <out-dir>/bake-<name>.json [--switch-now] [--out-dir <dir>]");
  return { vmId, bakeJson: path.resolve(bakeJson), switchNow: hasFlag("--switch-now", argv), outDir: path.resolve(argValue("--out-dir", argv) ?? "guest-kernel-install-out") };
}

/** CLI entry (images/cmux-vm/guest-kernel-install.ts). */
export async function main(argv = process.argv): Promise<number> {
  try {
    console.log(await install(optionsFromArgv(argv)));
    return 0;
  } catch (error) {
    console.error(`guest-kernel-install: ${String(error)}`);
    return 1;
  }
}
