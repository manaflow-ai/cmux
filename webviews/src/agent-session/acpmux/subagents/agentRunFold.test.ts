// l10n-allow-file: recorded shell commands and replies, not shipped UI.
// Bash command text never establishes a session. Explicit acpmux child records may associate a
// parent call with the child; the protocol supplies its identity and reply.
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

test("agent command text and stdout never create a session card", () => {
  for (const harness of ["claude", "codex", ""]) {
    const { fold, send } = folder(harness);
    expect(send(call("c1", REVIEW, { run_in_background: true }))).toBe(false);
    expect(
      send({
        sessionUpdate: "tool_call_update",
        toolCallId: "c1",
        status: "completed",
        content: text(
          "OpenAI Codex\nmodel: gpt-6-astra\nCommand running in background with ID: b1. Output is being written to: /tmp/tasks/b1.output.",
        ),
      }),
    ).toBe(false);
    expect(send({ sessionUpdate: "background_task_update", toolCallId: "c1", state: "completed" })).toBe(false);
    expect(fold.isRun("c1")).toBe(false);
    expect(fold.all()).toEqual([]);
    expect(fold.takeRows()).toEqual([]);
    expect(fold.deferredRun).toBe(false);
  }
});

// `acpmux run --parent` (acpmux #25019): the chat's log records its child's start and each turn's end.
const PARENT_RUN = `acpmux run --parent chat-1 -n fix "Fix the flaky test"`;
const child = (fold: SubagentFold, at: number, record: Record<string, unknown>) =>
  fold.reduceChild({ seq: 100 + at, at: at * 1000, msg: record }, { childSessionId: "child-1", ...record });

test("an acpmux run --parent call is the child acpmux records, with its harness, model and reply", () => {
  const { fold, send } = folder();
  // The command names no harness: it draws as the call until acpmux says what started.
  expect(send(call("c1", PARENT_RUN))).toBe(false);
  expect(fold.takeRows()).toEqual([]);
  const started = {
    event: "started",
    shortName: "fix",
    harness: "codex",
    model: "gpt-6-astra",
    effort: "xhigh",
  };
  expect(child(fold, 2, { ...started, prompt: "Fix the flaky test", state: "running" })).toBe("c1");
  expect(fold.isRun("c1")).toBe(true);
  const [row] = fold.takeRows();
  expect(row!.subagents![0]).toMatchObject({
    id: "run:c1",
    name: "Fix the flaky test",
    kind: "Codex · gpt-6-astra xhigh",
    harness: "codex",
    child: "child-1",
    session: "fix",
    state: "running",
    startedAt: 1000,
  });
  const reply = "Fixed: the test waits for the socket.";
  expect(child(fold, 3, { event: "turn_ended", state: "done", result: { state: "done", reply } })).toBeUndefined();
  expect(fold.all()[0]).toMatchObject({ state: "completed", result: reply, endedAt: 3000 });
  // What the shell printed after is not its reply: acpmux's record is.
  const end = { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed", content: text("Fixed…") };
  expect(send(end)).toBe(true);
  expect(fold.all()[0]!.result).toBe(reply);
  // A later turn that failed says so.
  child(fold, 5, { event: "turn_ended", state: "failed", result: { state: "failed", error: "model at capacity" } });
  expect(fold.all()[0]).toMatchObject({ state: "failed", result: "model at capacity" });
  // A turn that said nothing has no reply.
  child(fold, 6, { event: "turn_ended", state: "cancelled", result: { state: "cancelled" } });
  expect(fold.all()[0]!.state).toBe("cancelled");
  expect(fold.all()[0]!.result).toBeUndefined();
});

test("a child of the chat's own family, or one no call of the chat started, is not a run", () => {
  const { fold, send } = folder();
  expect(send(call("c1", PARENT_RUN))).toBe(false);
  expect(child(fold, 2, { event: "started", shortName: "fix", harness: "claude-sr2" })).toBeUndefined();
  expect(send({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed" })).toBe(false);
  // The start_session tool's child has its own card.
  expect(child(fold, 3, { event: "started", harness: "codex", state: "running" })).toBeUndefined();
  expect(child(fold, 4, { event: "turn_ended", state: "done", result: { reply: "Done." } })).toBeUndefined();
  expect(fold.all()).toEqual([]);
  // The start_session tool's child, while a call waits for its own, is not that call's.
  expect(send(call("c2", `acpmux run --parent chat-1 "Review the tray"`))).toBe(false);
  const started = { event: "started", harness: "codex", state: "running" };
  expect(child(fold, 6, { ...started, childSessionId: "child-3", prompt: "Fix the tests" })).toBeUndefined();
  // The call's own child, by what it was asked.
  expect(child(fold, 7, { ...started, childSessionId: "child-2", prompt: "Review the tray" })).toBe("c2");
  expect(fold.all()[0]).toMatchObject({ id: "run:c2", child: "child-2", harness: "codex" });
});

test("a child record must name its harness, regardless of CLI flags", () => {
  const { fold, send } = folder();
  send(call("c1", `${PARENT_RUN} -m codex/gpt-6-astra -e xhigh`));
  expect(child(fold, 2, { event: "started", shortName: "fix" })).toBeUndefined();
  expect(fold.isRun("c1")).toBe(false);
  expect(fold.all()).toEqual([]);
});

test("only the child record supplies harness, model, effort and host identity", () => {
  const { fold, send } = folder();
  send(call("c1", `reach review-router '${PARENT_RUN} -m claude/requested-model -e low'`));
  expect(child(fold, 2, { event: "started", shortName: "fix", harness: "codex" })).toBe("c1");
  expect(fold.all()[0]).toMatchObject({ harness: "codex", kind: "Codex", child: "child-1", session: "fix" });
  expect(fold.all()[0]!.model).toBeUndefined();
  expect(fold.all()[0]!.host).toBeUndefined();
});
