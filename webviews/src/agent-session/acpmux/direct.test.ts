import { expect, test } from "bun:test";
import { mergeToolItem } from "./direct";
import { isDraftCall } from "./conversation/toolGroups";

test("an empty rawInput update keeps a draft tool call's command", () => {
  const draft = mergeToolItem(
    undefined,
    { title: "Bash", kind: "execute", status: "in_progress", rawInput: { command: "echo hello" } },
    "call-1",
    "",
    1,
  );
  const updated = mergeToolItem(draft, { status: "in_progress", rawInput: {} }, "call-1", "", 2);

  expect(updated.tool?.inputSummary).toBe(JSON.stringify({ command: "echo hello" }));
  expect(updated.tool?.command).toBe("echo hello");
  expect(isDraftCall(updated.tool!)).toBe(false);
});

test("pi's bash output, streamed as _meta.terminal_output, adds up, and its exit code is read", () => {
  // pi-acp 0.0.34: a terminal call with the command as its title, then output deltas.
  const call = mergeToolItem(
    undefined,
    {
      title: "cargo test",
      kind: "execute",
      status: "pending",
      rawInput: { command: "cargo test", cwd: "/w" },
      content: [{ type: "terminal", terminalId: "t1" }],
      _meta: { terminal_info: { terminal_id: "t1", cwd: "/w" } },
    },
    "t1",
    "",
    1,
  );
  const meta = (data: string, exit?: number) => ({
    terminal_output: { terminal_id: "t1", data },
    ...(exit === undefined ? {} : { terminal_exit: { terminal_id: "t1", exit_code: exit, signal: null } }),
  });
  const running = mergeToolItem(call, { status: "in_progress", _meta: meta("running 2 tests\n") }, "t1", "", 2);
  expect(running.tool?.output).toBe("running 2 tests\n");
  const ended = mergeToolItem(running, { status: "failed", _meta: meta("test result: FAILED\n", 101) }, "t1", "", 3);
  expect(ended.tool?.output).toBe("running 2 tests\ntest result: FAILED\n");
  expect(ended.tool?.exitCode).toBe(101);
  expect(ended.tool?.command).toBe("cargo test");
  // An update with no new output keeps what it printed.
  expect(mergeToolItem(ended, { status: "failed" }, "t1", "", 4).tool?.output).toBe(ended.tool?.output);
});

test("a shell call's exit code: rawOutput.exit_code first, then OpenCode's metadata.exit", () => {
  const start = mergeToolItem(undefined, { title: "ls x", kind: "execute", status: "in_progress" }, "c1", "", 1);
  const opencode = mergeToolItem(
    start,
    { status: "completed", rawOutput: { output: "ls: x: No such file", metadata: { exit: 2, truncated: false } } },
    "c1",
    "ls: x: No such file",
    2,
  );
  expect(opencode.tool?.exitCode).toBe(2);
  const both = mergeToolItem(
    start,
    { status: "completed", rawOutput: { exit_code: 0, metadata: { exit: 9 } } },
    "c1",
    "",
    2,
  );
  expect(both.tool?.exitCode).toBe(0);
});
