import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyCommand } from "./applyCommand";
import type { ChangeSet } from "./model";

const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

/// A repository holding `files`, outside any user or system git config.
function repository(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "cmux-apply-"));
  roots.push(root);
  for (const [path, text] of Object.entries(files)) writeFileSync(join(root, path), text);
  const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", HOME: root };
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
    expect(command?.startsWith("git apply <<'CMUX_PATCH'\n")).toBe(true);
    const root = repository(base);
    execFileSync("sh", ["-c", command!], { cwd: root, stdio: "pipe" });
    expect(readFileSync(join(root, "a.ts"), "utf8")).toBe("one\nTWO\nthree\n");
    expect(readFileSync(join(root, "new.ts"), "utf8")).toBe("hello\n");
    expect(existsSync(join(root, "gone.ts"))).toBe(false);
    expect([existsSync(join(root, "old.ts")), readFileSync(join(root, "moved.ts"), "utf8")]).toEqual([false, "same\n"]);
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
    // A line equal to the here-document's marker would end it early.
    expect(applyCommand(with_({ patch: "@@ -0,0 +1 @@\nCMUX_PATCH\n" }))).toBeUndefined();
  });
});
