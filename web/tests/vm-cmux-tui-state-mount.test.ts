import { afterEach, describe, expect, test } from "bun:test";
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
  /** Makes the growth allocation fail, as on a disk that filled after the headroom check. */
  readonly fallocateFails?: boolean;
};

function stub(bin: string, name: string, body: string): void {
  const file = path.join(bin, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
}

async function runEnsure(disk: Disk): Promise<{ status: number | null; stderr: string; grew: boolean; truncatedTo: string | null }> {
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
  stub(bin, "fallocate", disk.fallocateFails ? "exit 1" : `: > ${JSON.stringify(grewMarker)}`);
  stub(bin, "truncate", `echo "$@" > ${JSON.stringify(path.join(root, "truncated"))}`);
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

  const result = await runChild("/bin/sh", [helper, "ensure", home, "cmux"], {
    env: { PATH: `${bin}:/usr/bin:/bin` },
  });
  const truncated = path.join(root, "truncated");
  return {
    status: result.status,
    stderr: result.stderr,
    grew: existsSync(grewMarker),
    truncatedTo: existsSync(truncated) ? readFileSync(truncated, "utf8").trim() : null,
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
  });

  test("the size cap does not defer the daemon either", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 64 * 1024 * 1024, imageBytes: 8 * 1024 ** 3 });
    expect(result.stderr).toContain("reached its");
    expect(result.status).toBe(0);
  });

  test("a state filesystem with no working room still defers startup", async () => {
    const result = await runEnsure({ stateFreeKb: 4 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.status).not.toBe(0);
  });

  test("grows the state image when the root disk has headroom", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 8 * 1024 * 1024 });
    expect(result.status).toBe(0);
    expect(result.grew).toBe(true);
  });

  test("a failed growth allocation is undone and the daemon still starts", async () => {
    const result = await runEnsure({ stateFreeKb: 64 * 1024, rootFreeKb: 8 * 1024 * 1024, fallocateFails: true });
    expect(result.status).toBe(0);
    expect(result.truncatedTo).toContain(`-s ${1024 * 1024 * 1024}`);
    expect(result.stderr).toContain("continuing with 65536KiB free");
  });

  test("leaves a roomy state filesystem alone", async () => {
    const result = await runEnsure({ stateFreeKb: 512 * 1024, rootFreeKb: 100 * 1024 });
    expect(result.status).toBe(0);
    expect(result.grew).toBe(false);
    expect(result.stderr).toBe("");
  });
});
