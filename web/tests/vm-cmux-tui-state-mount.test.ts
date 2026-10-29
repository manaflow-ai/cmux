import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runChild } from "./helpers/run-child";

// Runs the real guest helper against a scratch root. Its absolute guest paths
// are rewritten into the scratch directory and the disk tools are stubs whose
// free-space answers each test sets, so the full-disk branches run anywhere.
const helperSource = readFileSync(
  fileURLToPath(new URL("../services/vms/images/devbox/cmux-tui-state-mount", import.meta.url)),
  "utf8",
);

// Each test runs the real helper as a child shell; a loaded runner can pass
// bun's 5 s default.
const TEST_TIMEOUT_MS = 20_000;

type Disk = {
  /** Free KiB `df` reports for the mounted state filesystem. */
  readonly stateFreeKb: number | string;
  /** Free KiB `df` reports for the root filesystem holding the state image. */
  readonly rootFreeKb: number | string;
  /** Current size of the state image in bytes. */
  readonly imageBytes?: number;
  /** Makes the growth allocation fail part way, as on a disk that filled after the headroom check. */
  readonly fallocateFails?: boolean;
  /** Makes the rollback of a failed allocation fail too. */
  readonly truncateFails?: boolean;
  /** Fails a growth tool before the image allocation. */
  readonly growthToolFailure?: "losetup" | "resize2fs";
  /** Starts with the state image unmounted, so `ensure` mounts it first. */
  readonly unmounted?: boolean;
};

function stub(bin: string, name: string, body: string): void {
  const file = path.join(bin, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
}

async function runEnsure(disk: Disk): Promise<{ status: number | null; stderr: string; grew: boolean; mounted: boolean; finalImageBytes: number }> {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-tui-state-mount-"));
  try {
    return await runEnsureInRoot(root, disk);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

async function runEnsureInRoot(root: string, disk: Disk) {
  const bin = path.join(root, "bin");
  const varLib = path.join(root, "var/lib/cmux");
  const home = path.join(root, "home/cmux");
  mkdirSync(bin, { recursive: true });
  mkdirSync(varLib, { recursive: true });
  mkdirSync(path.join(home, ".local/state/cmux-tui"), { recursive: true });
  writeFileSync(path.join(varLib, "cmux-tui-state.ext4"), "");

  const grewMarker = path.join(root, "grew");
  // The image's size lives in a sidecar file that the stat, fallocate and
  // truncate stubs share, so a test sees what the helper left behind.
  const sizeFile = JSON.stringify(path.join(root, "image-size"));
  const initialBytes = disk.imageBytes ?? 1024 * 1024 * 1024;
  writeFileSync(path.join(root, "image-size"), `${initialBytes}\n`);
  const mountedMarker = path.join(root, "mounted");
  stub(bin, "mountpoint", disk.unmounted ? `test -e ${JSON.stringify(mountedMarker)}` : "exit 0");
  stub(bin, "mount", `: > ${JSON.stringify(mountedMarker)}`);
  stub(bin, "chown", "exit 0");
  stub(bin, "flock", "exit 0");
  stub(bin, "findmnt", "echo /dev/loop7");
  stub(bin, "losetup", disk.growthToolFailure === "losetup" ? "exit 1" : "exit 0");
  stub(bin, "resize2fs", disk.growthToolFailure === "resize2fs" ? "exit 1" : "exit 0");
  stub(bin, "stat", `cat ${sizeFile}`);
  // fallocate -l BYTES FILE; a failing one extends the file by 1 MiB first.
  stub(
    bin,
    "fallocate",
    disk.fallocateFails
      ? `echo $(($(cat ${sizeFile}) + 1048576)) > ${sizeFile}; exit 1`
      : `echo "$2" > ${sizeFile}; : > ${JSON.stringify(grewMarker)}`,
  );
  // truncate -s BYTES FILE
  stub(bin, "truncate", disk.truncateFails ? "exit 1" : `echo "$2" > ${sizeFile}`);
  stub(
    bin,
    "df",
    [
      'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"',
      'case "$2" in *cmux-tui-state.ext4) free=$CMUX_TEST_ROOT_FREE_KB ;; *) free=$CMUX_TEST_STATE_FREE_KB ;; esac',
      'echo "/dev/x 100 0 $free 0% /"',
    ].join("\n"),
  );

  const helper = path.join(root, "cmux-tui-state-mount");
  writeFileSync(
    helper,
    helperSource
      .replaceAll("/var/lib/cmux", varLib)
      .replaceAll("/etc/cmux", path.join(root, "etc/cmux")),
  );
  chmodSync(helper, 0o755);

  const result = await runChild("/bin/sh", [helper, "ensure", home, "cmux"], {
    // Leave time for runChild's termination grace before the test deadline.
    timeout: TEST_TIMEOUT_MS - 5_000,
    env: {
      PATH: `${bin}:/usr/bin:/bin`,
      CMUX_TEST_ROOT_FREE_KB: String(disk.rootFreeKb),
      CMUX_TEST_STATE_FREE_KB: String(disk.stateFreeKb),
    },
  });
  if (result.error) throw result.error;
  return {
    status: result.status,
    stderr: result.stderr,
    grew: existsSync(grewMarker),
    mounted: existsSync(mountedMarker),
    finalImageBytes: Number(readFileSync(path.join(root, "image-size"), "utf8").trim()),
  };
}

describe("cmux-tui state mount on a full disk", () => {
  test("a full root disk does not defer the daemon while the state filesystem still has room", async () => {
    // State is below the 128 MiB growth threshold and root has no headroom to
    // grow it. Deferring here is what left machines answering "connection refused".
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.stderr).toContain("insufficient root headroom");
    expect(result.stderr).toContain("continuing with 65536KiB free");
    expect(result.status).toBe(0);
    expect(result.grew).toBe(false);
  }, TEST_TIMEOUT_MS);

  test("a freshly mounted state image starts the daemon when growth fails with room left", async () => {
    // ensure mounts the image first (a cold boot), then hits the same full root disk.
    const result = await runEnsure({ stateFreeKb: 16 * 1024, rootFreeKb: 100 * 1024, unmounted: true });
    expect(result.mounted).toBe(true);
    expect(result.stderr).toContain("insufficient root headroom");
    expect(result.stderr).toContain("continuing with 16384KiB free");
    expect(result.status).toBe(0);
  }, TEST_TIMEOUT_MS);

  test("a freshly mounted state image with no working room still defers startup", async () => {
    const result = await runEnsure({ stateFreeKb: 16 * 1024 - 1, rootFreeKb: 100 * 1024, unmounted: true });
    expect(result.mounted).toBe(true);
    expect(result.stderr).toContain("state filesystem is full");
    expect(result.status).toBe(1);
  }, TEST_TIMEOUT_MS);

  test("the size cap does not defer the daemon either", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 64 * 1024 * 1024, imageBytes: 8 * 1024 ** 3 });
    expect(result.stderr).toContain("reached its");
    expect(result.status).toBe(0);
  }, TEST_TIMEOUT_MS);

  test("a state filesystem with no working room still defers startup", async () => {
    const result = await runEnsure({ stateFreeKb: 4 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("state filesystem is full");
  }, TEST_TIMEOUT_MS);

  test.each(["not-a-number", ""])("rejects malformed state free-space output %j", async (stateFreeKb) => {
    const result = await runEnsure({ stateFreeKb, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("cannot read state filesystem free space");
    expect(result.grew).toBe(false);
  }, TEST_TIMEOUT_MS);

  test("defers startup just below the critical free-space boundary", async () => {
    const result = await runEnsure({ stateFreeKb: 16_383, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("state filesystem is full (free=16383KiB)");
    expect(result.grew).toBe(false);
  }, TEST_TIMEOUT_MS);

  test("starts at the exact critical free-space boundary", async () => {
    const result = await runEnsure({ stateFreeKb: 16_384, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("continuing with 16384KiB free");
    expect(result.grew).toBe(false);
  }, TEST_TIMEOUT_MS);

  test("malformed root free-space output cannot authorize growth", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: "not-a-number" });
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("cannot read root filesystem free space");
    expect(result.stderr).toContain("continuing with 65536KiB free");
    expect(result.grew).toBe(false);
  }, TEST_TIMEOUT_MS);

  test.each(["losetup", "resize2fs"] as const)("a failed %s preserves startup with working room", async (growthToolFailure) => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 8 * 1024 * 1024, growthToolFailure });
    expect(result.status).toBe(0);
    expect(result.stderr).toContain("continuing with 65536KiB free");
    expect(result.grew).toBe(false);
    expect(result.finalImageBytes).toBe(1024 * 1024 * 1024);
  }, TEST_TIMEOUT_MS);

  test.each(["losetup", "resize2fs"] as const)("a failed %s cannot start below the critical boundary", async (growthToolFailure) => {
    const result = await runEnsure({ stateFreeKb: 16_383, rootFreeKb: 8 * 1024 * 1024, growthToolFailure });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("state filesystem is full (free=16383KiB)");
    expect(result.grew).toBe(false);
  }, TEST_TIMEOUT_MS);

  test("grows the state image when the root disk has headroom", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 8 * 1024 * 1024 });
    expect(result.status).toBe(0);
    expect(result.grew).toBe(true);
    expect(result.finalImageBytes).toBe(2 * 1024 * 1024 * 1024);
  }, TEST_TIMEOUT_MS);

  test("a failed growth allocation is undone and the daemon still starts", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 8 * 1024 * 1024, fallocateFails: true });
    expect(result.status).toBe(0);
    expect(result.finalImageBytes).toBe(1024 * 1024 * 1024);
    expect(result.stderr).toContain("continuing with 65536KiB free");
  }, TEST_TIMEOUT_MS);

  test("a rollback that fails is logged and the daemon still starts", async () => {
    // The extra blocks are already allocated to the image either way; deferring
    // the daemon over them would bring back the unreachable machine.
    const result = await runEnsure({
      stateFreeKb: 64 * 1024,
      rootFreeKb: 8 * 1024 * 1024,
      fallocateFails: true,
      truncateFails: true,
    });
    expect(result.status).toBe(0);
    expect(result.finalImageBytes).toBe(1024 * 1024 * 1024 + 1024 * 1024);
    expect(result.stderr).toContain("could not shrink the state image back");
    expect(result.stderr).toContain("continuing with 65536KiB free");
  }, TEST_TIMEOUT_MS);

  test("leaves a roomy state filesystem alone", async () => {
    const result = await runEnsure({ stateFreeKb: 512 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(0);
    expect(result.grew).toBe(false);
    expect(result.stderr).toBe("");
  }, TEST_TIMEOUT_MS);
});
