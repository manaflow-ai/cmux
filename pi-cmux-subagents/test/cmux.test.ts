import assert from "node:assert/strict";
import test from "node:test";
import {
  createChildWorkspace,
  ensureParentGroup,
  steerWorkspace,
  type CmuxExecution,
} from "../src/cmux.ts";

function fake(responses: unknown[]): { executor: CmuxExecution; calls: string[][] } {
  const calls: string[][] = [];
  return {
    calls,
    executor: {
      async exec(command, args) {
        calls.push([command, ...args]);
        return { stdout: JSON.stringify(responses.shift()), stderr: "", code: 0 };
      },
    },
  };
}

test("reuses the parent's existing workspace group", async () => {
  const { executor, calls } = fake([{
    caller: { workspace_ref: "workspace:2", workspace_group_ref: "workspace_group:4" },
  }]);
  const result = await ensureParentGroup(executor, "/repo");
  assert.deepEqual(result, {
    groupRef: "workspace_group:4",
    parentWorkspaceRef: "workspace:2",
  });
  assert.equal(calls.length, 1);
});

test("creates a group containing the parent when needed", async () => {
  const { executor, calls } = fake([
    { caller: { workspace_ref: "workspace:2" } },
    { group: { ref: "workspace_group:7" } },
  ]);
  const result = await ensureParentGroup(executor, "/projects/demo");
  assert.equal(result.groupRef, "workspace_group:7");
  assert.deepEqual(calls[1], [
    "cmux", "--json", "workspace-group", "create", "--name", "Pi · demo",
    "--cwd", "/projects/demo", "--from", "workspace:2",
  ]);
});

test("creates an unfocused child after the parent within the group", async () => {
  const { executor, calls } = fake([{ workspace_ref: "workspace:9" }]);
  const workspace = await createChildWorkspace(executor, {
    groupRef: "workspace_group:7",
    parentWorkspaceRef: "workspace:2",
    cwd: "/repo",
    title: "Explore · auth",
    command: "node launcher run",
  });
  assert.equal(workspace, "workspace:9");
  assert.deepEqual(calls[0].slice(-8), [
    "--group", "workspace_group:7",
    "--group-placement", "afterCurrent",
    "--group-reference", "workspace:2",
    "--focus", "false",
  ]);
});

test("steering sends literal text then enter", async () => {
  const { executor, calls } = fake([{}, {}]);
  await steerWorkspace(executor, "workspace:9", "check the failing test; don't guess");
  assert.deepEqual(calls, [
    ["cmux", "--json", "send", "--workspace", "workspace:9", "check the failing test; don't guess"],
    ["cmux", "--json", "send-key", "--workspace", "workspace:9", "enter"],
  ]);
});
