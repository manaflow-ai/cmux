// l10n-allow-file: test fixture commands, not shipped UI.
// Hold to approve (holdToApprove.experiment.ts): off by default, so no approval changes unless the
// person turns it on; under "destructive" only asks that can lose work hold; the ring fills with the
// hold and, under Reduce Motion, steps instead of sweeping.
import { expect, test } from "bun:test";
import { experimentArm } from "../../../experiments/experiment";
import { holdApplies, holdProgress, isDestructiveAsk } from "./holdToApprove";
import { HOLD_DURATIONS_MS, holdToApprove, holdToApproveDuration } from "./holdToApprove.experiment";

test("the experiment is off by default and holds 600 ms when on", () => {
  expect(experimentArm(holdToApprove, { overrides: {}, stored: {} })).toBe("off");
  expect(HOLD_DURATIONS_MS[experimentArm(holdToApproveDuration, { overrides: {}, stored: {} })]).toBe(600);
  expect(experimentArm(holdToApprove, { overrides: {}, stored: { "hold-to-approve": "destructive" } })).toBe(
    "destructive",
  );
  // A stale arm falls back to off.
  expect(experimentArm(holdToApprove, { overrides: {}, stored: { "hold-to-approve": "always" } })).toBe("off");
});

test("off never holds; all always holds", () => {
  const asks = [{ kind: "execute", command: "rm -rf build" }];
  expect(holdApplies("off", asks)).toBe(false);
  expect(holdApplies("all", [{ kind: "read" }])).toBe(true);
});

const destructive = [
  "rm -rf build",
  "sudo rm /etc/hosts",
  "cd out && rm *.tmp",
  "git reset --hard HEAD~1",
  "git push --force origin main",
  "git push -f",
  "git push origin +main",
  "git clean -fdx",
  "git checkout -- src/app.ts",
  "git restore .",
  "git branch -D feature",
  "git stash drop",
  "find . -name '*.log' -delete",
  "ls | xargs rm",
  "dd if=/dev/zero of=/dev/disk2",
  "chmod -R 777 .",
  "kill -9 4242",
  "psql -c 'DROP TABLE users'",
  "echo hi > notes.txt",
  "truncate -s 0 app.log",
];
const benign = [
  "npm test",
  "git push origin feature/reel-export",
  "git status",
  "ls -la",
  "cat notes.txt",
  "npm run build 2>&1",
  "make > /dev/null",
  "echo hi >> notes.txt",
  "grep -rn rmdir docs",
  "git checkout feature",
  "npm run format",
];

for (const command of destructive)
  test(`destructive: ${command}`, () => {
    expect(isDestructiveAsk({ kind: "execute", command })).toBe(true);
    expect(holdApplies("destructive", [{ kind: "execute", command }])).toBe(true);
  });
for (const command of benign)
  test(`not destructive: ${command}`, () => {
    expect(isDestructiveAsk({ kind: "execute", command })).toBe(false);
    expect(holdApplies("destructive", [{ kind: "execute", command }])).toBe(false);
  });

test("a delete or move of files is destructive; a read or edit is not", () => {
  expect(isDestructiveAsk({ kind: "delete" })).toBe(true);
  expect(isDestructiveAsk({ kind: "move" })).toBe(true);
  expect(isDestructiveAsk({ kind: "read" })).toBe(false);
  expect(isDestructiveAsk({ kind: "edit" })).toBe(false);
  // A group holds when any of its asks is destructive.
  expect(holdApplies("destructive", [{ kind: "read" }, { kind: "delete" }])).toBe(true);
});

test("the ring fills with the hold, and steps in quarters under Reduce Motion", () => {
  expect(holdProgress(0, 600)).toBe(0);
  expect(holdProgress(300, 600)).toBe(0.5);
  expect(holdProgress(900, 600)).toBe(1);
  expect(holdProgress(-5, 600)).toBe(0);
  expect(holdProgress(140, 600, true)).toBe(0);
  expect(holdProgress(160, 600, true)).toBe(0.25);
  expect(holdProgress(440, 600, true)).toBe(0.5);
  expect(holdProgress(599, 600, true)).toBe(0.75);
  expect(holdProgress(600, 600, true)).toBe(1);
});
