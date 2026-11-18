import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runChild } from "./helpers/run-child";

// Runs the real guest helper against a scratch root. Its absolute guest paths
// are rewritten into the scratch directory and the disk tools are stubs whose
// free-space answers each test sets, so the growth branches run anywhere.
const helperSource = readFileSync(
  fileURLToPath(new URL("../services/vms/images/devbox/cmux-tui-state-mount", import.meta.url)),
  "utf8",
);

const TEST_TIMEOUT_MS = 20_000;
const MIB = 1024 * 1024;
const GIB = 1024 * MIB;
/** The helper's STATE_MIN_FREE_KB floor (128 MiB). */
const FLOOR_KB = 131072;

type Disk = {
  /** Free KiB `df` reports for the mounted state filesystem. */
  readonly stateFreeKb: number;
  /** Free KiB `df` reports for the root filesystem holding the state image. */
  readonly rootFreeKb: number;
  /** Bytes of the session's workspace registry. */
  readonly registryBytes: number;
  /** Current size of the state image in bytes. */
  readonly imageBytes: number;
};

function stub(bin: string, name: string, body: string): void {
  const file = path.join(bin, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
}

async function runEnsure(disk: Disk) {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-tui-state-vacuum-"));
  try {
    const bin = path.join(root, "bin");
    const varLib = path.join(root, "var/lib/cmux");
    const etc = path.join(root, "etc/cmux");
    const home = path.join(root, "home/cmux");
    const state = path.join(home, ".local/state/cmux-tui");
    const session = path.join(state, "sessions/cloud-test");
    for (const dir of [bin, varLib, etc, session]) mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(varLib, "cmux-tui-state.ext4"), "");
    writeFileSync(path.join(session, "workspace-registry.sqlite3"), Buffer.alloc(disk.registryBytes));

    // stat, fallocate and the result share the image's size through a sidecar.
    const sizeFile = JSON.stringify(path.join(root, "image-size"));
    writeFileSync(path.join(root, "image-size"), `${disk.imageBytes}\n`);
    stub(bin, "mountpoint", "exit 0");
    stub(bin, "mount", "exit 0");
    stub(bin, "chown", "exit 0");
    stub(bin, "flock", "exit 0");
    stub(bin, "findmnt", "echo /dev/loop7");
    stub(bin, "losetup", "exit 0");
    stub(bin, "resize2fs", "exit 0");
    stub(bin, "stat", `cat ${sizeFile}`);
    stub(bin, "fallocate", `echo "$2" > ${sizeFile}`);
    // df -Pk PATH: the state mount answers stateFreeKb, anything else rootFreeKb.
    stub(
      bin,
      "df",
      `case "$2" in ${JSON.stringify(state)}) free=${disk.stateFreeKb} ;; *) free=${disk.rootFreeKb} ;; esac
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/x 1 1 $free 1% /"`,
    );

    const helper = path.join(root, "cmux-tui-state-mount");
    writeFileSync(helper, helperSource.replaceAll("/var/lib/cmux", varLib).replaceAll("/etc/cmux", etc));
    const result = await runChild("/bin/sh", [helper, "ensure", home, "cmux"], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}` },
    });
    return { ...result, imageBytes: Number(readFileSync(path.join(root, "image-size"), "utf8").trim()) };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe("cmux-tui state image keeps room for a registry VACUUM", () => {
  test(
    "grows when free space is above the floor but below the registry's size",
    async () => {
      // A registry migration's full VACUUM needs about the registry's size free.
      // 1 MiB above the floor cannot hold a 2 MiB registry's rewrite.
      const result = await runEnsure({
        stateFreeKb: FLOOR_KB + 1024,
        rootFreeKb: 64 * GIB / 1024,
        registryBytes: 2 * MIB,
        imageBytes: 2 * GIB,
      });
      expect(result.status).toBe(0);
      expect(result.imageBytes).toBe(4 * GIB);
    },
    TEST_TIMEOUT_MS,
  );

  test(
    "does not grow when the registry's VACUUM already fits",
    async () => {
      const result = await runEnsure({
        stateFreeKb: FLOOR_KB + 4096,
        rootFreeKb: 64 * GIB / 1024,
        registryBytes: 2 * MIB,
        imageBytes: 2 * GIB,
      });
      expect(result.status).toBe(0);
      expect(result.imageBytes).toBe(2 * GIB);
    },
    TEST_TIMEOUT_MS,
  );

  test(
    "starts the daemon without growth when the root disk has no headroom for the VACUUM room",
    async () => {
      const result = await runEnsure({
        stateFreeKb: FLOOR_KB + 1024,
        rootFreeKb: 512 * 1024,
        registryBytes: 2 * MIB,
        imageBytes: 2 * GIB,
      });
      expect(result.status).toBe(0);
      expect(result.imageBytes).toBe(2 * GIB);
      expect(result.stderr).toContain("insufficient root headroom");
      expect(result.stderr).toContain("no room to grow for a registry VACUUM");
    },
    TEST_TIMEOUT_MS,
  );

  test(
    "starts the daemon without growth at the 8 GiB cap",
    async () => {
      const result = await runEnsure({
        stateFreeKb: FLOOR_KB + 1024,
        rootFreeKb: 64 * GIB / 1024,
        registryBytes: 2 * MIB,
        imageBytes: 8 * GIB,
      });
      expect(result.status).toBe(0);
      expect(result.imageBytes).toBe(8 * GIB);
      expect(result.stderr).toContain("reached its 8589934592-byte cap");
      expect(result.stderr).toContain("no room to grow for a registry VACUUM");
    },
    TEST_TIMEOUT_MS,
  );

  test(
    "still refuses below the floor when growth is impossible",
    async () => {
      const result = await runEnsure({
        stateFreeKb: FLOOR_KB - 1,
        rootFreeKb: 512 * 1024,
        registryBytes: 2 * MIB,
        imageBytes: 2 * GIB,
      });
      expect(result.status).toBe(1);
      expect(result.imageBytes).toBe(2 * GIB);
    },
    TEST_TIMEOUT_MS,
  );
});
