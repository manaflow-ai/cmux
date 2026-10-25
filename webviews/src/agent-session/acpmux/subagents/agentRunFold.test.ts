// l10n-allow-file: recorded shell commands and replies, not shipped UI.
// A shell call that starts an agent of another family folds to that agent (subagentFold.ts
// `reduceRun`), from the update shapes Claude Code records: a Bash `tool_call` with
// `rawInput.command`, its `tool_call_update`, acpmux's `background_task_update`, and a later Read
// of a background run's output file.
import { expect, test } from "bun:test";
import { SubagentFold } from "./subagentFold";

const REVIEW = `codex exec --sandbox read-only -m gpt-6-astra -c model_reasoning_effort=xhigh "Re-review hq#4038"`;
const text = (said: string) => [{ type: "content", content: { type: "text", text: said } }];

function folder(harness = "claude") {
  const fold = new SubagentFold();
  fold.harness = harness;
  let seq = 0;
  const send = (update: Record<string, unknown>) =>
    fold.reduce({ seq: (seq += 1), at: seq * 1000, msg: { params: { update } } }, update);
  return { fold, send };
}
const call = (id: string, command: string, more: Record<string, unknown> = {}) => ({
  sessionUpdate: "tool_call",
  toolCallId: id,
  title: command,
  kind: "execute",
  status: "in_progress",
  rawInput: { command, ...more },
});

test("a codex exec call is a running Codex subagent, then done with its final message", () => {
  const { fold, send } = folder();
  expect(send(call("c1", REVIEW, { description: "Codex review" }))).toBe(true);
  const [row] = fold.takeRows();
  expect(row!.kind).toBe("subagents");
  expect(row!.subagents![0]).toMatchObject({
    id: "run:c1",
    name: "Re-review hq#4038",
    task: "Codex review",
    kind: "Codex · gpt-6-astra xhigh",
    harness: "codex",
    model: "gpt-6-astra xhigh",
    state: "running",
    command: REVIEW,
  });
  expect(fold.isRun("c1")).toBe(true);
  expect(
    send({
      sessionUpdate: "tool_call_update",
      toolCallId: "c1",
      status: "completed",
      content: text("hook: Stop\ntokens used\n6,624\nVERDICT: SHIP\n"),
    }),
  ).toBe(true);
  expect(fold.takeRows()[0]!.subagents![0]).toMatchObject({
    state: "completed",
    result: "VERDICT: SHIP",
    endedAt: 2000,
  });
  // Its own view is the call: the command and all it printed.
  expect(fold.views()["run:c1"]!.some((entry) => entry.items?.some((item) => item.tool?.id === "c1"))).toBe(true);
});

test("a failed call is a failed run", () => {
  const { fold, send } = folder();
  send(call("c1", REVIEW));
  send({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "failed", content: text("ERROR: at capacity") });
  expect(fold.all()[0]).toMatchObject({ state: "failed", result: "ERROR: at capacity" });
});

test("a background run ends with its task, and a read of its output file is its reply", () => {
  const { fold, send } = folder();
  send(call("c1", REVIEW, { run_in_background: true }));
  send({
    sessionUpdate: "tool_call_update",
    toolCallId: "c1",
    status: "completed",
    content: text(
      "Command running in background with ID: b1. Output is being written to: /tmp/tasks/b1.output. You will be notified when it completes.",
    ),
  });
  expect(fold.all()[0]).toMatchObject({ state: "running", background: true });
  // The turn ending leaves a background run running.
  expect(fold.stopRunning({ state: "completed", turn: true }, 3000)).toBe(false);
  expect(send({ sessionUpdate: "background_task_update", toolCallId: "c1", state: "completed" })).toBe(true);
  expect(fold.all()[0]!.state).toBe("completed");
  // The read draws its own row.
  expect(
    send({
      sessionUpdate: "tool_call",
      toolCallId: "r1",
      kind: "read",
      status: "completed",
      rawInput: { file_path: "/tmp/tasks/b1.output" },
      content: text("     1\tVERDICT: FIX\n     2\t- one finding"),
    }),
  ).toBe(false);
  expect(fold.all()[0]!.result).toBe("VERDICT: FIX\n- one finding");
});

test("a call that is no other family's agent stays a command", () => {
  const { fold, send } = folder("codex");
  expect(send(call("c1", REVIEW))).toBe(false);
  expect(send(call("c2", `grep -n "codex exec" notes.md`))).toBe(false);
  expect(send({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed" })).toBe(false);
  expect(fold.all()).toEqual([]);
  // A Codex chat's own `claude -p` is another family's.
  expect(send(call("c3", `claude -p "Summarize the log"`))).toBe(true);
  expect(fold.all()[0]).toMatchObject({ harness: "claude", name: "Summarize the log", kind: "Claude" });
});
