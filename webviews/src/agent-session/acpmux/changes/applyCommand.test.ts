import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyCommand } from "./applyCommand";
import type { ChangeSet } from "./model";

const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

/// git without any user or system config.
const isolated = (home: string) => ({
  ...process.env,
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  HOME: home,
  XDG_CONFIG_HOME: home,
});

/// A repository holding `files`, outside any user or system git config.
function repository(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "cmux-apply-"));
  roots.push(root);
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), text);
  }
  const env = isolated(root);
  const git = (...args: string[]) => execFileSync("git", args, { cwd: root, env, stdio: "pipe" });
  git("init", "-q");
  git("add", "-A");
  git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base");
  return root;
}

const base = { "a.ts": "one\ntwo\nthree\n", "gone.ts": "bye\n", "old.ts": "same\n" };
const changeSet: ChangeSet = {
  scope: "uncommitted",
  root: "/repo",
  files: [
    {
      path: "a.ts",
      status: "modified",
      additions: 1,
      deletions: 1,
      patch: "@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n",
    },
    { path: "new.ts", status: "added", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+hello\n" },
    { path: "gone.ts", status: "deleted", additions: 0, deletions: 1, patch: "@@ -1 +0,0 @@\n-bye\n" },
    { path: "moved.ts", previousPath: "old.ts", status: "renamed", additions: 0, deletions: 0 },
  ],
};

describe("Copy git apply command", () => {
  test("the command applies a scope's edits, a new file, a deletion and a rename to a clean checkout", () => {
    const command = applyCommand(changeSet);
    expect(command?.startsWith(`git -C "$(git rev-parse --show-toplevel)" apply <<'CMUX_PATCH'\n`)).toBe(true);
    const root = repository(base);
    execFileSync("sh", ["-c", command!], { cwd: root, env: isolated(root), stdio: "pipe" });
    expect(readFileSync(join(root, "a.ts"), "utf8")).toBe("one\nTWO\nthree\n");
    expect(readFileSync(join(root, "new.ts"), "utf8")).toBe("hello\n");
    expect(existsSync(join(root, "gone.ts"))).toBe(false);
    expect([existsSync(join(root, "old.ts")), readFileSync(join(root, "moved.ts"), "utf8")]).toEqual([false, "same\n"]);
  });

  test("pasted in a subdirectory, the command still applies every change from the top level", () => {
    const command = applyCommand({
      scope: "uncommitted",
      files: [
        { path: "top.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+A\n" },
        { path: "sub/inner.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-b\n+B\n" },
      ],
    });
    const root = repository({ "top.ts": "a\n", "sub/inner.ts": "b\n" });
    execFileSync("sh", ["-c", command!], { cwd: join(root, "sub"), env: isolated(root), stdio: "pipe" });
    expect([readFileSync(join(root, "top.ts"), "utf8"), readFileSync(join(root, "sub/inner.ts"), "utf8")]).toEqual([
      "A\n",
      "B\n",
    ]);
  });

  test("nothing to copy when the patches would not reproduce every change", () => {
    const with_ = (file: Partial<ChangeSet["files"][number]>) => ({
      ...changeSet,
      files: [
        {
          path: "x.ts",
          status: "modified" as const,
          additions: 1,
          deletions: 0,
          patch: "@@ -0,0 +1 @@\n+x\n",
          ...file,
        },
      ],
    });
    expect(applyCommand({ ...changeSet, files: [] })).toBeUndefined();
    expect(applyCommand(with_({ binary: true, patch: undefined }))).toBeUndefined();
    expect(applyCommand(with_({ status: "untracked", patch: undefined }))).toBeUndefined();
    expect(applyCommand(with_({ patchTruncated: true }))).toBeUndefined();
    expect(applyCommand({ ...with_({}), filesOmitted: 3 })).toBeUndefined();
    // git quotes a path with a control character, a quote or a backslash; the copy does not.
    expect(applyCommand(with_({ path: "tab\there.ts" }))).toBeUndefined();
    expect(applyCommand(with_({ path: 'quote".ts' }))).toBeUndefined();
    expect(applyCommand(with_({ path: "x.ts", previousPath: "back\\slash.ts", status: "renamed" }))).toBeUndefined();
    // A line equal to the here-document's marker would end it early.
    expect(applyCommand(with_({ patch: "@@ -0,0 +1 @@\nCMUX_PATCH\n" }))).toBeUndefined();
  });
});
