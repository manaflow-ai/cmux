import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";

// cmux-machine-hygiene reclaims disk on an agent machine without touching
// source. Every test builds a throwaway machine under the system temp
// directory, points the script at it with --home/--root/--tmp-dir, and
// asserts that nothing the script reports or removes lies outside it. Docker
// is a stub that only logs its arguments, so no test prunes real images, and
// `mount` is a stub that prints the fixture's mounts file.

const SCRIPT = path.join(import.meta.dirname, "../services/vms/hygiene/cmux-machine-hygiene");
const DAY_S = 24 * 60 * 60;

setDefaultTimeout(30_000);

const fixtures: string[] = [];
afterEach(() => {
  for (const root of fixtures.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Item = { category: string; path: string; kb: number; action: string; reason?: string };
type Report = { version: number; mode: string; home: string; reclaimableKb: number; items: Item[] };

type Machine = {
  root: string;
  home: string;
  tmp: string;
  code: string;
  bin: string;
  dockerLog: string;
  /** Lines the stub `mount` prints, in Linux format. */
  mounts: string;
};

function write(file: string, body = "x") {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, body);
}

/** Sets mtime and atime on a tree, so the script sees it as idle for that long. */
function age(target: string, days: number) {
  const when = Date.now() / 1000 - days * DAY_S;
  const visit = (entry: string) => {
    if (statSync(entry, { throwIfNoEntry: false })?.isDirectory()) {
      for (const child of readdirSync(entry)) visit(path.join(entry, child));
    }
    utimesSync(entry, when, when);
  };
  visit(target);
}

function machine(): Machine {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-hygiene-"));
  fixtures.push(root);
  const home = path.join(root, "home");
  const tmp = path.join(root, "tmp");
  const code = path.join(home, "code");
  const bin = path.join(root, "bin");
  const dockerLog = path.join(root, "docker.calls");
  const mounts = path.join(root, "mounts");
  for (const dir of [home, tmp, code, bin]) mkdirSync(dir, { recursive: true });
  writeFileSync(mounts, "/dev/root on / type ext4 (rw,relatime)\n");
  writeFileSync(path.join(bin, "mount"), ["#!/bin/sh", `cat ${JSON.stringify(mounts)}`, ""].join("\n"));
  chmodSync(path.join(bin, "mount"), 0o755);
  writeFileSync(
    path.join(bin, "docker"),
    ["#!/bin/sh", `printf '%s\\n' "$*" >> ${JSON.stringify(dockerLog)}`, "exit 0", ""].join("\n"),
  );
  chmodSync(path.join(bin, "docker"), 0o755);
  return { root, home, tmp, code, bin, dockerLog, mounts };
}

/** A project with source, git metadata and a build artifact directory. */
function project(m: Machine, name: string, artifact: string, marker: string) {
  const dir = path.join(m.code, name);
  write(path.join(dir, marker), "{}");
  write(path.join(dir, "src", "main.ts"), "export {};");
  write(path.join(dir, ".git", "HEAD"), "ref: refs/heads/main\n");
  write(path.join(dir, artifact, "pkg", "index.js"), "module.exports = 1;");
  return dir;
}

function runRaw(m: Machine, args: string[]) {
  return runChild("bash", [SCRIPT, ...args], {
    env: { PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`, HOME: m.home, TMPDIR: m.tmp },
  });
}

async function run(m: Machine, args: string[] = []): Promise<Report> {
  const result = await runRaw(m, ["--home", m.home, "--root", m.code, "--tmp-dir", m.tmp, ...args]);
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  const report = JSON.parse(result.stdout) as Report;
  // Nothing outside the throwaway machine may ever be reported or removed.
  for (const item of report.items) {
    if (item.path.startsWith("/")) expect(item.path.startsWith(m.root)).toBe(true);
  }
  return report;
}

const paths = (report: Report, action: string, category?: string) =>
  report.items
    .filter((item) => item.action === action && (!category || item.category === category))
    .map((item) => item.path);

describe("cmux-machine-hygiene", () => {
  test("dry-run is the default and removes nothing", async () => {
    const m = machine();
    const app = project(m, "app", "node_modules", "package.json");
    age(app, 30);
    const report = await run(m, ["--skip", "docker"]);
    expect(report.mode).toBe("dry-run");
    expect(paths(report, "would-delete", "project-artifacts")).toEqual([path.join(app, "node_modules")]);
    expect(existsSync(path.join(app, "node_modules", "pkg", "index.js"))).toBe(true);
    expect(paths(report, "deleted")).toEqual([]);
  });

  test("apply removes idle artifacts and keeps source, git metadata and recent builds", async () => {
    const m = machine();
    const idleNode = project(m, "idle-node", "node_modules", "package.json");
    const idleRust = project(m, "idle-rust", "target", "Cargo.toml");
    const busy = project(m, "busy", "node_modules", "package.json");
    age(idleNode, 30);
    age(idleRust, 30);
    age(busy, 30);
    write(path.join(busy, "node_modules", "fresh.js"), "1");
    const report = await run(m, ["--apply", "--skip", "docker"]);
    expect(paths(report, "deleted", "project-artifacts").sort()).toEqual(
      [path.join(idleNode, "node_modules"), path.join(idleRust, "target")].sort(),
    );
    for (const dir of [idleNode, idleRust, busy]) {
      expect(existsSync(path.join(dir, "src", "main.ts"))).toBe(true);
      expect(existsSync(path.join(dir, ".git", "HEAD"))).toBe(true);
    }
    expect(existsSync(path.join(busy, "node_modules", "fresh.js"))).toBe(true);
  });

  test("never treats a directory without its project marker as an artifact", async () => {
    const m = machine();
    const dir = path.join(m.code, "not-rust");
    write(path.join(dir, "target", "notes.md"), "keep me");
    age(dir, 30);
    const report = await run(m, ["--apply", "--skip", "docker"]);
    expect(existsSync(path.join(dir, "target", "notes.md"))).toBe(true);
    expect(paths(report, "deleted")).toEqual([]);
  });

  test("does not follow a symlinked artifact out of the machine", async () => {
    const m = machine();
    const victim = path.join(m.root, "outside", "precious");
    write(path.join(victim, "data.txt"), "keep me");
    const app = path.join(m.code, "app");
    write(path.join(app, "package.json"), "{}");
    symlinkSync(path.dirname(victim), path.join(app, "node_modules"));
    age(app, 30);
    const report = await run(m, ["--apply", "--skip", "docker"]);
    expect(existsSync(path.join(victim, "data.txt"))).toBe(true);
    expect(paths(report, "deleted")).toEqual([]);
  });

  test("keeps protected homes and agent sessions, and trims only old agent logs", async () => {
    const m = machine();
    write(path.join(m.home, ".ssh", "id_ed25519"), "secret");
    write(path.join(m.home, ".cmux", "journal", "events"), "daemon state");
    write(path.join(m.home, ".claude", "projects", "s.jsonl"), "session");
    write(path.join(m.home, ".claude", "debug", "old.txt"), "old log");
    write(path.join(m.home, ".claude", "debug", "new.txt"), "new log");
    write(path.join(m.home, ".codex", "sessions", "s.jsonl"), "session");
    write(path.join(m.home, ".codex", "log", "codex-tui.log"), "old log");
    age(path.join(m.home, ".ssh"), 90);
    age(path.join(m.home, ".cmux"), 90);
    age(path.join(m.home, ".claude", "projects"), 90);
    age(path.join(m.home, ".claude", "debug", "old.txt"), 30);
    age(path.join(m.home, ".codex"), 90);
    const report = await run(m, ["--apply", "--skip", "docker"]);
    expect(paths(report, "deleted", "agent-logs").sort()).toEqual(
      [path.join(m.home, ".claude", "debug", "old.txt"), path.join(m.home, ".codex", "log", "codex-tui.log")].sort(),
    );
    for (const kept of [
      ".ssh/id_ed25519",
      ".cmux/journal/events",
      ".claude/projects/s.jsonl",
      ".claude/debug/new.txt",
      ".codex/sessions/s.jsonl",
    ]) {
      expect(existsSync(path.join(m.home, kept))).toBe(true);
    }
  });

  test("clears package caches only under disk pressure", async () => {
    const m = machine();
    write(path.join(m.home, ".npm", "_cacache", "index"), "cache");
    write(path.join(m.home, ".cache", "uv", "wheel"), "cache");
    const calm = await run(m, ["--apply", "--only", "package-caches", "--pressure-pct", "100"]);
    expect(paths(calm, "deleted")).toEqual([]);
    expect(existsSync(path.join(m.home, ".npm", "_cacache", "index"))).toBe(true);
    const pressured = await run(m, ["--apply", "--only", "package-caches", "--pressure-pct", "0"]);
    expect(paths(pressured, "deleted", "package-caches").sort()).toEqual(
      [path.join(m.home, ".npm", "_cacache"), path.join(m.home, ".cache", "uv")].sort(),
    );
  });

  test("removes only the user's idle temp entries", async () => {
    const m = machine();
    write(path.join(m.tmp, "old-build.log"), "old");
    write(path.join(m.tmp, "scratch", "a.txt"), "old");
    write(path.join(m.tmp, "cmux-socket-dir", "s"), "daemon");
    write(path.join(m.tmp, "today.txt"), "new");
    age(path.join(m.tmp, "old-build.log"), 30);
    age(path.join(m.tmp, "scratch"), 30);
    age(path.join(m.tmp, "cmux-socket-dir"), 30);
    const report = await run(m, ["--apply", "--only", "temp-files"]);
    expect(paths(report, "deleted", "temp-files").sort()).toEqual(
      [path.join(m.tmp, "old-build.log"), path.join(m.tmp, "scratch")].sort(),
    );
    expect(existsSync(path.join(m.tmp, "cmux-socket-dir", "s"))).toBe(true);
    expect(existsSync(path.join(m.tmp, "today.txt"))).toBe(true);
  });

  test("prunes records of deleted worktrees and keeps live worktrees", async () => {
    const m = machine();
    const repo = path.join(m.code, "repo");
    const git = (args: string[]) =>
      runChild("git", args, {
        cwd: repo,
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", HOME: m.home },
      });
    mkdirSync(repo, { recursive: true });
    await git(["init", "-q", "-b", "main"]);
    write(path.join(repo, "README.md"), "hi");
    await git(["add", "README.md"]);
    await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"]);
    await git(["worktree", "add", "-q", path.join(m.code, "live"), "-b", "live"]);
    await git(["worktree", "add", "-q", path.join(m.code, "gone"), "-b", "gone"]);
    rmSync(path.join(m.code, "gone"), { recursive: true, force: true });

    const dry = await run(m, ["--only", "git-worktrees"]);
    expect(paths(dry, "would-delete", "git-worktrees")).toEqual([repo]);
    const applied = await run(m, ["--apply", "--only", "git-worktrees"]);
    expect(paths(applied, "deleted", "git-worktrees")).toEqual([repo]);
    const list = await git(["worktree", "list", "--porcelain"]);
    expect(list.stdout).toContain(path.join(m.code, "live"));
    expect(list.stdout).not.toContain(path.join(m.code, "gone"));
    expect(existsSync(path.join(m.code, "live", "README.md"))).toBe(true);
  });

  test("prunes only dangling Docker data, and only with --apply", async () => {
    const m = machine();
    await run(m, ["--only", "docker"]);
    expect(readFileSync(m.dockerLog, "utf8").trim().split("\n")).toEqual(["info"]);
    await run(m, ["--apply", "--only", "docker"]);
    expect(readFileSync(m.dockerLog, "utf8").trim().split("\n")).toEqual([
      "info",
      "info",
      "image prune --force",
      "builder prune --force --filter until=168h",
    ]);
  });

  test("keeps an artifact directory the repository tracks", async () => {
    const m = machine();
    const repo = path.join(m.code, "vendored");
    write(path.join(repo, "package.json"), "{}");
    write(path.join(repo, "node_modules", "patched", "index.js"), "tracked");
    const git = (args: string[]) =>
      runChild("git", args, {
        cwd: repo,
        env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", HOME: m.home },
      });
    await git(["init", "-q", "-b", "main"]);
    await git(["add", "-f", "package.json", "node_modules/patched/index.js"]);
    await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "vendored"]);
    age(repo, 30);
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(repo, "node_modules"), action: "skipped", reason: "git-tracked" }),
    );
    expect(existsSync(path.join(repo, "node_modules", "patched", "index.js"))).toBe(true);
  });

  test("keeps artifacts of a project a running process works in", async () => {
    const m = machine();
    const app = project(m, "app", "node_modules", "package.json");
    age(app, 30);
    const busy = spawn("sleep", ["30"], { cwd: path.join(app, "src"), stdio: "ignore" });
    await new Promise((resolve) => busy.once("spawn", resolve));
    try {
      const report = await run(m, ["--apply", "--only", "project-artifacts"]);
      expect(report.items).toContainEqual(
        expect.objectContaining({ path: path.join(app, "node_modules"), action: "skipped", reason: "project-in-use" }),
      );
      expect(existsSync(path.join(app, "node_modules", "pkg", "index.js"))).toBe(true);
    } finally {
      const exited = new Promise((resolve) => busy.once("exit", resolve));
      busy.kill();
      await exited;
    }
  });

  test("finishes a removal an interrupted run left behind, but not one still running", async () => {
    const m = machine();
    const deadPid = 2_147_483_000;
    const dead = path.join(m.code, "app", `.cmux-hygiene-deleting-node_modules-${deadPid}`);
    const live = path.join(m.code, "app", `.cmux-hygiene-deleting-target-${process.pid}`);
    write(path.join(dead, "pkg", "index.js"));
    write(path.join(live, "debug", "app"));
    const report = await run(m, ["--apply", "--only", "interrupted"]);
    expect(paths(report, "deleted", "interrupted")).toEqual([dead]);
    expect(existsSync(dead)).toBe(false);
    expect(existsSync(path.join(live, "debug", "app"))).toBe(true);
  });

  test("refuses an unsafe home, root or temp directory", async () => {
    const m = machine();
    const cases: string[][] = [
      ["--home", "/", "--root", m.code, "--tmp-dir", m.tmp],
      ["--home", m.home, "--root", "/", "--tmp-dir", m.tmp],
      ["--home", m.home, "--root", m.code, "--tmp-dir", m.home],
      ["--home", m.home, "--root", m.code, "--tmp-dir", m.root],
      ["--home", m.home, "--root", m.code, "--tmp-dir", "/etc"],
    ];
    for (const args of cases) {
      const result = await runRaw(m, args);
      expect({ args, status: result.status, stdout: result.stdout }).toEqual({ args, status: 3, stdout: "" });
    }
  });

  test("refuses --apply without an explicit home and root", async () => {
    const m = machine();
    for (const args of [
      ["--apply", "--root", m.code, "--tmp-dir", m.tmp],
      ["--apply", "--home", m.home, "--tmp-dir", m.tmp],
    ]) {
      const result = await runRaw(m, args);
      expect({ args, status: result.status, stdout: result.stdout }).toEqual({ args, status: 2, stdout: "" });
    }
  });

  test("refuses a path reached through a symlinked parent", async () => {
    const m = machine();
    const realClaude = path.join(m.root, "outside", "claude");
    write(path.join(realClaude, "debug", "old.txt"), "keep me");
    age(path.join(realClaude, "debug", "old.txt"), 30);
    symlinkSync(realClaude, path.join(m.home, ".claude"));
    const report = await run(m, ["--apply", "--only", "agent-logs"]);
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(m.home, ".claude", "debug", "old.txt"), reason: "symlinked-parent" }),
    );
    expect(existsSync(path.join(realClaude, "debug", "old.txt"))).toBe(true);
  });

  test("never removes a mount point or a tree holding one", async () => {
    const m = machine();
    const mounted = project(m, "mounted", "node_modules", "package.json");
    const holding = project(m, "holding", "node_modules", "package.json");
    age(mounted, 30);
    age(holding, 30);
    writeFileSync(
      m.mounts,
      [
        "/dev/root on / type ext4 (rw)",
        `/dev/sdb on ${path.join(mounted, "node_modules")} type ext4 (rw)`,
        `tmpfs on ${path.join(holding, "node_modules", "pkg")} type tmpfs (rw)`,
        "",
      ].join("\n"),
    );
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(mounted, "node_modules"), reason: "mount-point" }),
    );
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(holding, "node_modules"), reason: "contains-mount" }),
    );
    expect(existsSync(path.join(mounted, "node_modules", "pkg", "index.js"))).toBe(true);
    expect(existsSync(path.join(holding, "node_modules", "pkg", "index.js"))).toBe(true);
  });

  test("treats newline and glob names as single names", async () => {
    const m = machine();
    // A newline name must not split into the fresh sibling "keep".
    write(path.join(m.tmp, "keep\nme"), "odd");
    write(path.join(m.tmp, "keep"), "fresh");
    age(path.join(m.tmp, "keep\nme"), 30);
    // A project named "*" must not glob onto its siblings.
    const star = project(m, "*", "node_modules", "package.json");
    const sibling = project(m, "b", "node_modules", "package.json");
    age(star, 30);
    const report = await run(m, ["--apply", "--only", "temp-files", "--only", "project-artifacts"]);
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(m.tmp, "keep\nme"), action: "skipped", reason: "unsafe-name" }),
    );
    expect(existsSync(path.join(m.tmp, "keep\nme"))).toBe(true);
    expect(existsSync(path.join(m.tmp, "keep"))).toBe(true);
    expect(paths(report, "deleted", "project-artifacts")).toEqual([path.join(star, "node_modules")]);
    expect(existsSync(path.join(sibling, "node_modules", "pkg", "index.js"))).toBe(true);
  });

  test("stays small enough to ship through the provider's exec limit", () => {
    expect(statSync(SCRIPT).size).toBeLessThan(24 * 1024);
  });
});
