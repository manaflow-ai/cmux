import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Runs the real guest helper against a scratch root. Its absolute guest paths
// are rewritten into the scratch directory and the disk tools are stubs whose
// free-space answers each test sets, so the full-disk branches run anywhere.
const helperSource = readFileSync(
  path.join(import.meta.dir, "../services/vms/images/devbox/cmux-tui-state-mount"),
  "utf8",
);

const scratchDirs: string[] = [];
afterEach(() => {
  for (const dir of scratchDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

type Disk = {
  /** Free KiB `df` reports for the mounted state filesystem. */
  readonly stateFreeKb: number;
  /** Free KiB `df` reports for the root filesystem holding the state image. */
  readonly rootFreeKb: number;
  /** Current size of the state image in bytes. */
  readonly imageBytes?: number;
};

function stub(bin: string, name: string, body: string): void {
  const file = path.join(bin, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
}

function runEnsure(disk: Disk): { status: number | null; stderr: string; grew: boolean } {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-tui-state-mount-"));
  scratchDirs.push(root);
  const bin = path.join(root, "bin");
  const varLib = path.join(root, "var/lib/cmux");
  const home = path.join(root, "home/cmux");
  mkdirSync(bin, { recursive: true });
  mkdirSync(varLib, { recursive: true });
  mkdirSync(path.join(home, ".local/state/cmux-tui"), { recursive: true });
  writeFileSync(path.join(varLib, "cmux-tui-state.ext4"), "");

  const grewMarker = path.join(root, "grew");
  stub(bin, "mountpoint", "exit 0");
  stub(bin, "flock", "exit 0");
  stub(bin, "findmnt", "echo /dev/loop7");
  stub(bin, "losetup", "exit 0");
  stub(bin, "resize2fs", "exit 0");
  stub(bin, "stat", `echo ${disk.imageBytes ?? 1024 * 1024 * 1024}`);
  stub(bin, "fallocate", `: > ${JSON.stringify(grewMarker)}`);
  stub(
    bin,
    "df",
    [
      'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"',
      `case "$2" in *cmux-tui-state.ext4) free=${disk.rootFreeKb} ;; *) free=${disk.stateFreeKb} ;; esac`,
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

  const result = spawnSync("/bin/sh", [helper, "ensure", home, "cmux"], {
    encoding: "utf8",
    env: { PATH: `${bin}:/usr/bin:/bin` },
  });
  return { status: result.status, stderr: result.stderr, grew: existsSync(grewMarker) };
}

describe("cmux-tui state mount on a full disk", () => {
  test("a full root disk does not defer the daemon while the state filesystem still has room", () => {
    // State is below the 128 MiB growth threshold and root has no headroom to
    // grow it. Deferring here is what left machines answering "connection refused".
    const result = runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.stderr).toContain("insufficient root headroom");
    expect(result.stderr).toContain("continuing with 65536KiB free");
    expect(result.status).toBe(0);
    expect(result.grew).toBe(false);
  });

  test("the size cap does not defer the daemon either", () => {
    const result = runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 64 * 1024 * 1024, imageBytes: 8 * 1024 ** 3 });
    expect(result.stderr).toContain("reached its");
    expect(result.status).toBe(0);
  });

  test("a state filesystem with no working room still defers startup", () => {
    const result = runEnsure({ stateFreeKb: 4 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.status).not.toBe(0);
  });

  test("grows the state image when the root disk has headroom", () => {
    const result = runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 8 * 1024 * 1024 });
    expect(result.status).toBe(0);
    expect(result.grew).toBe(true);
  });

  test("leaves a roomy state filesystem alone", () => {
    const result = runEnsure({ stateFreeKb: 512 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(0);
    expect(result.grew).toBe(false);
    expect(result.stderr).toBe("");
  });
});
