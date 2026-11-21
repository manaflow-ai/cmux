import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from "node:fs";
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

// The daemon writes runtime.json and its lifecycle fence under the remote state
// dir on every start and exits on ENOSPC, so that dir must not be on the root disk.
describe("cmux-tui remote state on the reserved filesystem", () => {
  const SESSION = "sessions/Y2xvdWQ";
  type Scenario = {
    /** Files already at ~/.local/state/cmux/remote. */
    readonly onRoot?: Record<string, string>;
    /** Files already in the reserved copy; omit for a machine that has none yet. */
    readonly reserved?: Record<string, string>;
    readonly noMarker?: boolean;
    readonly alreadyBound?: boolean;
    readonly daemonRunning?: boolean;
    readonly mountFails?: boolean;
    readonly copyFails?: boolean;
    readonly instanceId?: string;
    /** Directories already in /tmp, each with a file inside. */
    readonly tmpDirs?: readonly string[];
    /** A plain file already at this /tmp name. */
    readonly tmpFile?: string;
    /** Makes mkdir fail for /tmp paths, as on a full root filesystem. */
    readonly tmpMkdirFails?: boolean;
    /** The state image cannot be loop-mounted, and the state dir is not a mountpoint. */
    readonly loopMountFails?: boolean;
    /** The reservation marker is present but the state image is missing. */
    readonly noImage?: boolean;
    /** The flush of the reserved copy fails. */
    readonly syncFails?: boolean;
  };

  function writeTree(dir: string, files: Record<string, string>): void {
    mkdirSync(dir, { recursive: true });
    for (const [name, body] of Object.entries(files)) {
      mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
      writeFileSync(path.join(dir, name), body);
    }
  }

  async function withEnsure(
    scenario: Scenario,
    check: (paths: { status: number | null; stderr: string; bound: boolean; remote: string; reserved: string; tmp: string; pgrepPattern: string; chowned: string; synced: string }) => void,
  ): Promise<void> {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-tui-remote-state-"));
    try {
      const bin = path.join(root, "bin");
      const varLib = path.join(root, "var/lib/cmux");
      const etc = path.join(root, "etc/cmux");
      const home = path.join(root, "home/cmux");
      const state = path.join(home, ".local/state/cmux-tui");
      const remote = path.join(home, ".local/state/cmux/remote");
      const reserved = path.join(state, ".cmux-remote");
      const bound = path.join(root, "bound");
      const tmp = path.join(root, "tmp");
      mkdirSync(bin, { recursive: true });
      mkdirSync(varLib, { recursive: true });
      mkdirSync(etc, { recursive: true });
      mkdirSync(state, { recursive: true });
      mkdirSync(tmp, { recursive: true });
      for (const name of scenario.tmpDirs ?? []) writeTree(path.join(tmp, name), { kept: "" });
      if (scenario.tmpFile) writeFileSync(path.join(tmp, scenario.tmpFile), "planted");
      if (!scenario.noImage) writeFileSync(path.join(varLib, "cmux-tui-state.ext4"), "");
      if (!scenario.noMarker) writeFileSync(path.join(etc, "cmux-tui-state-reservation"), "");
      if (scenario.instanceId) writeFileSync(path.join(etc, "daemon-instance-id"), `${scenario.instanceId}\n`);
      if (scenario.onRoot) writeTree(remote, scenario.onRoot);
      if (scenario.reserved) writeTree(reserved, scenario.reserved);
      if (scenario.alreadyBound) writeFileSync(bound, "");
      const stateIsMounted = scenario.loopMountFails || scenario.noImage ? "exit 1" : "exit 0";
      stub(bin, "mountpoint", `case "$2" in */cmux/remote) test -e ${JSON.stringify(bound)} ;; *) ${stateIsMounted} ;; esac`);
      // mount --bind FROM TO records what was bound where; a loop mount only succeeds or fails.
      const bindMount = scenario.mountFails ? "exit 1" : `echo "$2 $3" > ${JSON.stringify(bound)}`;
      const loopMount = scenario.loopMountFails ? "exit 32" : "exit 0";
      stub(bin, "mount", `if [ "$1" = --bind ]; then ${bindMount}; else ${loopMount}; fi`);
      const pgrepArgs = path.join(root, "pgrep-args");
      stub(bin, "pgrep", `echo "$*" > ${JSON.stringify(pgrepArgs)}\n${scenario.daemonRunning ? "exit 0" : "exit 1"}`);
      const syncArgs = path.join(root, "sync-args");
      stub(bin, "sync", `echo "$*" >> ${JSON.stringify(syncArgs)}\n${scenario.syncFails ? "exit 1" : "exit 0"}`);
      const chownArgs = path.join(root, "chown-args");
      stub(bin, "chown", `echo "$*" >> ${JSON.stringify(chownArgs)}`);
      stub(bin, "flock", "exit 0");
      stub(bin, "id", "echo 1000");
      if (scenario.tmpMkdirFails) {
        stub(bin, "mkdir", `case "$*" in *${tmp}*) exit 1 ;; esac\nexec /bin/mkdir "$@"`);
      }
      if (scenario.copyFails) stub(bin, "cp", "exit 1");
      stub(bin, "df", 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 100 0 1048576 0% /"');
      const helper = path.join(root, "cmux-tui-state-mount");
      writeFileSync(
        helper,
        helperSource.replaceAll("/var/lib/cmux", varLib).replaceAll("/etc/cmux", etc).replaceAll('"/tmp/cmux-', `"${tmp}/cmux-`),
      );
      chmodSync(helper, 0o755);
      const result = await runChild("/bin/sh", [helper, "ensure", home, "cmux"], {
        timeout: TEST_TIMEOUT_MS - 5_000,
        env: { PATH: `${bin}:/usr/bin:/bin` },
      });
      if (result.error) throw result.error;
      const pgrepPattern = existsSync(pgrepArgs) ? readFileSync(pgrepArgs, "utf8") : "";
      const chowned = existsSync(chownArgs) ? readFileSync(chownArgs, "utf8") : "";
      const synced = existsSync(syncArgs) ? readFileSync(syncArgs, "utf8") : "";
      check({ status: result.status, stderr: result.stderr, bound: existsSync(bound), remote, reserved, tmp, pgrepPattern, chowned, synced });
      if (existsSync(bound) && !scenario.alreadyBound) {
        expect(readFileSync(bound, "utf8").trim()).toBe(`${reserved} ${remote}`);
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }

  const read = (dir: string, name: string) => readFileSync(path.join(dir, name), "utf8");

  test("the first start copies the identity over and binds it", async () => {
    await withEnsure({ onRoot: { [`${SESSION}/auth/identity.json`]: "identity" }, instanceId: "i-a" }, ({ status, bound, remote, reserved }) => {
      expect(status).toBe(0);
      expect(bound).toBe(true);
      expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("identity");
      expect(read(reserved, ".instance-id")).toBe("i-a\n");
      expect(existsSync(`${reserved}.new`)).toBe(false);
      // Nothing a fork could later uncover: the identity lives in one place.
      expect(existsSync(path.join(remote, "sessions"))).toBe(false);
    });
  }, TEST_TIMEOUT_MS);

  test("the owner record belongs to the daemon's user, since the image requires every file under home to", async () => {
    await withEnsure({ instanceId: "i-a" }, ({ reserved, chowned }) => {
      expect(chowned).toContain(`cmux:cmux ${reserved}/.instance-id.new`);
    });
  }, TEST_TIMEOUT_MS);

  test("a machine with no remote state yet gets the bind before the daemon creates any", async () => {
    await withEnsure({}, ({ status, bound, remote, reserved }) => {
      expect(status).toBe(0);
      expect(bound).toBe(true);
      expect(existsSync(remote)).toBe(true);
      expect(existsSync(reserved)).toBe(true);
    });
  }, TEST_TIMEOUT_MS);

  test("after a reboot the reserved copy wins over the stale one underneath", async () => {
    await withEnsure(
      { onRoot: { [`${SESSION}/auth/identity.json`]: "stale" }, reserved: { [`${SESSION}/auth/identity.json`]: "current" } },
      ({ status, bound, reserved }) => {
        expect(status).toBe(0);
        expect(bound).toBe(true);
        expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("current");
      },
    );
  }, TEST_TIMEOUT_MS);

  test("after a reboot a runtime marker with no shutdown record is dropped", async () => {
    await withEnsure({ reserved: { [`${SESSION}/runtime.json`]: "{}" } }, ({ status, reserved }) => {
      expect(status).toBe(0);
      expect(existsSync(path.join(reserved, `${SESSION}/runtime.json`))).toBe(false);
    });
  }, TEST_TIMEOUT_MS);

  test("after a reboot a successful shutdown record is cleared with its marker", async () => {
    const outcome = JSON.stringify({ version: 1, lifecycle_id: "x", status: "succeeded" });
    await withEnsure({ reserved: { [`${SESSION}/runtime.json`]: "{}", [`${SESSION}/shutdown.json`]: outcome } }, ({ reserved }) => {
      expect(existsSync(path.join(reserved, `${SESSION}/runtime.json`))).toBe(false);
      expect(existsSync(path.join(reserved, `${SESSION}/shutdown.json`))).toBe(false);
    });
  }, TEST_TIMEOUT_MS);

  for (const [label, outcome] of [
    ["failed", JSON.stringify({ version: 1, lifecycle_id: "x", status: "failed" })],
    ["malformed", "{not json"],
  ] as const) {
    test(`after a reboot a ${label} shutdown record stays as a fence`, async () => {
      await withEnsure({ reserved: { [`${SESSION}/runtime.json`]: "{}", [`${SESSION}/shutdown.json`]: outcome } }, ({ status, reserved }) => {
        expect(status).toBe(0);
        expect(read(reserved, `${SESSION}/runtime.json`)).toBe("{}");
        expect(read(reserved, `${SESSION}/shutdown.json`)).toBe(outcome);
      });
    }, TEST_TIMEOUT_MS);
  }

  test("a clone booted from the disk drops its parent's identity", async () => {
    await withEnsure(
      {
        instanceId: "i-clone",
        reserved: { ".instance-id": "i-parent\n", [`${SESSION}/auth/identity.json`]: "parent", "connections/a": "parent" },
      },
      ({ status, bound, reserved }) => {
        expect(status).toBe(0);
        expect(bound).toBe(true);
        expect(existsSync(path.join(reserved, `${SESSION}/auth`))).toBe(false);
        expect(existsSync(path.join(reserved, "connections"))).toBe(false);
        expect(read(reserved, ".instance-id")).toBe("i-clone\n");
      },
    );
  }, TEST_TIMEOUT_MS);

  test("the same machine rebooting keeps its identity", async () => {
    await withEnsure(
      { instanceId: "i-a", reserved: { ".instance-id": "i-a\n", [`${SESSION}/auth/identity.json`]: "mine", "connections/a": "mine" } },
      ({ reserved }) => {
        expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("mine");
        expect(read(reserved, "connections/a")).toBe("mine");
      },
    );
  }, TEST_TIMEOUT_MS);

  test("a machine with no recorded owner keeps its identity", async () => {
    await withEnsure({ instanceId: "i-a", reserved: { [`${SESSION}/auth/identity.json`]: "mine" } }, ({ reserved }) => {
      expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("mine");
    });
  }, TEST_TIMEOUT_MS);

  test("a live bind only refreshes the owner, so a forked machine's later reboot keeps its identity", async () => {
    await withEnsure(
      {
        alreadyBound: true,
        instanceId: "i-fork",
        reserved: { ".instance-id": "i-parent\n", [`${SESSION}/runtime.json`]: "{}", [`${SESSION}/auth/identity.json`]: "fork" },
      },
      ({ status, reserved }) => {
        expect(status).toBe(0);
        expect(read(reserved, ".instance-id")).toBe("i-fork\n");
        expect(read(reserved, `${SESSION}/runtime.json`)).toBe("{}");
        expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("fork");
      },
    );
  }, TEST_TIMEOUT_MS);

  test("a running daemon's directory is never covered", async () => {
    await withEnsure({ daemonRunning: true, onRoot: { [`${SESSION}/runtime.json`]: "{}" } }, ({ status, stderr, bound, reserved }) => {
      expect(status).toBe(0);
      expect(bound).toBe(false);
      expect(existsSync(reserved)).toBe(false);
      expect(stderr).toContain("remote state moves at its next start");
    });
  }, TEST_TIMEOUT_MS);

  test("an image without a reservation marker keeps its layout", async () => {
    await withEnsure({ noMarker: true, onRoot: { [`${SESSION}/runtime.json`]: "{}" } }, ({ status, bound, reserved }) => {
      expect(status).toBe(0);
      expect(bound).toBe(false);
      expect(existsSync(reserved)).toBe(false);
    });
  }, TEST_TIMEOUT_MS);

  test("the daemon's /tmp directories exist before it starts, since it cannot mkdir them on a full root", async () => {
    await withEnsure({ tmpDirs: ["cmux-th-1000"] }, ({ status, tmp }) => {
      expect(status).toBe(0);
      for (const name of ["cmux-tui-1000", "cmux-th-1000", "cmux-image-paste-1000"]) {
        expect(statSync(path.join(tmp, name)).isDirectory()).toBe(true);
      }
      expect(statSync(path.join(tmp, "cmux-tui-1000")).mode & 0o777).toBe(0o700);
      expect(existsSync(path.join(tmp, "cmux-th-1000/kept"))).toBe(true);
    });
  }, TEST_TIMEOUT_MS);

  test("a path someone else planted in /tmp is left alone, and a failed mkdir does not defer the daemon", async () => {
    await withEnsure({ tmpFile: "cmux-tui-1000", tmpMkdirFails: true }, ({ status, stderr, tmp }) => {
      expect(status).toBe(0);
      expect(readFileSync(path.join(tmp, "cmux-tui-1000"), "utf8")).toBe("planted");
      expect(stderr).toContain("could not create");
    });
  }, TEST_TIMEOUT_MS);

  test("an image without a reservation creates nothing in /tmp", async () => {
    await withEnsure({ noMarker: true }, ({ tmp }) => {
      expect(existsSync(path.join(tmp, "cmux-tui-1000"))).toBe(false);
    });
  }, TEST_TIMEOUT_MS);

  test("a state image that cannot mount defers the daemon and never moves remote state to the root filesystem", async () => {
    await withEnsure({ loopMountFails: true, onRoot: { [`${SESSION}/auth/identity.json`]: "identity" } }, ({ status, bound, remote, reserved }) => {
      expect(status).not.toBe(0);
      expect(bound).toBe(false);
      expect(existsSync(reserved)).toBe(false);
      expect(read(remote, `${SESSION}/auth/identity.json`)).toBe("identity");
    });
  }, TEST_TIMEOUT_MS);

  test("a marker with no state image binds nothing", async () => {
    await withEnsure({ noImage: true, onRoot: { [`${SESSION}/auth/identity.json`]: "identity" } }, ({ status, bound, reserved }) => {
      expect(status).toBe(0);
      expect(bound).toBe(false);
      expect(existsSync(reserved)).toBe(false);
    });
  }, TEST_TIMEOUT_MS);

  test("only the supervised daemon holds the move back, not a daemon the user runs in a pane", async () => {
    await withEnsure({ daemonRunning: true, onRoot: { [`${SESSION}/runtime.json`]: "{}" } }, ({ pgrepPattern }) => {
      expect(pgrepPattern).toContain("--session cloud");
    });
  }, TEST_TIMEOUT_MS);

  test("the root copy stays until the reserved copy is flushed, so a power cut cannot leave only an empty identity", async () => {
    await withEnsure({ syncFails: true, onRoot: { [`${SESSION}/auth/identity.json`]: "identity" } }, ({ status, bound, remote, reserved }) => {
      expect(status).toBe(0);
      expect(bound).toBe(true);
      expect(read(remote, `${SESSION}/auth/identity.json`)).toBe("identity");
      expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("identity");
    });
  }, TEST_TIMEOUT_MS);

  test("a root copy left by a crash or a rollback is removed at the next bind", async () => {
    await withEnsure(
      { onRoot: { [`${SESSION}/auth/identity.json`]: "stale" }, reserved: { [`${SESSION}/auth/identity.json`]: "current" } },
      ({ remote, reserved, synced }) => {
        expect(existsSync(path.join(remote, "sessions"))).toBe(false);
        expect(read(reserved, `${SESSION}/auth/identity.json`)).toBe("current");
        expect(synced).toContain(reserved);
      },
    );
  }, TEST_TIMEOUT_MS);

  test("a machine with nothing on the root path skips the flush, which New Machine would wait for", async () => {
    await withEnsure({}, ({ synced }) => {
      expect(synced).toBe("");
    });
  }, TEST_TIMEOUT_MS);

  test("a failed bind does not defer the daemon", async () => {
    await withEnsure({ mountFails: true }, ({ status, stderr, bound }) => {
      expect(status).toBe(0);
      expect(bound).toBe(false);
      expect(stderr).toContain("remote state stays on the root filesystem");
    });
  }, TEST_TIMEOUT_MS);

  test("a failed copy leaves no partial reserved copy for a later start to trust", async () => {
    await withEnsure({ copyFails: true, onRoot: { [`${SESSION}/auth/identity.json`]: "identity" } }, ({ status, bound, remote, reserved, stderr }) => {
      expect(status).toBe(0);
      expect(read(remote, `${SESSION}/auth/identity.json`)).toBe("identity");
      expect(bound).toBe(false);
      expect(existsSync(reserved)).toBe(false);
      expect(existsSync(`${reserved}.new`)).toBe(false);
      expect(stderr).toContain("remote state stays on the root filesystem");
    });
  }, TEST_TIMEOUT_MS);
});
