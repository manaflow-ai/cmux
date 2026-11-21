import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";

// The boot supervisor protects the cmux-tui daemon from the kernel OOM killer
// without protecting the user's work. oom_score_adj is inherited across fork,
// so every terminal host and shell the daemon spawns would carry the daemon's
// protection; the supervisor hands those back the default score. These tests
// run the supervisor's real functions against a scratch /proc.

const devboxBoot = readFileSync(
  path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-devbox-boot"),
  "utf8",
);
const TEST_TIMEOUT_MS = 20_000;

function shellFunction(name: string): string {
  const start = devboxBoot.indexOf(`\n${name}() {\n`);
  expect(start).toBeGreaterThan(-1);
  const end = devboxBoot.indexOf("\n}\n", start) + 3;
  return devboxBoot.slice(start + 1, end);
}

function shellAssignment(name: string): string {
  const match = devboxBoot.match(new RegExp(`^${name}=(.*)$`, "m"));
  expect(match).not.toBeNull();
  return match![1]!;
}

/** pid -> oom_score_adj in a scratch /proc; returns the score each pid ends with. */
async function runWithProc(scores: Record<string, number>, daemonPid: string, calls: string[]) {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-devbox-oom-"));
  try {
    const proc = path.join(root, "proc");
    for (const [pid, score] of Object.entries(scores)) {
      mkdirSync(path.join(proc, pid), { recursive: true });
      writeFileSync(path.join(proc, pid, "oom_score_adj"), `${score}\n`);
    }
    // Non-process entries /proc also has.
    mkdirSync(path.join(proc, "sys"), { recursive: true });
    writeFileSync(path.join(proc, "self"), "");
    const result = await runChild("sh", ["-c", [
      `DAEMON_OOM_SCORE_ADJ=${shellAssignment("DAEMON_OOM_SCORE_ADJ")}`,
      `PROC_DIR='${proc}'`,
      `daemon_pid='${daemonPid}'`,
      shellFunction("protect_daemon_from_oom"),
      shellFunction("release_inherited_oom_protection"),
      ...calls,
    ].join("\n")], { timeout: 15_000 });
    const after: Record<string, number> = {};
    for (const pid of Object.keys(scores)) {
      after[pid] = Number(readFileSync(path.join(proc, pid, "oom_score_adj"), "utf8").trim());
    }
    return { ...result, after };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe("cmux-tui daemon OOM protection", () => {
  test("the daemon's score is negative, never -1000, and distinct from the platform agent's -900", () => {
    const value = Number(shellAssignment("DAEMON_OOM_SCORE_ADJ"));
    expect(value).toBeLessThan(0);
    expect(value).toBeGreaterThan(-1000);
    // The Freestyle guest agent and dbus run at -900; the release below
    // matches the daemon's own value, so it must not touch theirs.
    expect(value).not.toBe(-900);
    expect(shellAssignment("PROC_DIR")).toBe("/proc");
  });

  test(
    "protecting the daemon writes its score to the daemon's own process",
    async () => {
      const result = await runWithProc({ "4242": 0, "4243": 0 }, "4242", ["protect_daemon_from_oom"]);
      expect(result.status).toBe(0);
      expect(result.after["4242"]).toBe(Number(shellAssignment("DAEMON_OOM_SCORE_ADJ")));
      expect(result.after["4243"]).toBe(0);
    },
    TEST_TIMEOUT_MS,
  );

  test(
    "terminal hosts, shells and their children that inherited the daemon's score get the default back",
    async () => {
      const daemon = Number(shellAssignment("DAEMON_OOM_SCORE_ADJ"));
      const result = await runWithProc(
        {
          "100": daemon, // the daemon
          "101": daemon, // a terminal host it spawned
          "102": daemon, // that host's shell
          "103": daemon, // a build the user started from it
          "200": -900, // the Freestyle agent
          "201": -1000, // sshd
          "300": 0, // an unrelated process
          "301": 500, // a process the user made more killable
        },
        "100",
        ["release_inherited_oom_protection"],
      );
      expect(result.status).toBe(0);
      expect(result.after).toEqual({
        "100": daemon,
        "101": 0,
        "102": 0,
        "103": 0,
        "200": -900,
        "201": -1000,
        "300": 0,
        "301": 500,
      });
    },
    TEST_TIMEOUT_MS,
  );

  test(
    "without a running daemon nothing keeps the protection",
    async () => {
      const daemon = Number(shellAssignment("DAEMON_OOM_SCORE_ADJ"));
      const result = await runWithProc({ "101": daemon, "200": -900 }, "", [
        "protect_daemon_from_oom",
        "release_inherited_oom_protection",
      ]);
      expect(result.status).toBe(0);
      expect(result.after).toEqual({ "101": 0, "200": -900 });
    },
    TEST_TIMEOUT_MS,
  );

  test("the supervisor protects each daemon it starts and releases inherited scores every tick", () => {
    const start = shellFunction("start_daemon");
    const pid = start.indexOf("daemon_pid=$!");
    const protect = start.indexOf("protect_daemon_from_oom");
    expect(pid).toBeGreaterThan(-1);
    // After the fork, so the supervisor itself and anything it starts later
    // keep the default score; the exec that follows keeps the same pid.
    expect(protect).toBeGreaterThan(pid);
    const loop = devboxBoot.slice(devboxBoot.indexOf("\nwhile true; do\n"));
    const health = loop.indexOf("check_daemon_health");
    const release = loop.indexOf("release_inherited_oom_protection");
    expect(health).toBeGreaterThan(-1);
    expect(release).toBeGreaterThan(health);
    expect(release).toBeLessThan(loop.indexOf('sleep "$tick"'));
  });
});
