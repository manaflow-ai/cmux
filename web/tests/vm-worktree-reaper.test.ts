import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { runChild } from "./helpers/run-child";

// cmux-worktree-reaper removes agent worktrees whose owner is gone, after
// pushing any work in them to a wip/ branch. Each test builds a throwaway
// home with a bare "remote", a main clone and worktrees, and runs the script
// with --ttl-hours 0 so only liveness signals (processes, keep markers,
// sessions) decide.

const SCRIPT = path.join(import.meta.dirname, "../services/vms/hygiene/cmux-worktree-reaper");

setDefaultTimeout(60_000);

const fixtures: string[] = [];
afterEach(() => {
  for (const root of fixtures.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Box = { root: string; home: string; projects: string; main: string; remote: string };

async function git(cwd: string, args: string[]) {
  const result = await runChild("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
  return result.stdout.trim();
}

async function box(): Promise<Box> {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-reaper-"));
  fixtures.push(root);
  const home = path.join(root, "home");
  const projects = path.join(home, "Projects");
  const remote = path.join(root, "remote.git");
  const main = path.join(projects, "repo");
  mkdirSync(projects, { recursive: true });
  await git(root, ["init", "-q", "--bare", "-b", "main", remote]);
  await git(projects, ["clone", "-q", remote, main]);
  writeFileSync(path.join(main, "README.md"), "hi\n");
  await git(main, ["add", "README.md"]);
  await git(main, ["commit", "-q", "-m", "init"]);
  await git(main, ["push", "-q", "origin", "main"]);
  return { root, home, projects, main, remote };
}

async function worktree(b: Box, name: string, pushed = true) {
  const dir = path.join(b.projects, "repo-worktrees", name);
  await git(b.main, ["worktree", "add", "-q", "-b", name, dir]);
  if (pushed) await git(dir, ["push", "-q", "origin", name]);
  return dir;
}

// A stand-in for gitleaks: exits 1 (a finding) when the scanned range adds
// a file named leak.txt. The reaper refuses every backup without gitleaks.
function fakeGitleaks(b: Box) {
  const bin = path.join(b.root, "bin");
  mkdirSync(bin, { recursive: true });
  const file = path.join(bin, "gitleaks");
  writeFileSync(
    file,
    '#!/bin/sh\nfor a; do repo="$a"; case "$a" in --log-opts=*) range="${a#--log-opts=}";; esac; done\n' +
      'git -C "$repo" log --format= --name-only $range | grep -qx leak.txt && exit 1\nexit 0\n',
    { mode: 0o755 },
  );
  return bin;
}

async function reap(b: Box, args: string[] = [], extraPath = "") {
  const basePath = process.env.PATH ?? "/usr/bin:/bin";
  const result = await runChild("bash", [SCRIPT, "--root", b.projects, "--ttl-hours", "0", ...args], {
    env: { PATH: extraPath ? `${extraPath}:${basePath}` : basePath, HOME: b.home, XDG_STATE_HOME: path.join(b.home, ".state") },
  });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return result.stdout;
}

const line = (out: string, dir: string) => out.split("\n").find((l) => l.includes(` ${dir}`)) ?? "";

describe("cmux-worktree-reaper", () => {
  test("reports by default and removes nothing", async () => {
    const b = await box();
    const done = await worktree(b, "done");
    const out = await reap(b);
    expect(line(out, done)).toMatch(/^reap\s+clean/);
    expect(existsSync(done)).toBe(true);
  });

  test("removes an orphaned clean worktree and keeps its branch", async () => {
    const b = await box();
    const done = await worktree(b, "done");
    const out = await reap(b, ["--apply"]);
    expect(line(out, done)).toMatch(/^reaped\s+clean/);
    expect(existsSync(done)).toBe(false);
    expect(await git(b.main, ["branch", "--list", "done"])).toContain("done");
  });

  test("holds a worktree with work and lists what a backup would carry", async () => {
    const b = await box();
    const work = await worktree(b, "work");
    writeFileSync(path.join(work, "new.txt"), "untracked\n");
    writeFileSync(path.join(work, ".gitignore"), "ignored.log\n");
    writeFileSync(path.join(work, "ignored.log"), "x\n");
    const out = await reap(b, ["--apply", "--show-files"]);
    expect(line(out, work)).toMatch(/^hold\s+changes/);
    expect(out).toContain("?? new.txt");
    expect(out).not.toContain("ignored.log");
    expect(existsSync(path.join(work, "new.txt"))).toBe(true);
  });

  test("with --backup, pushes uncommitted, untracked and unpushed work to a wip branch before removing", async () => {
    const b = await box();
    const work = await worktree(b, "work", false);
    writeFileSync(path.join(work, "committed.txt"), "c\n");
    await git(work, ["add", "committed.txt"]);
    await git(work, ["commit", "-q", "-m", "local only"]);
    writeFileSync(path.join(work, "README.md"), "edited\n");
    writeFileSync(path.join(work, "new.txt"), "untracked\n");
    writeFileSync(path.join(work, ".gitignore"), "ignored.log\n");
    writeFileSync(path.join(work, "ignored.log"), "x\n");
    const out = await reap(b, ["--apply", "--backup"], fakeGitleaks(b));
    expect(line(out, work)).toMatch(/^reaped\s+changes\+unpushed/);
    expect(existsSync(work)).toBe(false);
    const refs = await git(b.remote, ["for-each-ref", "--format=%(refname)", "refs/heads/wip/"]);
    expect(refs).toMatch(/refs\/heads\/wip\/unknown-work\/work$/);
    const files = await git(b.remote, ["ls-tree", "-r", "--name-only", refs]);
    expect(files.split("\n").sort()).toEqual([".gitignore", "README.md", "committed.txt", "new.txt"]);
    expect(await git(b.remote, ["show", `${refs}:README.md`])).toBe("edited");
    const log = readFileSync(path.join(b.home, ".state", "cmux-worktree-reaper", "log.jsonl"), "utf8");
    expect(log).toContain('"action":"backed-up"');
    expect(log).toContain('"action":"removed"');
  });

  test.each<[string, string, string, RegExp]>([
    ["an env file", ".env", "TOKEN=x\n", /name:\.env/],
    ["a token in a file", "notes.txt", `gh token ghp_${"a".repeat(36)}\n`, /content:notes\.txt/],
    ["a gitleaks finding", "leak.txt", "x\n", /gitleaks/],
  ])("refuses a backup holding %s and keeps the worktree", async (_name, file, body, why) => {
    const b = await box();
    const work = await worktree(b, "work");
    writeFileSync(path.join(work, file), body);
    const out = await reap(b, ["--apply", "--backup"], fakeGitleaks(b));
    expect(line(out, work)).toMatch(/^hold\s+secret/);
    expect(line(out, work)).toMatch(why);
    expect(existsSync(path.join(work, file))).toBe(true);
    expect(await git(b.remote, ["for-each-ref", "refs/heads/wip/"])).toBe("");
  });

  test("scans unpushed commits too: refuses a backup when a token sits in a local-only commit", async () => {
    const b = await box();
    const work = await worktree(b, "work", false);
    writeFileSync(path.join(work, "notes.txt"), `gh token ghp_${"a".repeat(36)}\n`);
    await git(work, ["add", "notes.txt"]);
    await git(work, ["commit", "-q", "-m", "local only"]);
    const out = await reap(b, ["--apply", "--backup"], fakeGitleaks(b));
    expect(line(out, work)).toMatch(/^hold\s+secret.*content:notes\.txt/);
    expect(existsSync(path.join(work, "notes.txt"))).toBe(true);
    expect(await git(b.remote, ["for-each-ref", "refs/heads/wip/"])).toBe("");
  });

  test("keeps a worktree holding a nested repository or gitignored work", async () => {
    const b = await box();
    const nested = await worktree(b, "nested");
    writeFileSync(path.join(nested, ".gitignore"), "vendor/\n");
    await git(nested, ["init", "-q", path.join(nested, "vendor", "lib")]);
    const ignored = await worktree(b, "ignored");
    writeFileSync(path.join(ignored, ".gitignore"), ".env.local\nbuild/\n");
    writeFileSync(path.join(ignored, ".env.local"), "X=1\n");
    mkdirSync(path.join(ignored, "build"));
    writeFileSync(path.join(ignored, "build", "out.js"), "1\n");
    const out = await reap(b, ["--apply"]);
    expect(line(out, nested)).toMatch(/^skip\s+nested-repo:vendor\/lib/);
    expect(line(out, ignored)).toMatch(/^skip\s+ignored-file:\.env\.local/);
    expect(existsSync(path.join(nested, "vendor", "lib", ".git"))).toBe(true);
    expect(existsSync(path.join(ignored, ".env.local"))).toBe(true);
  });

  test("refuses every backup when gitleaks is not installed", async () => {
    const b = await box();
    const work = await worktree(b, "work");
    writeFileSync(path.join(work, "new.txt"), "untracked\n");
    const out = await reap(b, ["--apply", "--backup"]);
    expect(line(out, work)).toMatch(/no-gitleaks/);
    expect(existsSync(path.join(work, "new.txt"))).toBe(true);
  });

  test("keeps a worktree when the backup cannot be pushed", async () => {
    const b = await box();
    const work = await worktree(b, "work", false);
    writeFileSync(path.join(work, "new.txt"), "untracked\n");
    await git(work, ["remote", "set-url", "origin", path.join(b.root, "missing.git")]);
    const out = await reap(b, ["--apply", "--backup"], fakeGitleaks(b));
    expect(line(out, work)).toMatch(/^FAIL\s+backup/);
    expect(readFileSync(path.join(work, "new.txt"), "utf8")).toBe("untracked\n");
  });

  test("never reclaims a kept worktree or one a process works in", async () => {
    const b = await box();
    const kept = await worktree(b, "kept");
    const busy = await worktree(b, "busy");
    const keep = await runChild("bash", [SCRIPT, "keep", kept, "demo fixture"], { env: { PATH: process.env.PATH ?? "" } });
    expect(keep.status).toBe(0);
    const child = spawn("sleep", ["60"], { cwd: busy, stdio: "ignore" });
    await new Promise((resolve) => child.once("spawn", resolve));
    try {
      const out = await reap(b, ["--apply"]);
      expect(line(out, kept)).toMatch(/^keep\s+demo fixture/);
      expect(line(out, busy)).toMatch(/^live\s+process-inside/);
      expect(existsSync(kept) && existsSync(busy)).toBe(true);
    } finally {
      const exited = new Promise((resolve) => child.once("exit", resolve));
      child.kill();
      await exited;
    }
  });

  test("never removes a worktree that holds another worktree", async () => {
    const b = await box();
    const outer = await worktree(b, "outer");
    const inner = path.join(outer, "nested");
    await git(b.main, ["worktree", "add", "-q", "-b", "inner", inner]);
    await git(inner, ["push", "-q", "origin", "inner"]);
    writeFileSync(path.join(outer, ".gitignore"), "nested/\n");
    const out = await reap(b, ["--apply"]);
    expect(line(out, outer)).toMatch(/holds-another-worktree/);
    expect(existsSync(path.join(outer, "README.md"))).toBe(true);
  });
});
