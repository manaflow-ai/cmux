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
// directory, confines the script to it with CMUX_HYGIENE_SANDBOX, points it
// there with --home/--root/--tmp-dir, and
// asserts that nothing the script reports or removes lies outside it. Docker
// is a stub that logs any call (none is allowed: the sandbox never runs
// Docker), and `mount` is a stub that prints the fixture's mounts file.

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

function runRaw(m: Machine, args: string[], env: Record<string, string | undefined> = {}) {
  return runChild("bash", [SCRIPT, ...args], {
    env: {
      PATH: `${m.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
      HOME: m.home,
      TMPDIR: m.tmp,
      CMUX_HYGIENE_SANDBOX: m.root,
      CMUX_HYGIENE_SANDBOX_APPLY: "1",
      ...env,
    },
  });
}

/** Writes the lines the stub `mount` prints. */
function mounts(m: Machine, lines: string[]) {
  writeFileSync(m.mounts, `${lines.join("\n")}\n`);
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

/** Sets mtime and atime on a tree to that many hours ago. */
function ageHours(target: string, hours: number) {
  age(target, hours / 24);
}

/** A git checkout holding a Rust project one level down, like a cmux worktree's cmux-tui/. */
function checkout(m: Machine, name: string, parent = m.code) {
  const dir = path.join(parent, name);
  write(path.join(dir, ".git"), "gitdir: /elsewhere\n");
  write(path.join(dir, "README.md"), "hi");
  const rust = path.join(dir, "cmux-tui");
  write(path.join(rust, "Cargo.toml"), "[package]");
  write(path.join(rust, "src", "main.rs"), "fn main() {}");
  write(path.join(rust, "target", "debug", "deps", "libx.rlib"), "x");
  write(path.join(rust, "target", "debug", "incremental", "x-1", "s-1", "dep-graph.bin"), "x");
  return { dir, target: path.join(rust, "target"), incremental: path.join(rust, "target", "debug", "incremental") };
}

/** Runs a process named `name` (a copy of sleep) with its cwd at `cwd` until stopped. */
async function processIn(m: Machine, cwd: string, name = "sleep") {
  const exe = path.join(m.bin, name);
  if (!existsSync(exe)) writeFileSync(exe, readFileSync("/bin/sleep"), { mode: 0o755 });
  const child = spawn(exe, ["60"], { cwd, stdio: "ignore" });
  await new Promise((resolve) => child.once("spawn", resolve));
  return async () => {
    const exited = new Promise((resolve) => child.once("exit", resolve));
    child.kill();
    await exited;
  };
}

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

  test("never runs Docker by default, nor under the sandbox even when included", async () => {
    const m = machine();
    const byDefault = await run(m, ["--apply"]);
    expect(byDefault.items.filter((item) => item.category === "docker")).toEqual([]);
    const included = await run(m, ["--apply", "--include", "docker", "--only", "docker"]);
    expect(included.items).toEqual([expect.objectContaining({ category: "docker", action: "skipped", reason: "sandbox" })]);
    expect(existsSync(m.dockerLog)).toBe(false);
  });

  test("refuses to run as root", async () => {
    const m = machine();
    writeFileSync(path.join(m.bin, "id"), "#!/bin/sh\n[ \"$1\" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id \"$@\"\n");
    chmodSync(path.join(m.bin, "id"), 0o755);
    const result = await runRaw(m, ["--home", m.home, "--root", m.code, "--tmp-dir", m.tmp]);
    expect(result.status).toBe(3);
    expect(result.stderr).toContain("refusing to run as root");
    expect(result.stdout).toBe("");
  });

  test("allows one --apply run at a time and takes over a dead run's lock", async () => {
    const m = machine();
    const uid = (await runChild("id", ["-u"])).stdout.trim();
    const lock = path.join(m.tmp, `.cmux-hygiene-${uid}.lock`);
    write(path.join(lock, "pid"), String(process.pid));
    const busy = await runRaw(m, ["--apply", "--home", m.home, "--root", m.code, "--tmp-dir", m.tmp]);
    expect(busy.status).toBe(4);
    expect(busy.stdout).toBe("");
    writeFileSync(path.join(lock, "pid"), "2147483000");
    const report = await run(m, ["--apply", "--only", "temp-files"]);
    expect(report.mode).toBe("apply");
    expect(existsSync(lock)).toBe(false);
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

  test("outside the test sandbox, home must be a real user's home and temp a real temp dir", async () => {
    const m = machine();
    const real = { CMUX_HYGIENE_SANDBOX: undefined, TMPDIR: undefined };
    const cases: [string[], string][] = [
      [["--home", m.home, "--root", m.code, "--tmp-dir", "/tmp"], "home"],
      [["--home", "/var/tmp", "--root", "/var/tmp", "--tmp-dir", "/tmp"], "home"],
      [["--home", "/tmp", "--root", "/tmp", "--tmp-dir", "/tmp"], "home"],
      [["--home", "/home", "--root", "/home", "--tmp-dir", "/tmp"], "home"],
      [["--home", m.home, "--root", m.code, "--tmp-dir", m.tmp], "tmp-dir"],
    ];
    for (const [args, label] of cases) {
      const result = await runRaw(m, args, real);
      expect({ args, status: result.status, refused: result.stderr.includes(`refusing unsafe ${label}`) }).toEqual({
        args,
        status: 3,
        refused: true,
      });
    }
    // A $TMPDIR that is not the macOS per-user .../T directory is not a temp dir either.
    const viaTmpdir = await runRaw(m, ["--home", m.home, "--root", m.code], { CMUX_HYGIENE_SANDBOX: undefined });
    expect(viaTmpdir.status).toBe(3);
    expect(viaTmpdir.stderr).toContain("refusing unsafe tmp-dir");
  });

  test("refuses roots outside home and a sandbox that is not directly in a temp dir", async () => {
    const m = machine();
    const outsideHome = await runRaw(m, ["--home", m.home, "--root", m.tmp, "--tmp-dir", m.tmp]);
    expect(outsideHome.status).toBe(3);
    expect(outsideHome.stderr).toContain("refusing unsafe root");
    const nestedSandbox = await runRaw(m, ["--home", path.join(m.code), "--root", m.code, "--tmp-dir", m.tmp], {
      CMUX_HYGIENE_SANDBOX: m.home,
    });
    expect(nestedSandbox.status).toBe(3);
    expect(nestedSandbox.stderr).toContain("refusing unsafe sandbox");
  });

  test("deletes nothing when rm cannot refuse to cross filesystems", async () => {
    const m = machine();
    writeFileSync(
      path.join(m.bin, "rm"),
      [
        "#!/bin/sh",
        'for arg in "$@"; do case "$arg" in --one-file-system|-rfx) exit 64 ;; esac; done',
        'exec /bin/rm "$@"',
        "",
      ].join("\n"),
    );
    chmodSync(path.join(m.bin, "rm"), 0o755);
    const app = project(m, "app", "node_modules", "package.json");
    age(app, 30);
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(app, "node_modules"), action: "skipped", reason: "no-mount-guard" }),
    );
    expect(existsSync(path.join(app, "node_modules", "pkg", "index.js"))).toBe(true);
  });

  test("parses Linux and macOS mount output, keeping odd target names whole", async () => {
    const m = machine();
    const spaced = project(m, "a on b", "node_modules", "package.json");
    const escaped = project(m, "sp ace", "node_modules", "package.json");
    const slashed = project(m, "back\\slash", "node_modules", "package.json");
    const raw = project(m, "raw\\cy", "node_modules", "package.json");
    for (const dir of [spaced, escaped, slashed, raw]) age(dir, 30);
    const linuxTarget = (dir: string) =>
      path.join(dir, "node_modules").replaceAll("\\", "\\134").replaceAll(" ", "\\040");
    mounts(m, [
      "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)",
      "map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)",
      `/dev/disk5 on ${path.join(spaced, "node_modules")} (apfs, local)`,
      `/dev/disk6 on ${path.join(raw, "node_modules")} (apfs, local)`,
      `/dev/sdc on ${linuxTarget(escaped)} type ext4 (rw,relatime)`,
      `/dev/sdd on ${linuxTarget(slashed)} type ext4 (rw,relatime)`,
    ]);
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    for (const dir of [spaced, escaped, slashed, raw]) {
      expect(report.items).toContainEqual(
        expect.objectContaining({ path: path.join(dir, "node_modules"), reason: "mount-point" }),
      );
      expect(existsSync(path.join(dir, "node_modules", "pkg", "index.js"))).toBe(true);
    }
  });

  test("does not start in the sandbox without a parsable mount list", async () => {
    const m = machine();
    const app = project(m, "app", "node_modules", "package.json");
    age(app, 30);
    const cases = [
      [],
      ["this is not a mount line"],
      ["/dev/root on / type ext4 (rw)", "garbage on /x"],
      // Two " on /" make the target ambiguous.
      ["/dev/root on / type ext4 (rw)", `u@h:/a on /b on ${m.code} type fuse.sshfs (rw)`],
    ];
    for (const lines of cases) {
      mounts(m, lines);
      const result = await runRaw(m, ["--apply", "--home", m.home, "--root", m.code, "--tmp-dir", m.tmp]);
      expect({ lines, status: result.status, refused: result.stderr.includes("no mount evidence") }).toEqual({
        lines,
        status: 3,
        refused: true,
      });
      expect(existsSync(path.join(app, "node_modules", "pkg", "index.js"))).toBe(true);
    }
  });

  test("never removes anything under a mount nested in home", async () => {
    const m = machine();
    const app = project(m, "app", "node_modules", "package.json");
    age(app, 30);
    // A bind mount shares the device, so only the mount list can tell.
    mounts(m, ["/dev/root on / type ext4 (rw)", `/dev/root on ${app} type ext4 (rw,bind)`]);
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    expect(report.items).toContainEqual(
      expect.objectContaining({ path: path.join(app, "node_modules"), reason: "under-mount" }),
    );
    expect(existsSync(path.join(app, "node_modules", "pkg", "index.js"))).toBe(true);
  });

  test("refuses a sandbox that is a mount point, and --apply in it without the test flag", async () => {
    const m = machine();
    mounts(m, ["/dev/root on / type ext4 (rw)", `tmpfs on ${m.root} type tmpfs (rw)`]);
    const mounted = await runRaw(m, ["--home", m.home, "--root", m.code, "--tmp-dir", m.tmp]);
    expect(mounted.status).toBe(3);
    expect(mounted.stderr).toContain("mount point");
    mounts(m, ["/dev/root on / type ext4 (rw)"]);
    const noFlag = await runRaw(m, ["--apply", "--home", m.home, "--root", m.code, "--tmp-dir", m.tmp], {
      CMUX_HYGIENE_SANDBOX_APPLY: undefined,
    });
    expect(noFlag.status).toBe(2);
    expect(noFlag.stdout).toBe("");
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

  test("a checkout nothing works in loses its build output after a short settle", async () => {
    const m = machine();
    const done = checkout(m, "done");
    const justBuilt = checkout(m, "just-built");
    ageHours(done.dir, 3);
    ageHours(justBuilt.dir, 0.5);
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    expect(paths(report, "deleted", "project-artifacts")).toEqual([done.target]);
    expect(existsSync(path.join(done.dir, "cmux-tui", "src", "main.rs"))).toBe(true);
    expect(existsSync(path.join(done.dir, ".git"))).toBe(true);
    expect(existsSync(justBuilt.target)).toBe(true);
  });

  test("a live checkout keeps its build output but loses rustc incremental caches while nothing builds", async () => {
    const m = machine();
    const live = checkout(m, "live");
    const building = checkout(m, "building");
    ageHours(live.dir, 3);
    ageHours(building.dir, 3);
    const stops = [await processIn(m, live.dir), await processIn(m, building.dir), await processIn(m, building.dir, "cargo")];
    try {
      const report = await run(m, ["--apply", "--only", "project-artifacts", "--only", "build-incremental"]);
      expect(paths(report, "deleted", "project-artifacts")).toEqual([]);
      expect(paths(report, "deleted", "build-incremental")).toEqual([live.incremental]);
      expect(report.items).toContainEqual(
        expect.objectContaining({ path: building.incremental, action: "skipped", reason: "building" }),
      );
      expect(existsSync(path.join(live.target, "debug", "deps", "libx.rlib"))).toBe(true);
      expect(existsSync(building.incremental)).toBe(true);
    } finally {
      for (const stop of stops) await stop();
    }
  });

  test("finds build output in Claude Code worktrees under a repository's .claude", async () => {
    const m = machine();
    const repo = path.join(m.code, "repo");
    write(path.join(repo, ".git", "HEAD"), "ref: refs/heads/main\n");
    write(path.join(repo, ".claude", "settings.json"), "{}");
    const wt = checkout(m, "agent-1", path.join(repo, ".claude", "worktrees"));
    ageHours(repo, 3);
    const report = await run(m, ["--apply", "--only", "project-artifacts"]);
    expect(paths(report, "deleted", "project-artifacts")).toEqual([wt.target]);
    expect(existsSync(path.join(repo, ".claude", "settings.json"))).toBe(true);
  });

  test("stays small enough to ship through the provider's exec limit", () => {
    // Half the provider's 64 KiB exec limit, leaving room for the JSON-escaped form and arguments.
    expect(statSync(SCRIPT).size).toBeLessThan(32 * 1024);
  });
});
