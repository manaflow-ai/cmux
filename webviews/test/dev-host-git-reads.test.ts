// The dev slot's repository reads (dev-server/agentGitHost.ts), through the real
// POST /__dev-host/read middleware of the agent pane's dev plugin, against a temp repository:
// - git.status names the branch, HEAD, upstream, base and the ahead/behind counts;
// - git.diff answers every scope in the session host's shape, with patches from the first `@@`,
//   renames, untracked files, `paths` and `context_lines`;
// - file.search ranks as the mock daemon does, relative to the folder searched;
// - a folder outside the slot's folder, a slot-less server and a write are refused;
// - the read list admits no mutating git command, not even by an abbreviated option;
// - a repository's own config never runs a program (fsmonitor, filter drivers, a driver named
//   with "=", a lazy fetch from a promisor remote, a submodule's diff driver), and the dev's
//   GIT_* environment never redirects a read;
// - the repository's orderfile and global attributes file are never read, and its hooks never run.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { isReadOnlyGit } from "../dev-server/agentGitHost";
import { cmuxDevServer } from "../dev-server/plugins";

type Handler = (request: IncomingMessage, response: ServerResponse, next: (error?: unknown) => void) => void;

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-dev-host-git-")));
const remote = path.join(root, "remote.git");
const repo = path.join(root, "repo");
const outside = path.join(root, "outside");
const state = path.join(root, "state");
const savedEnv = { ...process.env };
let server: http.Server;
let port = 0;

const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
const write = (file: string, text: string) => {
  fs.mkdirSync(path.dirname(path.join(repo, file)), { recursive: true });
  fs.writeFileSync(path.join(repo, file), text);
};

async function read(method: string, params: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
  const response = await fetch(`http://127.0.0.1:${port}/__dev-host/read`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify({ method, params: { cwd: repo, ...params } }),
  });
  return { status: response.status, body: response.status === 200 ? ((await response.json()) as any) : undefined };
}

beforeAll(async () => {
  Object.assign(process.env, {
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_AUTHOR_NAME: "Dev",
    GIT_AUTHOR_EMAIL: "dev@example.com",
    GIT_COMMITTER_NAME: "Dev",
    GIT_COMMITTER_EMAIL: "dev@example.com",
    CMUX_WEBVIEWS_DEV_STATE_DIR: state,
  });
  for (const folder of [repo, outside, state]) fs.mkdirSync(folder, { recursive: true });
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", remote]);
  git("init", "-q", "-b", "main");
  git("remote", "add", "origin", remote);
  write("src/app.ts", "export const a = 1;\nexport const b = 2;\n");
  write("src/old-name.ts", "one\ntwo\nthree\nfour\nfive\n");
  write("docs/readme.md", "# Readme\n");
  git("add", ".");
  git("commit", "-q", "-m", "base");
  git("push", "-q", "-u", "origin", "main");
  git("remote", "set-head", "origin", "main");
  git("switch", "-q", "-c", "feature");
  git("branch", "-q", "--set-upstream-to=origin/main");
  write("src/app.ts", "export const a = 1;\nexport const b = 3;\n");
  git("mv", "src/old-name.ts", "src/new-name.ts");
  git("commit", "-q", "-am", "feature");
  // Staged: a new file. Unstaged: an edit. Untracked: a two-line file and a binary one.
  write("src/staged.ts", "staged\n");
  git("add", "src/staged.ts");
  write("docs/readme.md", "# Readme\n\nMore.\n");
  write("notes.txt", "first\nsecond");
  fs.writeFileSync(path.join(repo, "blob.bin"), Buffer.from([1, 0, 2, 0]));
  fs.writeFileSync(path.join(state, "cwd"), `${repo}\n`);

  const plugin = cmuxDevServer().find((entry) => entry.name === "cmux-dev-agent-pane")!;
  const handlers: Handler[] = [];
  const fake = { middlewares: { use: (handler: Handler) => handlers.push(handler) }, config: { server: { port: 0 } } };
  (plugin.configureServer as (server: unknown) => void)(fake);
  // A plain node server, not Vite: only the plugin's middlewares run.
  server = new http.Server((request, response) => {
    const run = (index: number) => {
      if (index >= handlers.length) {
        response.statusCode = 404;
        return response.end();
      }
      handlers[index]!(request, response, () => run(index + 1));
    };
    run(0);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = (server.address() as AddressInfo).port;
  fake.config.server.port = port;
});

afterAll(() => {
  server?.close();
  process.env = savedEnv;
  fs.rmSync(root, { recursive: true, force: true });
});

describe("git.status", () => {
  test("names the branch, HEAD, upstream, base and counts", async () => {
    const { body } = await read("git.status");
    expect(body.ok).toBe(true);
    expect(body.value).toEqual({
      root: repo,
      detached: false,
      branch: "feature",
      head: git("rev-parse", "HEAD"),
      upstream: "origin/main",
      base: "origin/main",
      ahead: 1,
      behind: 0,
    });
  });
});

describe("git.diff", () => {
  test("uncommitted: tracked edits and untracked files, with patches from the first @@", async () => {
    const { body } = await read("git.diff", { scope: "uncommitted", include_patch: true });
    const value = body.value;
    expect(value.scope).toBe("uncommitted");
    expect(value.root).toBe(repo);
    expect(value.head).toBe(git("rev-parse", "HEAD"));
    expect(value.files.map((file: any) => [file.path, file.status, file.additions, file.deletions])).toEqual([
      ["blob.bin", "untracked", 0, 0],
      ["docs/readme.md", "modified", 2, 0],
      ["notes.txt", "untracked", 2, 0],
      ["src/staged.ts", "added", 1, 0],
    ]);
    expect(value.files[0].binary).toBe(true);
    const readme = value.files[1];
    expect(readme.patch).toBe("@@ -1 +1,3 @@\n # Readme\n+\n+More.\n");
    expect(value.files[2].patch).toBeUndefined();
    expect([value.additions, value.deletions, value.total_files, value.files_omitted]).toEqual([5, 0, 4, 0]);
  });

  test("staged and unstaged split the index", async () => {
    const staged = (await read("git.diff", { scope: "staged" })).body.value;
    expect(staged.files.map((file: any) => file.path)).toEqual(["src/staged.ts"]);
    expect(staged.files[0].patch).toBeUndefined();
    const unstaged = (await read("git.diff", { scope: "unstaged" })).body.value;
    expect(unstaged.files.map((file: any) => file.path)).toEqual(["blob.bin", "docs/readme.md", "notes.txt"]);
  });

  test("committed: HEAD against its parent, with the rename and the parent as base", async () => {
    const value = (await read("git.diff", { scope: "committed", include_patch: true })).body.value;
    expect(value.base).toBe(git("rev-parse", "HEAD^1"));
    expect(value.files).toEqual([
      {
        path: "src/app.ts",
        status: "modified",
        additions: 1,
        deletions: 1,
        patch: "@@ -1,2 +1,2 @@\n export const a = 1;\n-export const b = 2;\n+export const b = 3;\n",
      },
      { path: "src/new-name.ts", previous_path: "src/old-name.ts", status: "renamed", additions: 0, deletions: 0 },
    ]);
  });

  test("branch: from the merge base with origin's default branch", async () => {
    const value = (await read("git.diff", { scope: "branch" })).body.value;
    expect(value.base).toBe(git("merge-base", "HEAD", "origin/main"));
    expect(value.files.map((file: any) => file.path)).toEqual([
      "blob.bin",
      "docs/readme.md",
      "notes.txt",
      "src/app.ts",
      "src/new-name.ts",
      "src/staged.ts",
    ]);
  });

  test("paths and context_lines narrow a read", async () => {
    const value = (
      await read("git.diff", { scope: "committed", include_patch: true, paths: ["src/app.ts"], context_lines: 0 })
    ).body.value;
    expect(value.files.map((file: any) => file.path)).toEqual(["src/app.ts"]);
    expect(value.files[0].patch).toBe("@@ -2 +2 @@ export const a = 1;\n-export const b = 2;\n+export const b = 3;\n");
  });

  test("an unknown scope and a path leaving the repository are invalid", async () => {
    expect((await read("git.diff", { scope: "everything" })).body.error.code).toBe("validation.invalid");
    expect((await read("git.diff", { scope: "uncommitted", paths: ["../x"] })).body.error.code).toBe(
      "validation.invalid",
    );
  });

  test("git.checkpoint.diff lists no files and echoes the pair", async () => {
    const value = (await read("git.checkpoint.diff", { from: "c1", to: "c2" })).body.value;
    expect(value).toMatchObject({ root: repo, from: "c1", to: "c2", files: [], total_files: 0 });
  });
});

describe("file.search", () => {
  test("ranks a name match first, relative to the folder searched", async () => {
    const value = (await read("file.search", { query: "app", limit: 5 })).body.value;
    expect(value.root).toBe(repo);
    expect(value.search_root).toBe(repo);
    expect(value.results[0]).toEqual({ path: "src/app.ts", matches: [4, 5, 6] });
    const inSrc = (await read("file.search", { cwd: path.join(repo, "src"), query: "name" })).body.value;
    expect(inSrc.search_root).toBe(path.join(repo, "src"));
    expect(inSrc.results.map((result: any) => result.path)).toEqual(["new-name.ts"]);
  });

  test("limit truncates and an empty query lists nothing", async () => {
    const value = (await read("file.search", { query: "s", limit: 1 })).body.value;
    expect(value.results).toHaveLength(1);
    expect(value.truncated).toBe(true);
    expect((await read("file.search", { query: "  " })).body.value.results).toEqual([]);
  });
});

describe("confinement", () => {
  test("a folder outside the slot's folder is refused", async () => {
    fs.symlinkSync(outside, path.join(repo, "escape"));
    for (const cwd of [outside, root, path.join(repo, "escape"), `${repo}/../outside`]) {
      const { body } = await read("git.status", { cwd });
      expect(body.ok).toBe(false);
      expect(body.error.code).toBe("native.unsupported");
    }
    fs.unlinkSync(path.join(repo, "escape"));
  });

  test("without a recorded slot folder every read is refused", async () => {
    fs.renameSync(path.join(state, "cwd"), path.join(state, "cwd.off"));
    try {
      expect((await read("git.diff", { scope: "uncommitted" })).body.error.code).toBe("native.unsupported");
    } finally {
      fs.renameSync(path.join(state, "cwd.off"), path.join(state, "cwd"));
    }
  });

  test("only the four reads are served; writes are not", async () => {
    for (const method of ["git.commit", "git.push", "git.stage", "git.stageHunk"]) {
      expect((await read(method, { message: "x", paths: ["notes.txt"] })).body.error.code).toBe("native.unsupported");
    }
    expect(git("status", "--porcelain")).toContain("?? notes.txt");
  });

  test("another origin or Host is refused before any read", async () => {
    expect((await read("git.status", {}, { Origin: "http://evil.example" })).status).toBe(403);
    expect((await read("git.status", {}, { Host: "evil.example" })).status).toBe(403);
  });

  test("the git read list admits no write", () => {
    expect(isReadOnlyGit(["diff", "--no-ext-diff", "--", "a"])).toBe(true);
    expect(isReadOnlyGit(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])).toBe(true);
    expect(isReadOnlyGit(["config", "--get", "branch.x.cmuxBase"])).toBe(true);
    for (const args of [
      ["commit", "-m", "x"],
      ["push"],
      ["add", "."],
      ["checkout", "."],
      ["reset", "--hard"],
      ["stash"],
      ["diff", "--output=/tmp/x"],
      ["diff", "--ext-diff"],
      ["symbolic-ref", "HEAD", "refs/heads/other"],
      ["symbolic-ref", "-d", "HEAD"],
      ["config", "user.name", "x"],
      ["config", "--get", "a", "b"],
      ["diff", "--out=/tmp/x"],
      ["diff", "--ext-dif"],
      ["diff", "--textc"],
      [],
    ])
      expect(isReadOnlyGit(args)).toBe(false);
  });
});

describe("untrusted repository", () => {
  test("a folder that only shares the slot folder's prefix is refused", async () => {
    const sibling = `${repo}-sibling`;
    fs.mkdirSync(sibling, { recursive: true });
    const { body } = await read("git.status", { cwd: sibling });
    expect(body.ok).toBe(false);
    expect(body.error.code).toBe("native.unsupported");
  });

  test("a path that reads as an option is invalid", async () => {
    expect((await read("git.diff", { scope: "uncommitted", paths: ["--output=/tmp/x"] })).body.error.code).toBe(
      "validation.invalid",
    );
  });

  test("the repository's fsmonitor and filter drivers never run", async () => {
    const fsmonitorMarker = path.join(root, "fsmonitor-ran");
    const filterMarker = path.join(root, "filter-ran");
    git("config", "core.fsmonitor", `touch ${fsmonitorMarker}; false`);
    git("config", "filter.evil.clean", `touch ${filterMarker}; cat`);
    git("config", "filter.evil.required", "true");
    fs.writeFileSync(path.join(repo, ".git", "info", "attributes"), "*.md filter=evil\n");
    // Stat-dirty: git must read the file again, through its clean filter.
    write("docs/readme.md", "# Readme\n\nMore, changed.\n");
    try {
      expect((await read("git.status")).body.ok).toBe(true);
      expect((await read("git.diff", { scope: "uncommitted", include_patch: true })).body.ok).toBe(true);
      expect((await read("git.diff", { scope: "unstaged" })).body.ok).toBe(true);
      expect(fs.existsSync(fsmonitorMarker)).toBe(false);
      expect(fs.existsSync(filterMarker)).toBe(false);
    } finally {
      git("config", "--unset", "core.fsmonitor");
      git("config", "--remove-section", "filter.evil");
      fs.rmSync(path.join(repo, ".git", "info", "attributes"));
      write("docs/readme.md", "# Readme\n\nMore.\n");
    }
  });

  test("the repository's orderfile and global attributes file are never read", async () => {
    // A path git cannot read stands in for /dev/zero, which git would read until memory ran out.
    git("config", "diff.orderFile", path.join(root, "no-such-orderfile"));
    git("config", "core.attributesFile", path.join(root, "binary-attributes"));
    fs.writeFileSync(path.join(root, "binary-attributes"), "*.md -diff\n");
    write("docs/readme.md", "# Readme\n\nMore, changed.\n");
    try {
      const { body } = await read("git.diff", { scope: "unstaged", include_patch: true });
      expect(body.ok).toBe(true);
      const readme = body.value.files.find((file: { path: string }) => file.path === "docs/readme.md");
      expect(readme.binary ?? false).toBe(false);
      expect(readme.patch).toContain("+More, changed.");
    } finally {
      git("config", "--unset", "diff.orderFile");
      git("config", "--unset", "core.attributesFile");
      write("docs/readme.md", "# Readme\n\nMore.\n");
    }
  });

  test("the repository's hooks never run, even when a read refreshes the index", async () => {
    // `git diff` against the working tree rewrites a stale index despite GIT_OPTIONAL_LOCKS=0,
    // and each index write runs post-index-change from .git/hooks or core.hooksPath.
    const defaultMarker = path.join(root, "hook-ran");
    const configuredMarker = path.join(root, "configured-hook-ran");
    const hook = path.join(repo, ".git", "hooks", "post-index-change");
    const hooksDir = path.join(root, "hostile-hooks");
    fs.writeFileSync(hook, `#!/bin/sh\ntouch ${defaultMarker}\n`, { mode: 0o755 });
    fs.mkdirSync(hooksDir, { recursive: true });
    fs.writeFileSync(path.join(hooksDir, "post-index-change"), `#!/bin/sh\ntouch ${configuredMarker}\n`, {
      mode: 0o755,
    });
    const stale = new Date("2001-01-01T00:00:00Z");
    try {
      // A clean tracked file with a new mtime: git rereads it, finds it unchanged and rewrites
      // the index entry, which is the write that runs the hook.
      fs.utimesSync(path.join(repo, "src/new-name.ts"), stale, stale);
      expect((await read("git.diff", { scope: "unstaged", include_patch: true })).body.ok).toBe(true);
      git("config", "core.hooksPath", hooksDir);
      fs.utimesSync(path.join(repo, "src/new-name.ts"), stale, new Date("2002-01-01T00:00:00Z"));
      expect((await read("git.diff", { scope: "uncommitted" })).body.ok).toBe(true);
      expect(fs.existsSync(defaultMarker)).toBe(false);
      expect(fs.existsSync(configuredMarker)).toBe(false);
    } finally {
      git("config", "--unset", "core.hooksPath");
      fs.rmSync(hook, { force: true });
    }
  });

  test("a GIT_DIR in the dev's environment never redirects a read", async () => {
    const other = path.join(root, "other");
    execFileSync("git", ["init", "-q", "-b", "main", other]);
    execFileSync("git", ["-C", other, "commit", "-q", "--allow-empty", "-m", "other"]);
    process.env.GIT_DIR = path.join(other, ".git");
    try {
      const { body } = await read("git.status");
      expect(body.value.branch).toBe("feature");
    } finally {
      delete process.env.GIT_DIR;
    }
    expect(git("rev-parse", "--abbrev-ref", "HEAD")).toBe("feature");
  });
});

describe("hostile repositories inside the slot", () => {
  const gitIn = (dir: string, ...args: string[]) =>
    execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  /// A repository nested in the slot's folder (so its reads are allowed), removed afterwards.
  async function withRepo(name: string, run: (dir: string, marker: string) => Promise<void>) {
    const dir = path.join(repo, name);
    const marker = path.join(root, `${name}-ran`);
    try {
      await run(dir, marker);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  test("a filter driver whose name contains '=' never runs", () =>
    withRepo("hostile-filter-name", async (dir, marker) => {
      execFileSync("git", ["init", "-q", "-b", "main", dir]);
      fs.writeFileSync(path.join(dir, "a.txt"), "one\n");
      gitIn(dir, "add", ".");
      gitIn(dir, "commit", "-q", "-m", "a");
      gitIn(dir, "config", "filter.a=b.clean", `touch ${marker}; cat`);
      fs.writeFileSync(path.join(dir, ".git", "info", "attributes"), "*.txt filter=a=b\n");
      fs.writeFileSync(path.join(dir, "a.txt"), "one\ntwo\n");
      const { body } = await read("git.diff", { cwd: dir, scope: "uncommitted", include_patch: true });
      expect(body.ok).toBe(true);
      expect(fs.existsSync(marker)).toBe(false);
    }));

  test("a partial clone never fetches a missing blob from its promisor remote", () =>
    withRepo("hostile-promisor", async (dir, marker) => {
      const origin = path.join(root, "promisor-origin");
      execFileSync("git", ["init", "-q", "-b", "main", origin]);
      gitIn(origin, "config", "uploadpack.allowFilter", "true");
      fs.writeFileSync(path.join(origin, "a.txt"), "one\n");
      gitIn(origin, "add", ".");
      gitIn(origin, "commit", "-q", "-m", "one");
      fs.writeFileSync(path.join(origin, "a.txt"), "one\ntwo\n");
      gitIn(origin, "commit", "-q", "-am", "two");
      execFileSync("git", ["clone", "-q", "--no-checkout", "--filter=blob:none", `file://${origin}`, dir]);
      // The missing blobs would come from a command the repository names.
      gitIn(dir, "config", "remote.origin.url", `ext::sh -c touch% ${marker}`);
      gitIn(dir, "config", "protocol.ext.allow", "always");
      gitIn(dir, "config", "core.sshCommand", `touch ${marker}; false`);
      await read("git.diff", { cwd: dir, scope: "committed", include_patch: true });
      expect(fs.existsSync(marker)).toBe(false);
    }));

  test("a submodule's diff driver never runs", () =>
    withRepo("hostile-submodule", async (dir, marker) => {
      const sub = path.join(dir, "sub");
      execFileSync("git", ["init", "-q", "-b", "main", dir]);
      execFileSync("git", ["init", "-q", "-b", "main", sub]);
      fs.writeFileSync(path.join(sub, "a.txt"), "one\n");
      gitIn(sub, "add", ".");
      gitIn(sub, "commit", "-q", "-m", "one");
      gitIn(dir, "add", "sub");
      gitIn(dir, "commit", "-q", "-m", "sub");
      fs.writeFileSync(path.join(sub, "a.txt"), "one\ntwo\n");
      gitIn(sub, "commit", "-q", "-am", "two");
      fs.writeFileSync(path.join(sub, ".git", "info", "attributes"), "* diff=evil\n");
      gitIn(sub, "config", "diff.evil.command", `touch ${marker}; true`);
      gitIn(dir, "config", "diff.submodule", "diff");
      const { body } = await read("git.diff", { cwd: dir, scope: "uncommitted", include_patch: true });
      expect(body.ok).toBe(true);
      expect(fs.existsSync(marker)).toBe(false);
    }));
});
