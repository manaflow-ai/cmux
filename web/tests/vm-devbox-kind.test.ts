import { afterEach, describe, expect, test } from "bun:test";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync, chmodSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";
import {
  CMUX_TUI_REQUIRED_MOVE_CAPABILITIES,
  DEVBOX_VM_KIND_PATH,
  devboxMoveToCloudChecks,
  devboxNoVmKindCommand,
  devboxParkDaemonCommand,
  devboxVmKindSyncUnit,
} from "../scripts/devbox-image-common";

// Move to Cloud on a production personal machine (cx-rppd.14). cmux-tui on a
// Cloud VM refuses to start or receive a chat unless the root-owned
// /etc/cmux/vm-kind reads `owner` (cmux-tui agent_start_host.rs). The guest's
// root-run cmux-vm-kind-sync asks GET /api/vm/reflection/kind and writes the
// answer; the image never carries one, and its daemon must serve the move.

const templateDir = path.join(import.meta.dirname, "../services/vms/images/devbox");
const scriptsDir = path.join(import.meta.dirname, "../scripts");
const kindSync = path.join(templateDir, "cmux-vm-kind-sync");
const read = (file: string) => readFileSync(file, "utf8");

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});
function fixture(): string {
  const directory = mkdtempSync(path.join(tmpdir(), "cmux-vm-kind-"));
  directories.push(directory);
  return directory;
}

/** Runs cmux-vm-kind-sync's functions in python3 against a directory. */
async function python(code: string, ...args: string[]) {
  return runChild("python3", ["-c", String.raw`
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("kind_sync", sys.argv[1])
spec = importlib.util.spec_from_loader("kind_sync", loader)
module = importlib.util.module_from_spec(spec); loader.exec_module(module)
` + code, kindSync, ...args]);
}

describe("cmux-vm-kind-sync (the guest writer)", () => {
  test("writes owner as a regular 0644 file owned by the writer, atomically, with no temp file left", async () => {
    const etc = path.join(fixture(), "cmux");
    const result = await python(String.raw`
import pathlib
print(module.publish(pathlib.Path(sys.argv[2]), "owner"))
print(module.publish(pathlib.Path(sys.argv[2]), "owner"))
`, etc);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim().split("\n")).toEqual(["True", "False"]);
    const record = path.join(etc, "vm-kind");
    const info = lstatSync(record);
    expect(info.isFile()).toBe(true);
    expect(info.mode & 0o777).toBe(0o644);
    expect(info.uid).toBe(process.getuid!());
    expect(read(record)).toBe("owner\n");
    expect(lstatSync(etc).mode & 0o777).toBe(0o755);
    expect(readdirSync(etc)).toEqual(["vm-kind"]);
  });

  test("team replaces owner by rename, and a planted symlink is replaced, never followed", async () => {
    const root = fixture();
    const etc = path.join(root, "cmux");
    mkdirSync(etc, { mode: 0o755 });
    const elsewhere = path.join(root, "elsewhere");
    writeFileSync(elsewhere, "untouched\n");
    symlinkSync(elsewhere, path.join(etc, "vm-kind"));
    const result = await python(String.raw`
import os, pathlib
d = pathlib.Path(sys.argv[2])
module.publish(d, "owner")
before = os.lstat(d / "vm-kind").st_ino
module.publish(d, "team")
print(before != os.lstat(d / "vm-kind").st_ino)
`, etc);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim()).toBe("True");
    expect(lstatSync(path.join(etc, "vm-kind")).isSymbolicLink()).toBe(false);
    expect(read(path.join(etc, "vm-kind"))).toBe("team\n");
    expect(read(elsewhere)).toBe("untouched\n");
  });

  test("refuses a symlinked folder and tightens a group- or other-writable one", async () => {
    const root = fixture();
    const real = path.join(root, "real");
    mkdirSync(real);
    symlinkSync(real, path.join(root, "cmux"));
    const refused = await python(String.raw`
import pathlib
try:
    module.publish(pathlib.Path(sys.argv[2]), "owner")
    print("wrote")
except OSError as error:
    print("refused")
`, path.join(root, "cmux"));
    expect(refused.stdout.trim()).toBe("refused");
    expect(readdirSync(real)).toEqual([]);

    const loose = path.join(root, "loose");
    mkdirSync(loose);
    chmodSync(loose, 0o777);
    const tightened = await python(String.raw`
import pathlib
module.publish(pathlib.Path(sys.argv[2]), "owner")
`, loose);
    expect(tightened.stderr).toBe("");
    expect(lstatSync(loose).mode & 0o777).toBe(0o755);
  });

  test("writes only owner or team from a well-formed answer, and keeps the record otherwise", async () => {
    const etc = path.join(fixture(), "cmux");
    const result = await python(String.raw`
import pathlib
d = pathlib.Path(sys.argv[2])
module.publish(d, "team")
for payload in [{"vm_id": "vm-1", "kind": "admin"}, {"kind": "owner"}, {"vm_id": "", "kind": "owner"}, ["owner"], {"vm_id": "vm-1"}]:
    try:
        module.publish(d, module.parse_kind(payload))
        print("wrote")
    except ValueError:
        print("rejected")
try:
    module.publish(d, "admin")
    print("wrote")
except ValueError:
    print("rejected")
print(module.parse_kind({"vm_id": "vm-1", "kind": "owner"}))
`, etc);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim().split("\n")).toEqual([...Array(6).fill("rejected"), "owner"]);
    expect(read(path.join(etc, "vm-kind"))).toBe("team\n");
  });

  test("a refusal drops the record at once, an outage only after five minutes, and no failure crashes the loop", async () => {
    const run = (script: string) => python(String.raw`
import io, pathlib, sys as _sys, types, urllib.error
d = pathlib.Path(sys.argv[2])
clock = {"now": 1000.0, "sleeps": 0}
def sleep(seconds):
    clock["now"] += seconds
    clock["sleeps"] += 1
    if clock["sleeps"] > 40:
        raise SystemExit(0)
module.time = types.SimpleNamespace(sleep=sleep, monotonic=lambda: clock["now"])
answers = iter(` + script + String.raw`)
def fetch(url):
    answer = next(answers, SystemExit(0))
    if isinstance(answer, BaseException):
        raise answer
    return answer
module.fetch_kind = fetch
_sys.argv = ["cmux-vm-kind-sync", "--directory", str(d)]
try:
    module.main()
except (SystemExit, StopIteration):
    pass
print((d / "vm-kind").read_text().strip() if (d / "vm-kind").exists() else "none")
`, path.join(fixture(), "cmux"));
    const refused = 'urllib.error.HTTPError("u", 409, "vm_not_live", {}, io.BytesIO())';
    const outage = 'urllib.error.URLError("down")';
    // Owner, then a refusal: no record is left.
    let result = await run(`["owner", ${refused}]`);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim()).toBe("none");
    // Owner, then a short outage (well under five minutes of backoff): the record stays.
    result = await run(`["owner", ${outage}, ${outage}, ${outage}]`);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim()).toBe("owner");
    // Owner, then an outage that outlasts five minutes: the record is gone.
    result = await run(`["owner"] + [${outage}] * 12`);
    expect(result.stdout.trim()).toBe("none");
    // An exception outside OSError/ValueError backs off instead of crashing the unit.
    result = await run(`["owner", RuntimeError("http.client.IncompleteRead"), "team"]`);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim()).toBe("team");
  });

  test("never polls faster after a failure than after a success", async () => {
    const result = await python(String.raw`
import io, urllib.error
def run(error, count):
    delay, delays = None, []
    for _ in range(count):
        delay = module.retry_delay(delay, error)
        delays.append(delay)
    return delays
refused = urllib.error.HTTPError("https://reflection.cmux.internal/kind", 401, "Unauthorized", {}, io.BytesIO())
print(run(refused, 11))
print(run(urllib.error.URLError("timed out"), 8))
print(module.SUCCESS_INTERVAL)
`);
    expect(result.stderr).toBe("");
    expect(result.stdout.trim().split("\n")).toEqual([
      "[1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300]",
      "[1, 2, 4, 8, 16, 32, 60, 60]",
      "60",
    ]);
  });
});

describe("devbox image: the kind is written on the machine, never baked", () => {
  const bake = read(path.join(scriptsDir, "build-devbox-freestyle.ts"));
  const boot = read(path.join(templateDir, "cmux-devbox-boot"));
  const verify = read(path.join(scriptsDir, "verify-devbox-image.ts"));

  test("the bake installs the root-run kind sync and proves no record is left before the snapshot", () => {
    expect(bake).toContain('await put("cmux-vm-kind-sync", DEVBOX_VM_KIND_SYNC_PATH, 0o755);');
    expect(bake).toContain("await vm.fs.writeFile(DEVBOX_VM_KIND_SYNC_UNIT_PATH, devboxVmKindSyncUnit(), { mode: 0o644 });");
    expect(bake).toContain("systemctl enable cmux-vm-kind-sync");
    const unit = devboxVmKindSyncUnit();
    expect(unit).toContain("User=root\n");
    expect(unit).toContain("ExecStart=/usr/local/bin/cmux-vm-kind-sync\n");
    expect(unit).toContain("StartLimitIntervalSec=0\n");
    expect(devboxParkDaemonCommand()).toContain("{ systemctl stop cmux-vm-kind-sync 2>/dev/null || true; } && " + devboxNoVmKindCommand());
    const noKind = bake.indexOf('await step("no-baked-vm-kind", devboxNoVmKindCommand());');
    expect(noKind).toBeGreaterThan(bake.indexOf('await step("cmux-vm-kind-sync-unit"'));
    expect(bake.indexOf("const snap = await vm.snapshot(")).toBeGreaterThan(noKind);
    // The park step (bake and every derived size) drops a record too.
    expect(devboxParkDaemonCommand()).toContain(devboxNoVmKindCommand());
    expect(devboxNoVmKindCommand()).toBe(`rm -f ${DEVBOX_VM_KIND_PATH} && test ! -e ${DEVBOX_VM_KIND_PATH} && test ! -L ${DEVBOX_VM_KIND_PATH} && echo no-baked-vm-kind`);
  });

  test("no-baked-vm-kind removes a record and a planted symlink", async () => {
    const etc = path.join(fixture(), "cmux");
    mkdirSync(etc);
    writeFileSync(path.join(etc, "vm-kind"), "owner\n");
    const command = devboxNoVmKindCommand().replaceAll(DEVBOX_VM_KIND_PATH, path.join(etc, "vm-kind"));
    expect((await runChild("sh", ["-c", command])).stdout.trim()).toBe("no-baked-vm-kind");
    symlinkSync("/nonexistent", path.join(etc, "vm-kind"));
    expect(readlinkSync(path.join(etc, "vm-kind"))).toBe("/nonexistent");
    expect((await runChild("sh", ["-c", command])).stdout.trim()).toBe("no-baked-vm-kind");
    expect(readdirSync(etc)).toEqual([]);
  });

  test("a fresh instance drops the record before its daemon starts and restarts the kind sync", () => {
    expect(boot).toContain("VM_KIND_FILE=/etc/cmux/vm-kind");
    const cloneBranch = boot.indexOf('if [ -n "$id" ] && [ "$id" != "$(cat "$BOUND_INSTANCE_FILE" 2>/dev/null)" ]; then');
    const drop = boot.indexOf('rm -f "$VM_KIND_FILE"', cloneBranch);
    const daemon = boot.indexOf("start_daemon", cloneBranch);
    const restart = boot.indexOf("systemctl --no-block restart cmux-vm-kind-sync.service", cloneBranch);
    expect(drop).toBeGreaterThan(cloneBranch);
    expect(daemon).toBeGreaterThan(drop);
    expect(restart).toBeGreaterThan(daemon);
  });

  test("verify requires the move capabilities in the baked daemon, no record, and the kind sync", () => {
    expect(verify).toContain("...devboxMoveToCloudChecks(),");
    expect([...CMUX_TUI_REQUIRED_MOVE_CAPABILITIES]).toEqual(["agent-transfer-v1", "access-request-v1", "vm-kind"]);
    const [capabilities, noRecord, writer] = devboxMoveToCloudChecks();
    expect(noRecord).toBe(`test ! -e ${DEVBOX_VM_KIND_PATH} && test ! -L ${DEVBOX_VM_KIND_PATH} && echo image-carries-no-vm-kind`);
    expect(writer).toContain("systemctl is-enabled cmux-vm-kind-sync");
    expect(writer).toContain("-p User --value)\" = root");
    expect(capabilities).toContain("/home/cmux/.cmux/bin/cmux-tui");
  });

  test("the capability check fails a daemon built before Move to Cloud", async () => {
    const dir = fixture();
    const [capabilities] = devboxMoveToCloudChecks();
    const run = (binary: string) => runChild("sh", ["-c", capabilities.replaceAll("/home/cmux/.cmux/bin/cmux-tui", binary)]);
    writeFileSync(path.join(dir, "old"), "\0cmux-tui fbbbc77a660f fs-v1\0");
    writeFileSync(path.join(dir, "new"), "\0agent-transfer-v1\0access-request-v1\0vm-kind\0");
    const old = await run(path.join(dir, "old"));
    expect(old.status).not.toBe(0);
    expect(old.stdout).toContain("baked cmux-tui lacks agent-transfer-v1");
    const current = await run(path.join(dir, "new"));
    expect(current.status).toBe(0);
    expect(current.stdout.trim()).toBe("cmux-tui-serves-move-to-cloud");
  });
});
