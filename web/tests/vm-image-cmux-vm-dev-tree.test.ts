import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { GUEST_DIR } from "../scripts/cmux-vm-image/bake";
import { CREDENTIAL_FILES_CHECK, devTreeCommand, devTreeCredentialCheckCommand, devTreeLock, devTreeUserPaths, FIRST_BUILD } from "../scripts/cmux-vm-image/dev-tree";
import { type FirstBuildReport, reportTable, summarize } from "../scripts/cmux-vm-image/first-build";
import { DEFAULT_LOCK_PATH, LockError, readInputsLock, validateInputsLock } from "../scripts/cmux-vm-image/lock";
import { secretScanCommand } from "../scripts/cmux-vm-image/smoke";
import { runChild } from "./helpers/run-child";

const lockText = readFileSync(DEFAULT_LOCK_PATH, "utf8");
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- tests mutate arbitrary nested lock fields
const fresh = () => JSON.parse(lockText) as Record<string, any>;

function problemsOf(raw: unknown): string[] {
  try {
    validateInputsLock(raw);
    return [];
  } catch (error) {
    if (error instanceof LockError) return [...error.problems];
    throw error;
  }
}

async function bashSyntax(script: string): Promise<void> {
  const result = await runChild("bash", ["-n"], { input: script, timeout: 20_000 });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
}

describe("the cmux dev tree (bake.ts --dev-tree)", () => {
  test("the checked-in lock pins a public checkout, libclang's closure and a checked rustup-init", () => {
    const tree = devTreeLock(readInputsLock());
    expect(tree.repo).toBe("https://github.com/manaflow-ai/cmux.git");
    expect(tree.dir).toBe("/home/cmux/cmux");
    expect(tree.submodules).toEqual(["ghostty-next"]);
    expect(tree.aptRoots.every((root) => root in tree.apt)).toBe(true);
    expect(tree.rustupInit.url).toContain(`/rustup/archive/${tree.rustupInit.version}/x86_64-unknown-linux-gnu/rustup-init`);
  });

  test("the lock refuses a private or non-https repo, a dir outside the work home and a closure that overlaps the image", () => {
    const raw = fresh();
    raw.devTree.repo = "git@github.com:manaflow-ai/cmux.git";
    raw.devTree.dir = "/srv/cmux";
    raw.devTree.apt.git = raw.apt.ubuntu.packages.git;
    raw.devTree.aptRoots = ["libclang-dev", "clang"];
    raw.devTree.rustupInit.sha256 = "nope";
    const problems = problemsOf(raw);
    expect(problems).toContain("devTree.repo: must be a public https://github.com/<owner>/<repo>.git URL");
    expect(problems).toContain("devTree.dir: must be a directory directly under /home/cmux");
    expect(problems).toContain("devTree.apt: git is also in apt.ubuntu.packages or a first-use closure");
    expect(problems).toContain("devTree.aptRoots: clang is not in devTree.apt");
    expect(problems).toContain("devTree.rustupInit.sha256: missing or not 64 lowercase hex");
    const without = fresh();
    delete without.devTree;
    expect(problemsOf(without)).toEqual([]);
  });

  test("guest commands parse; the secret scan skips exactly the tree's directories", async () => {
    const tree = devTreeLock(readInputsLock());
    const result = await runChild("bash", ["-n", `${GUEST_DIR}/dev-tree.sh`], { timeout: 20_000 });
    expect(result.status).toBe(0);
    await bashSyntax(devTreeCredentialCheckCommand(tree));
    // Each credential file is its own test: one present file fails the check whatever the others are.
    expect(CREDENTIAL_FILES_CHECK.match(/test ! -e /g)).toHaveLength(3);
    expect(devTreeCredentialCheckCommand(tree)).toContain(CREDENTIAL_FILES_CHECK);
    await bashSyntax(CREDENTIAL_FILES_CHECK);
    await bashSyntax(devTreeCommand(["update", tree.dir, "", ...tree.submodules]));
    await bashSyntax(devTreeCommand(["build", tree.dir, ...FIRST_BUILD]));
    const scan = secretScanCommand(devTreeUserPaths(tree));
    await bashSyntax(scan);
    expect(scan).toContain(`find /home -mindepth 1 \\( ${devTreeUserPaths(tree).map((p) => `-path '${p}'`).join(" -o ")} \\) -prune -o -type f -print0`);
    expect(secretScanCommand()).toContain("find /home -mindepth 1 -type f -print0");
    await bashSyntax(secretScanCommand());
  });

  test("the report puts before and after side by side, and says when a side was not measured", () => {
    const run = (totalMs: number, phasesMs: Record<string, number>) => ({ vmId: "vm-1", createToReadyMs: 900, rootUsedBytes: 5.5e9, phasesMs, totalMs, head: "a".repeat(40), bytes: {} });
    const runs = [run(2_400_000, { clone: 60_000, build: 2_340_000 }), run(2_520_000, { clone: 90_000, build: 2_430_000 }), run(2_460_000, { clone: 70_000, build: 2_390_000 })];
    const before: FirstBuildReport = { mode: "before", snapshotId: "sh-old", firstBuild: "cd /home/cmux/cmux/cmux-tui && cargo build -p cmux-tui", runs, failed: [], summary: summarize(runs) };
    expect(before.summary?.totalMs).toEqual({ n: 3, p50: 2_460_000, min: 2_400_000, max: 2_520_000 });
    const after: FirstBuildReport = { mode: "after", snapshotId: "sh-new", firstBuild: before.firstBuild, runs: [], failed: [], error: "boom" };
    const table = reportTable(before, after);
    expect(table).toContain("| Time to first build, p50 (min to max) | 41 min 0 s (40 min 0 s to 42 min 0 s), n=3 | not measured |");
    expect(table).toContain("| Phases, p50 | clone 1 min 10 s, build 39 min 50 s | n/a |");
    expect(table).toContain("| Notes |  | boom |");
  });
});
