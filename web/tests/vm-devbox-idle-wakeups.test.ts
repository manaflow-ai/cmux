import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { devboxIdleWakeupCheckCommand } from "../scripts/devbox-image-common";

// The idle-wakeup smoke check runs against a fake /proc: one terminal host
// (main thread plus a worker), the daemon, and a decoy shell whose command
// line mentions both markers, as the verifier's own exec shell does.
let root = "";
afterEach(() => {
  if (root) rmSync(root, { recursive: true, force: true });
  root = "";
});

function task(proc: string, pid: number, tid: number, comm: string, switches: number) {
  const dir = path.join(proc, String(pid), "task", String(tid));
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "comm"), `${comm}\n`);
  writeFileSync(path.join(dir, "status"), `Name:\t${comm}\nvoluntary_ctxt_switches:\t${switches}\nnonvoluntary_ctxt_switches:\t2\n`);
}

function fakeProc(withHost = true): string {
  root = mkdtempSync(path.join(tmpdir(), "idle-wakeups-"));
  const proc = path.join(root, "proc");
  if (withHost) {
    task(proc, 100, 100, "exe", 15_541);
    task(proc, 100, 101, "terminal-host-p", 13);
    writeFileSync(path.join(proc, "100", "cmdline"), "/proc/self/exe\0__terminal-host\0--bootstrap-stdio\0");
  }
  task(proc, 200, 200, "cmux-tui", 1_303);
  writeFileSync(path.join(proc, "200", "cmdline"), "/home/cmux/.cmux/bin/cmux-tui\0server\0start\0--session\0cloud\0");
  task(proc, 300, 300, "bash", 7);
  writeFileSync(path.join(proc, "300", "cmdline"), "bash\0-lc\0echo __terminal-host server start\0");
  return proc;
}

/** Runs the check; the pause step moves the host main thread's counter by `hostDelta`. */
function run(proc: string, hostDelta: number) {
  const status = path.join(proc, "100", "task", "100", "status");
  const pause = `printf 'Name:\\texe\\nvoluntary_ctxt_switches:\\t%s\\n' ${15_541 + hostDelta} > '${status}' 2>/dev/null || true`;
  const result = spawnSync("bash", ["-c", devboxIdleWakeupCheckCommand({ procRoot: proc, windowSeconds: 60, pause })], { encoding: "utf8" });
  return { code: result.status, out: `${result.stdout}${result.stderr}` };
}

describe("devbox idle-wakeup check", () => {
  test("fails on the old 20 ms accept loop (about 3,000 switches a minute)", () => {
    const r = run(fakeProc(), 2_980);
    expect(r.code).toBe(1);
    expect(r.out).toContain("idle-wakeups: host 100 thread 100 (exe main): 2980 voluntary switches in 60s");
    expect(r.out).toContain("FAIL 1 terminal host main thread(s) over 30 switches");
  });

  test("passes when the host blocks on events", () => {
    const r = run(fakeProc(), 2);
    expect(r.code).toBe(0);
    expect(r.out).toContain("PASS 1 terminal host main thread(s) at or under 30 switches in 60s");
    expect(r.out).toContain("daemon 200 thread 200 (cmux-tui main)");
  });

  test("ignores a shell whose command line only mentions the markers", () => {
    const r = run(fakeProc(), 2);
    expect(r.out).not.toContain(" 300 ");
  });

  test("a host whose status disappears in the window is not counted as idle", () => {
    const proc = fakeProc();
    const status = path.join(proc, "100", "task", "100", "status");
    const result = spawnSync("bash", ["-c", devboxIdleWakeupCheckCommand({ procRoot: proc, pause: `rm -f '${status}'` })], { encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(`${result.stdout}${result.stderr}`).toContain("FAIL no terminal host main thread measured");
  });

  test("fails when there is no terminal host to measure", () => {
    const r = run(fakeProc(false), 0);
    expect(r.code).toBe(1);
    expect(r.out).toContain("FAIL no terminal host to measure");
  });
});
