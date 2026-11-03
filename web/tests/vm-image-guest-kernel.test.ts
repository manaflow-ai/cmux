import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEFAULT_LOCK_PATH, LockError, readInputsLock, validateInputsLock } from "../scripts/cmux-vm-image/lock";
import {
  GUEST_KERNEL_CLI,
  GUEST_KERNEL_UNITS,
  guestKernelBuildScript,
  guestKernelFiles,
  guestKernelInstallCommand,
  guestKernelProblems,
  parseGuestKernelStatus,
  sha256Hex,
} from "../scripts/cmux-vm-image/guest-kernel";
import { bakedKernel } from "../scripts/cmux-vm-image/guest-kernel-install";
import { runChild } from "./helpers/run-child";

const lockText = readFileSync(DEFAULT_LOCK_PATH, "utf8");
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- tests mutate arbitrary nested lock fields
const fresh = () => JSON.parse(lockText) as Record<string, any>;

function problemsOf(raw: unknown): string[] {
  try {
    validateInputsLock(raw);
    return [];
  } catch (error) {
    if (error instanceof LockError) return [...error.problems];
    throw error;
  }
}

describe("kernel lock entry", () => {
  test("the checked-in lock pins a kernel.org stable release", () => {
    const { kernel } = readInputsLock();
    expect(kernel.version).toMatch(/^6\.1\.\d+$/);
    expect(kernel.url).toBe(`https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernel.version}.tar.xz`);
  });

  test("refuses a missing entry, a URL for another release and a mismatched checksum list", () => {
    const missing = fresh();
    delete missing.kernel;
    expect(problemsOf(missing)).toContain("kernel: missing");

    const other = fresh();
    other.kernel.url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.102.tar.xz";
    expect(problemsOf(other).some((p) => p.startsWith("kernel.url: names 6.1.102"))).toBe(true);

    const mirror = fresh();
    mirror.kernel.url = `https://example.com/linux-${mirror.kernel.version}.tar.xz`;
    expect(problemsOf(mirror)).toContain("kernel.url: must be a cdn.kernel.org linux-<version>.tar.xz URL");

    const sums = fresh();
    sums.kernel.checksumsUrl = "https://example.com/sha256sums.asc";
    expect(problemsOf(sums)).toContain("kernel.checksumsUrl: must be the sha256sums.asc next to kernel.url");
  });

  test("refuses a floating version, a bad digest and a missing builder or timestamp", () => {
    const raw = fresh();
    raw.kernel.version = "6.1";
    raw.kernel.sha256 = "ABC";
    raw.kernel.baseConfigSha256 = "";
    delete raw.kernel.builder;
    raw.kernel.buildTimestamp = "yesterday";
    const problems = problemsOf(raw);
    expect(problems).toContain("kernel.version: needs an exact stable release such as 6.1.191");
    expect(problems).toContain("kernel.sha256: missing or not 64 lowercase hex");
    expect(problems).toContain("kernel.baseConfigSha256: missing or not 64 lowercase hex");
    expect(problems).toContain("kernel.builder: missing (the snapshot the kernel builds on)");
    expect(problems).toContain("kernel.buildTimestamp: needs an ISO UTC time");
  });
});

describe("guest kernel status", () => {
  const { kernel } = readInputsLock();

  test("a machine on the locked kernel has no problems", () => {
    const out = `running=${kernel.version} installed=${kernel.version} attempts=0 on-cmux-kernel=yes\n`;
    expect(parseGuestKernelStatus(out)).toEqual({ running: kernel.version, installed: kernel.version, attempts: 0, onCmuxKernel: true });
    expect(guestKernelProblems(kernel, out)).toEqual([]);
  });

  test("the provider kernel, a stale install and a pending attempt are each reported", () => {
    const out = "running=6.1.102 installed=6.1.190 attempts=1 on-cmux-kernel=no";
    expect(parseGuestKernelStatus(out).onCmuxKernel).toBe(false);
    expect(guestKernelProblems(kernel, out)).toEqual([
      `installed kernel 6.1.190, lock ${kernel.version}`,
      `running kernel 6.1.102, lock ${kernel.version}`,
      "switch attempt count 1 (want 0 on the cmux kernel)",
    ]);
  });

  test("no status line at all is a problem, not a pass", () => {
    expect(guestKernelProblems(kernel, "")).toHaveLength(3);
  });
});

describe("guest kernel files and commands", () => {
  const { kernel } = readInputsLock();

  test("installs the script, the shutdown hook and every unit", () => {
    const paths = guestKernelFiles().map((f) => f.path);
    expect(paths).toContain(GUEST_KERNEL_CLI);
    expect(paths).toContain("/usr/lib/systemd/system-shutdown/cmux-guest-kernel.shutdown");
    for (const unit of GUEST_KERNEL_UNITS) expect(paths).toContain(`/etc/systemd/system/${unit}`);
  });

  test("the build checks the tarball twice and the base config before compiling", () => {
    const script = guestKernelBuildScript(kernel);
    const order = [kernel.sha256, kernel.checksumsUrl, kernel.baseConfigSha256, "make olddefconfig", "bzImage"].map((needle) => script.indexOf(needle));
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    expect(script).toContain(`KBUILD_BUILD_TIMESTAMP='${kernel.buildTimestamp}'`);
  });

  test("the install refuses a base whose config is not the one the kernel was built from", () => {
    const command = guestKernelInstallCommand(kernel, "0".repeat(64));
    expect(command).toContain(`= ${kernel.baseConfigSha256} ||`);
    expect(command.indexOf("systemctl enable")).toBeLessThan(command.indexOf(`${GUEST_KERNEL_CLI} load`));
  });

  test("sha256Hex matches the shell's sha256sum", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "guest-kernel-"));
    const file = path.join(dir, "blob");
    const bytes = new TextEncoder().encode("cmux guest kernel\n");
    writeFileSync(file, bytes);
    const r = await runChild("shasum", ["-a", "256", file]);
    expect(r.stdout.split(" ")[0]).toBe(sha256Hex(bytes));
  });
});

describe("the shutdown hook", () => {
  const hookPath = fileURLToPath(new URL("../../images/cmux-vm/guest/cmux-guest-kernel.shutdown", import.meta.url));
  const drivers = ["virtio_blk", "virtio_net", "vmw_vsock_virtio_transport", "virtio_balloon", "virtio_rng"];

  /** A fake sysfs with one device per driver; `shared` points every unbind file at one file. */
  async function fakeSysfs(shared: boolean): Promise<string> {
    const root = mkdtempSync(path.join(tmpdir(), "guest-kernel-sysfs-"));
    for (const [i, driver] of drivers.entries()) {
      const dir = path.join(root, "bus/virtio/drivers", driver);
      const made = await runChild("sh", ["-c", `mkdir -p "$1/virtio${i}" && { [ "$2" = 0 ] || ln -s "$3" "$1/unbind"; }`, "mk", dir, shared ? "1" : "0", path.join(root, "last-unbind")]);
      expect(made.status).toBe(0);
    }
    return root;
  }

  test("does nothing on a power off, reboot or halt", async () => {
    const root = await fakeSysfs(false);
    for (const action of ["poweroff", "reboot", "halt"]) {
      const r = await runChild("sh", [hookPath, action], { env: { ...process.env, CMUX_SYSFS: root } });
      expect(r.status).toBe(0);
      for (const driver of drivers) expect(() => readFileSync(path.join(root, "bus/virtio/drivers", driver, "unbind"))).toThrow();
    }
  });

  test("on kexec, unbinds every virtio device", async () => {
    const root = await fakeSysfs(false);
    const r = await runChild("sh", [hookPath, "kexec"], { env: { ...process.env, CMUX_SYSFS: root } });
    expect(r.status).toBe(0);
    for (const [i, driver] of drivers.entries()) expect(readFileSync(path.join(root, "bus/virtio/drivers", driver, "unbind"), "utf8")).toBe(`virtio${i}\n`);
  });

  test("unbinds the disk last", async () => {
    const root = await fakeSysfs(true);
    const r = await runChild("sh", [hookPath, "kexec"], { env: { ...process.env, CMUX_SYSFS: root } });
    expect(r.status).toBe(0);
    expect(readFileSync(path.join(root, "last-unbind"), "utf8")).toBe("virtio0\n");
  });
});

describe("guest-kernel-install: the kernel a bake built", () => {
  const { kernel } = readInputsLock();
  const bytes = new TextEncoder().encode("not really a bzImage\n");

  function bakeDir(recorded: { release?: string; sha256?: string } | undefined): string {
    const dir = mkdtempSync(path.join(tmpdir(), "guest-kernel-bake-"));
    writeFileSync(path.join(dir, `vmlinuz-${kernel.version}`), bytes);
    writeFileSync(path.join(dir, "bake-x.json"), JSON.stringify({ name: "x", guestKernel: recorded }));
    return path.join(dir, "bake-x.json");
  }

  test("returns the kernel whose sha256 the bake recorded", () => {
    expect(bakedKernel(bakeDir({ release: kernel.version, sha256: sha256Hex(bytes) }), kernel.version).sha256).toBe(sha256Hex(bytes));
  });

  test("refuses a changed file, another release and a bake without a kernel", () => {
    expect(() => bakedKernel(bakeDir({ release: kernel.version, sha256: "0".repeat(64) }), kernel.version)).toThrow(/is not the bake's/);
    expect(() => bakedKernel(bakeDir({ release: "6.1.102", sha256: sha256Hex(bytes) }), kernel.version)).toThrow(/records kernel 6.1.102/);
    expect(() => bakedKernel(bakeDir(undefined), kernel.version)).toThrow(/records kernel none/);
  });
});
