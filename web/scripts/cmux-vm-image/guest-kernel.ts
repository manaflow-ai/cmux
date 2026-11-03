/**
 * The cmux guest kernel (inputs.lock.json `kernel`): a kernel.org stable release
 * built with the provider base's own configuration, run instead of the provider's
 * kernel. Freestyle boots every machine with its own kernel and has no kernel
 * setting, so the image switches with kexec (images/cmux-vm/guest/cmux-guest-kernel):
 *
 * - buildGuestKernel: a throwaway builder VM (lock.kernel.builder, many vCPUs)
 *   downloads the locked tarball, checks its sha256 and kernel.org's sha256sums
 *   entry, refuses a base whose /proc/config.gz differs from the lock, runs
 *   `make olddefconfig bzImage` with a fixed build timestamp, user and host, and
 *   hands back the bzImage. The builder is deleted whatever happens.
 * - The bake installs it with the script, the shutdown hook and the units
 *   (guestKernelFiles + guestKernelInstallCommand), switches the builder VM to it
 *   before anything runs that must survive into the snapshot, and checks the
 *   release afterwards. A clone resumes from the memory snapshot on the cmux
 *   kernel; a cold boot switches back through cmux-guest-kernel.timer.
 * - guest-kernel-install.ts uses the same files to bring a running machine over.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Freestyle } from "freestyle";
import { createVm, deleteVm, firstExec, readGuestBytes, run, sleep, type Ledger, type StepLog, type Vm } from "./guest";
import { sq, type GuestKernelLock } from "./lock";

export const GUEST_KERNEL_DIR = "/usr/lib/cmux/kernel";
export const GUEST_KERNEL_IMAGE = `${GUEST_KERNEL_DIR}/vmlinuz`;
export const GUEST_KERNEL_CLI = "/usr/local/sbin/cmux-guest-kernel";
export const GUEST_KERNEL_UNITS = ["cmux-guest-kernel.service", "cmux-guest-kernel.timer", "cmux-guest-kernel-booted.service"] as const;
const SHUTDOWN_HOOK = "/usr/lib/systemd/system-shutdown/cmux-guest-kernel.shutdown";
const SOURCE_DIR = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../../images/cmux-vm/guest");

/** Where the builder VM works; the bzImage lands at BUILT_IMAGE. */
const BUILD_DIR = "/root/cmux-kernel-build";
const BUILT_IMAGE = `${BUILD_DIR}/vmlinuz`;
/** The provider's exec call stops at 5 minutes; the build runs as its own unit and is polled. */
const BUILD_UNIT = "cmux-kernel-build";
const BUILD_BUDGET_MS = 30 * 60_000;
/** A switch is a clean shutdown and a boot: 8 to 22 s measured (n = 12, 2026-11-02). */
const SWITCH_BUDGET_MS = 180_000;

export type GuestKernelFile = { path: string; bytes: Uint8Array; mode: number };

/** The guest-side files every machine with the cmux kernel carries (not the kernel itself). */
export function guestKernelFiles(): GuestKernelFile[] {
  const file = (name: string) => new Uint8Array(readFileSync(path.join(SOURCE_DIR, name)));
  return [
    { path: GUEST_KERNEL_CLI, bytes: file("cmux-guest-kernel"), mode: 0o755 },
    { path: SHUTDOWN_HOOK, bytes: file("cmux-guest-kernel.shutdown"), mode: 0o755 },
    ...GUEST_KERNEL_UNITS.map((unit) => ({ path: `/etc/systemd/system/${unit}`, bytes: file(unit), mode: 0o644 })),
  ];
}

export function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** The directories guestKernelFiles and the kernel are written into; run before writing them. */
export const GUEST_KERNEL_DIRS_COMMAND = `install -d -m 0755 ${GUEST_KERNEL_DIR} /usr/lib/systemd/system-shutdown /var/lib/cmux`;

/**
 * Before anything is written: the base kernel's config must be the one the kernel was built
 * from. Checked only on the provider kernel (`providerRelease`): a machine already on an older
 * cmux kernel reports that kernel's config, and it is upgraded to the new one in place.
 */
export function guestKernelConfigCheckCommand(lock: GuestKernelLock, providerRelease: string): string {
  return `test "$(uname -r)" != ${sq(providerRelease)} || test "$(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)" = ${lock.baseConfigSha256} || { echo "base kernel config differs from kernel.baseConfigSha256 (after a base change, set it by hand from the new base's /proc/config.gz)"; exit 1; }`;
}

/**
 * After guestKernelConfigCheckCommand passed and the files and the kernel are written: record its
 * release and sha256, verify and enable the units, clear the switch attempt count, and load the
 * kernel once without switching (a kernel the base cannot load fails here).
 */
export function guestKernelInstallCommand(lock: GuestKernelLock, imageSha256: string): string {
  const units = GUEST_KERNEL_UNITS.map((u) => `/etc/systemd/system/${u}`).join(" ");
  return [
    `printf '%s\\n' ${sq(lock.version)} > ${GUEST_KERNEL_DIR}/release`,
    `printf '%s  vmlinuz\\n' ${imageSha256} > ${GUEST_KERNEL_IMAGE}.sha256`,
    `chown -R root:root ${GUEST_KERNEL_DIR} && chmod 0644 ${GUEST_KERNEL_DIR}/*`,
    `systemd-analyze verify ${units}`,
    "systemctl daemon-reload",
    "systemctl enable cmux-guest-kernel.timer cmux-guest-kernel-booted.service >/dev/null 2>&1",
    `test "$(systemctl is-enabled cmux-guest-kernel.timer)" = enabled && test "$(systemctl is-enabled cmux-guest-kernel-booted.service)" = enabled`,
    `${GUEST_KERNEL_CLI} reset`,
    `${GUEST_KERNEL_CLI} load`,
    `${GUEST_KERNEL_CLI} status`,
  ].join(" && ");
}

/** Builder VM script: fetch, check, configure from the base, build. Prints `BZIMAGE <sha256> <release>` last. */
export function guestKernelBuildScript(lock: GuestKernelLock): string {
  const tarball = `linux-${lock.version}.tar.xz`;
  return [
    "set -euo pipefail",
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get update -qq",
    "apt-get install -y -qq --no-install-recommends build-essential flex bison bc libelf-dev libssl-dev dwarves cpio xz-utils curl ca-certificates >/dev/null",
    `mkdir -p ${BUILD_DIR} && cd ${BUILD_DIR}`,
    `curl -fsSL --retry 3 -o ${tarball} ${sq(lock.url)}`,
    `test "$(stat -c %s ${tarball})" = ${lock.size}`,
    `printf '%s  %s\\n' ${lock.sha256} ${tarball} | sha256sum -c --quiet -`,
    // kernel.org's sha256sums.asc must name the same digest: a second source for it (its PGP signature is not checked).
    // To a file, not a pipe: grep -q stops reading at the match and curl would fail on the closed pipe.
    `curl -fsSL --retry 3 -o sha256sums.asc ${sq(lock.checksumsUrl)}`,
    `grep -qx '${lock.sha256}  ${tarball}' sha256sums.asc`,
    `test "$(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)" = ${lock.baseConfigSha256}`,
    `tar -xf ${tarball} && cd linux-${lock.version}`,
    "zcat /proc/config.gz > .config",
    "make olddefconfig >/dev/null",
    `export KBUILD_BUILD_TIMESTAMP=${sq(lock.buildTimestamp)} KBUILD_BUILD_USER=cmux KBUILD_BUILD_HOST=cmux-vm-image`,
    'make -j"$(nproc)" bzImage >/dev/null 2>build.err || { tail -40 build.err; exit 1; }',
    `test "$(make -s kernelrelease)" = ${sq(lock.version)}`,
    `cp arch/x86/boot/bzImage ${BUILT_IMAGE}`,
    'echo "GCC $(gcc --version | head -1)"',
    `echo "BZIMAGE $(sha256sum ${BUILT_IMAGE} | cut -d' ' -f1) $(make -s kernelrelease)"`,
  ].join("\n");
}

export type BuiltGuestKernel = { bytes: Uint8Array; sha256: string; release: string; gcc: string; builderVmId: string; buildMs: number };

/**
 * Builds the locked kernel on its own VM (named `<name>-kernel`) and deletes the VM.
 * An aborted `signal` (the bake failed elsewhere) stops the wait at the next poll.
 */
export async function buildGuestKernel(fs: Freestyle, ledger: Ledger, L: StepLog, lock: GuestKernelLock, name: string, allowUnprefixed: boolean, signal?: AbortSignal): Promise<BuiltGuestKernel> {
  const vmName = `${name}-kernel`;
  const builder = await createVm(fs, ledger, { name: vmName, snapshotId: lock.builder, allowUnprefixed });
  const t0 = Date.now();
  try {
    await firstExec(builder.vm, builder.t0);
    await builder.vm.fs.writeFile(`/root/${BUILD_UNIT}.sh`, guestKernelBuildScript(lock), { mode: 0o755 });
    await L.step(builder.vm, "kernel-build-start", `systemd-run --unit=${BUILD_UNIT} --collect bash -c 'bash /root/${BUILD_UNIT}.sh > /root/${BUILD_UNIT}.log 2>&1; echo $? > /root/${BUILD_UNIT}.rc'`);
    const deadline = Date.now() + BUILD_BUDGET_MS;
    for (;;) {
      if (signal?.aborted) throw new Error("kernel build abandoned: the bake failed");
      // A dropped call is a poll that saw nothing yet; the deadline still bounds the wait.
      const rc = await run(builder.vm, `cat /root/${BUILD_UNIT}.rc 2>/dev/null || true`).catch(() => null);
      const code = rc?.stdout.trim() ?? "";
      if (code !== "") {
        const log = await L.step(builder.vm, "kernel-build-log", `tail -60 /root/${BUILD_UNIT}.log`);
        if (code !== "0") throw new Error(`kernel build exited ${code}: ${log.slice(-1500)}`);
        const line = log.split("\n").find((l) => l.startsWith("BZIMAGE ")) ?? "";
        const [, sha, release] = line.split(" ");
        const bytes = await readGuestBytes(builder.vm, BUILT_IMAGE);
        if (sha256Hex(bytes) !== sha) throw new Error(`downloaded bzImage sha256 ${sha256Hex(bytes)} is not the builder's ${sha}`);
        if (release !== lock.version) throw new Error(`built kernel release ${release}, lock ${lock.version}`);
        const gcc = (log.split("\n").find((l) => l.startsWith("GCC ")) ?? "").slice(4);
        L.log(`kernel ${release} built in ${((Date.now() - t0) / 1000).toFixed(0)}s: sha256 ${sha} (${bytes.length} bytes, ${gcc})`);
        return { bytes, sha256: sha, release, gcc, builderVmId: builder.vmId, buildMs: Date.now() - t0 };
      }
      if (Date.now() > deadline) throw new Error(`kernel build did not finish in ${BUILD_BUDGET_MS / 60_000} minutes`);
      await sleep(15_000);
    }
  } finally {
    await deleteVm(builder.vm, builder.vmId, vmName, ledger);
  }
}

/**
 * Switch a machine to the installed kernel and wait until it answers on it. The switch ends
 * every process (systemd stops each unit cleanly); files on disk stay. Returns the switch time.
 */
export async function switchToGuestKernel(vm: Vm, L: StepLog, release: string): Promise<number> {
  const t0 = Date.now();
  // A transient unit, so the switch outlives this exec call (the call itself ends with the old kernel).
  await L.step(vm, "kernel-switch", `systemd-run --unit=cmux-guest-kernel-switch --collect ${GUEST_KERNEL_CLI} switch && echo queued`);
  const deadline = t0 + SWITCH_BUDGET_MS;
  while (Date.now() < deadline) {
    const r = await run(vm, "uname -r", 10_000).catch(() => null);
    if (r?.code === 0 && r.stdout.trim() === release) {
      const ms = Date.now() - t0;
      L.log(`switched to ${release} in ${(ms / 1000).toFixed(1)}s`);
      return ms;
    }
    await sleep(1_000);
  }
  throw new Error(`the machine did not come up on ${release} within ${SWITCH_BUDGET_MS / 1000}s`);
}

/** `cmux-guest-kernel status` as fields; `onCmuxKernel` is the running release equal to the installed one. */
export function parseGuestKernelStatus(stdout: string): { running?: string; installed?: string; attempts?: number; onCmuxKernel: boolean; oops?: string } {
  const line = stdout.trim().split("\n").find((l) => l.startsWith("running=")) ?? "";
  const kv = new Map(line.split(" ").map((pair) => [pair.slice(0, pair.indexOf("=")), pair.slice(pair.indexOf("=") + 1)] as const));
  const attempts = kv.has("attempts") ? Number(kv.get("attempts")) : undefined;
  return { running: kv.get("running"), installed: kv.get("installed"), attempts, onCmuxKernel: kv.get("on-cmux-kernel") === "yes" && kv.get("running") === kv.get("installed"), oops: kv.get("oops") };
}

/** Problems with a machine's kernel state against the lock; none on a machine that runs the locked kernel. */
export function guestKernelProblems(lock: GuestKernelLock, statusStdout: string): string[] {
  const status = parseGuestKernelStatus(statusStdout);
  const problems: string[] = [];
  if (status.installed !== lock.version) problems.push(`installed kernel ${status.installed ?? "none"}, lock ${lock.version}`);
  if (status.running !== lock.version) problems.push(`running kernel ${status.running ?? "unknown"}, lock ${lock.version}`);
  if (status.attempts !== 0) problems.push(`switch attempt count ${status.attempts ?? "unreadable"} (want 0 on the cmux kernel)`);
  // An oops can leave a lock held (an ext4 journal handle hangs every later write), so it fails the check.
  if (status.oops !== "no") problems.push(`kernel oops since boot: ${status.oops ?? "unreadable"} (dmesg has the trace)`);
  return problems;
}
