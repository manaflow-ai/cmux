// l10n-allow-file: recorded shell commands and replies, not shipped UI.
// Bash command text never establishes a session. Explicit acpmux child records may associate a
// parent call with the child; the protocol supplies its identity and reply.
import { expect, test } from "bun:test";
import { SubagentFold } from "./subagentFold";
import { subagentRetry } from "./retryState";

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
    startedBy: "chat-1",
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
    parent: null,
    startedBySession: "chat-1",
    session: "fix",
    state: "running",
    startedAt: 1000,
  });
  // A direct --parent child remains a top-level run: it can retry, and its running row is eligible
  // for the pane's automatic-open rule (`parent === null && state === "running"`).
  expect(subagentRetry(fold.all()[0]!)).toEqual({ kind: "none" });
  expect(fold.all()[0]!.parent).toBeNull();
  expect(fold.all()[0]!.state).toBe("running");
  expect(fold.all()[0]!.parent === null && fold.all()[0]!.state === "running").toBe(true);
  const reply = "Fixed: the test waits for the socket.";
  expect(child(fold, 3, { event: "turn_ended", state: "done", result: { state: "done", reply } })).toBeUndefined();
  expect(fold.all()[0]).toMatchObject({ state: "completed", result: reply, endedAt: 3000 });
  expect(fold.all()[0]!.lastMessage).toBe(reply);
  // What the shell printed after is not its reply: acpmux's record is.
  const end = { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed", content: text("Fixed…") };
  expect(send(end)).toBe(true);
  expect(fold.all()[0]!.result).toBe(reply);
  // A later turn that failed says so.
  child(fold, 5, { event: "turn_ended", state: "failed", result: { state: "failed", error: "model at capacity" } });
  expect(fold.all()[0]).toMatchObject({ state: "failed", result: "model at capacity" });
  expect(subagentRetry({ ...fold.all()[0]!, retryable: true })).toEqual({ kind: "failed", action: "daemon" });
  // A turn that said nothing has no reply.
  child(fold, 6, { event: "turn_ended", state: "cancelled", result: { state: "cancelled" } });
  expect(fold.all()[0]!.state).toBe("cancelled");
  expect(fold.all()[0]!.result).toBeUndefined();
});

test("a child turn end refreshes its model and effort", () => {
  const { fold, send } = folder();
  expect(send(call("c1", PARENT_RUN))).toBe(false);
  expect(
    child(fold, 2, {
      event: "started",
      shortName: "fix",
      startedBy: "chat-1",
      harness: "codex",
      model: "model-a",
      prompt: "Fix the flaky test",
      state: "running",
    }),
  ).toBe("c1");
  expect(fold.all()[0]!.model).toBe("model-a");
  expect(fold.all()[0]!.effort).toBeUndefined();
  child(fold, 3, {
    event: "turn_ended",
    state: "done",
    model: "model-b",
    effort: "high",
    result: { state: "done", reply: "Updated." },
  });
  expect(fold.all()[0]).toMatchObject({ model: "model-b", effort: "high" });
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

const sessionStart = (
  id: string,
  style: "claude" | "cmux" | "codex" = "claude",
  name = "fix",
  prompt = "Fix the flaky test",
) => ({
  sessionUpdate: "tool_call",
  toolCallId: id,
  title:
    style === "codex"
      ? "cmux-subsessions.start_session call"
      : style === "cmux"
        ? "mcp__cmux__subsessions_start_session"
        : "mcp__cmux-subsessions__start_session",
  status: "in_progress",
  rawInput:
    style === "codex"
      ? { server: "cmux-subsessions", tool: "start_session", arguments: { name, prompt } }
      : { name, prompt },
});

for (const style of ["claude", "cmux", "codex"] as const) {
  for (const shellFirst of [true, false]) {
    test(`overlapping same-name shell and ${style} start_session keep the shell row (${shellFirst ? "shell" : "MCP"} first)`, () => {
      const { fold, send } = folder();
      const starts = [call("shell", PARENT_RUN, { run_in_background: true }), sessionStart("mcp", style)];
      if (!shellFirst) starts.reverse();
      for (const start of starts) expect(send(start)).toBe(false);
      // The MCP call may complete before either child's first prompt is accepted (queued starts).
      send({ sessionUpdate: "tool_call_update", toolCallId: "mcp", status: "completed" });
      for (const [index, shortName] of ["fix", "fix-2"].entries()) {
        expect(
          child(fold, 10 + index, {
            childSessionId: `child-${index}`,
            event: "started",
            shortName,
            prompt: "Fix the flaky test",
            harness: "codex",
            model: `recorded-model-${index}`,
          }),
        ).toBeUndefined();
      }
      expect(fold.isRun("shell")).toBe(false);
      expect(fold.all()).toEqual([]);
    });
  }
}

test("two background parent runs with the same name stay plain in either child order", () => {
  for (const names of [
    ["fix", "fix-2"],
    ["fix-2", "fix"],
  ]) {
    const { fold, send } = folder();
    for (const id of ["shell-a", "shell-b"]) {
      expect(send(call(id, PARENT_RUN, { run_in_background: true }))).toBe(false);
      expect(
        send({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          content: text(`Command running in background with ID: ${id}. Output is being written to: /tmp/${id}.output.`),
        }),
      ).toBe(false);
    }
    for (const [index, shortName] of names.entries())
      expect(
        child(fold, 10 + index, {
          childSessionId: `child-${index}`,
          event: "started",
          shortName,
          prompt: "Fix the flaky test",
          harness: "codex",
        }),
      ).toBeUndefined();
    expect(fold.isRun("shell-a")).toBe(false);
    expect(fold.isRun("shell-b")).toBe(false);
    expect(fold.all()).toEqual([]);
  }
});

test("distinct explicit parent names remain deterministic with the same prompt", () => {
  const { fold, send } = folder();
  const alpha = `acpmux run --parent chat-1 -n alpha "Fix the flaky test"`;
  const beta = `acpmux run --parent chat-1 -n beta "Fix the flaky test"`;
  send(call("alpha", alpha));
  send(call("beta", beta));
  expect(
    child(fold, 10, {
      childSessionId: "child-alpha",
      event: "started",
      shortName: "alpha",
      prompt: "Fix the flaky test",
      harness: "codex",
    }),
  ).toBe("alpha");
  expect(
    child(fold, 11, {
      childSessionId: "child-beta",
      event: "started",
      shortName: "beta",
      prompt: "Fix the flaky test",
      harness: "codex",
    }),
  ).toBe("beta");
  expect(fold.all().map((agent) => agent.session)).toEqual(["alpha", "beta"]);
});

for (const [label, records] of [
  [
    "MCP child first",
    [
      { shortName: "alpha-2", prompt: "MCP task" },
      { shortName: "alpha-2-2", prompt: "Shell task" },
    ],
  ],
  [
    "shell child first",
    [
      { shortName: "alpha-2-2", prompt: "Shell task" },
      { shortName: "alpha-2", prompt: "MCP task" },
    ],
  ],
  [
    "different prompt without child prompt",
    [{ shortName: "alpha-2" }, { shortName: "alpha-2-2", prompt: "Shell task" }],
  ],
] as const) {
  test(`a daemon rename family cannot pair MCP alpha-2 with shell alpha-2-2 (${label})`, () => {
    const { fold, send } = folder();
    send(call("shell", `acpmux run --parent chat-1 -n alpha-2 "Shell task"`));
    send(sessionStart("mcp", "claude", "alpha", "MCP task"));
    for (const [index, record] of records.entries())
      expect(
        child(fold, 10 + index, {
          childSessionId: `rename-child-${index}`,
          event: "started",
          harness: "codex",
          ...record,
        }),
      ).toBeUndefined();
    expect(fold.isRun("shell")).toBe(false);
    expect(fold.all()).toEqual([]);
  });
}

for (const [label, mcpName, shellName, actual] of [
  ["case fold", "Alpha", "alpha", "alpha"],
  ["punctuation", "Review/router", "review-router", "review-router"],
  ["separator run", "Alpha___Beta", "alpha-beta", "alpha-beta"],
] as const) {
  test(`daemon name normalization cannot pair ${label} MCP and shell starts`, () => {
    const { fold, send } = folder();
    send(call("shell", `acpmux run --parent chat-1 -n ${shellName} "Shell task"`));
    send(sessionStart("mcp", "claude", mcpName, "MCP task"));
    expect(
      child(fold, 20, {
        childSessionId: "normalized-mcp",
        event: "started",
        shortName: actual,
        prompt: "MCP task",
        harness: "codex",
      }),
    ).toBeUndefined();
    expect(
      child(fold, 21, {
        childSessionId: "normalized-shell",
        event: "started",
        shortName: `${actual}-2`,
        prompt: "Shell task",
        harness: "codex",
      }),
    ).toBeUndefined();
    expect(fold.isRun("shell")).toBe(false);
    expect(fold.all()).toEqual([]);
  });
}

test("an overlapping start stays ambiguous after the other shell call fails", () => {
  const { fold, send } = folder();
  send(call("shell-a", PARENT_RUN));
  send(call("shell-b", PARENT_RUN));
  send({ sessionUpdate: "tool_call_update", toolCallId: "shell-a", status: "failed" });
  send({ sessionUpdate: "tool_call_update", toolCallId: "shell-b", status: "failed" });
  // A repeated update with its input must not reintroduce a discarded ambiguous candidate.
  send({ ...call("shell-b", PARENT_RUN), sessionUpdate: "tool_call_update" });
  expect(child(fold, 5, { event: "started", shortName: "fix", harness: "codex" })).toBeUndefined();
  expect(fold.all()).toEqual([]);
});

for (const [label, end] of [
  [
    "failed",
    (send: (update: Record<string, unknown>) => boolean) =>
      send({ sessionUpdate: "tool_call_update", toolCallId: "old", status: "failed" }),
  ],
  [
    "timed out",
    (send: (update: Record<string, unknown>) => boolean) =>
      send({ sessionUpdate: "background_task_update", toolCallId: "old", state: "timed_out" }),
  ],
] as const) {
  test(`a late child from a ${label} parent cannot consume a later same-prompt call`, () => {
    const { fold, send } = folder();
    send(call("old", PARENT_RUN));
    end(send);
    send(call("new", PARENT_RUN));
    expect(
      child(fold, 5, { event: "started", shortName: "fix", prompt: "Fix the flaky test", harness: "codex" }),
    ).toBeUndefined();
    expect(fold.isRun("new")).toBe(false);
    expect(fold.all()).toEqual([]);
  });
}

test("two background parent runs and a same-name MCP start all retain their calls", () => {
  const { fold, send } = folder();
  for (const id of ["shell-a", "shell-b"]) send(call(id, PARENT_RUN, { run_in_background: true }));
  send(sessionStart("mcp"));
  for (const [index, shortName] of ["fix", "fix-2", "fix-3"].entries())
    expect(
      child(fold, 10 + index, {
        childSessionId: `child-${index}`,
        event: "started",
        shortName,
        prompt: "Fix the flaky test",
        harness: "codex",
      }),
    ).toBeUndefined();
  for (const id of ["shell-a", "shell-b", "mcp"])
    expect(send({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", content: text(id) })).toBe(
      false,
    );
  expect(fold.all()).toEqual([]);
});

test("a completed MCP call does not poison a later distinct parent", () => {
  const { fold, send } = folder();
  send(sessionStart("mcp"));
  send({ sessionUpdate: "tool_call_update", toolCallId: "mcp", status: "completed" });
  send(call("shell", `acpmux run --parent chat-1 -n later "Review the tray"`));
  expect(child(fold, 5, { event: "started", shortName: "later", prompt: "Review the tray", harness: "codex" })).toBe(
    "shell",
  );
  expect(fold.all()[0]).toMatchObject({ session: "later", harness: "codex" });
});

test("a completed MCP start tombstone still rejects a late same-prompt child", () => {
  const { fold, send } = folder();
  send(sessionStart("mcp"));
  send({ sessionUpdate: "tool_call_update", toolCallId: "mcp", status: "completed" });
  send(call("shell", PARENT_RUN));
  expect(
    child(fold, 5, { event: "started", shortName: "fix", prompt: "Fix the flaky test", harness: "codex" }),
  ).toBeUndefined();
  expect(fold.isRun("shell")).toBe(false);
  expect(fold.all()).toEqual([]);
});

test("a native subagent's MCP start can also compete for the parent's child record", () => {
  const { fold, send } = folder();
  send(call("shell", PARENT_RUN));
  const update = sessionStart("nested-mcp");
  fold.reduce(
    {
      seq: 2,
      at: 2000,
      msg: {
        params: {
          update,
          _meta: {
            acpmux: {
              subagent: "native-agent",
              subagents: [{ id: "native-agent", parent: null, name: "native", state: "running" }],
            },
          },
        },
      },
    },
    update,
  );
  expect(child(fold, 5, { event: "started", shortName: "fix", harness: "codex" })).toBeUndefined();
  expect(fold.isRun("shell")).toBe(false);
});

test("a native subagent's own acpmux run --parent start competes for the parent's child record", () => {
  // The native subagent runs the same command as the parent: acpmux tags its update with the
  // subagent, so it never becomes the parent's call, but its child can still claim `fix` first.
  const { fold, send } = folder();
  send(call("shell", PARENT_RUN));
  const update = call("nested-shell", PARENT_RUN);
  fold.reduce(
    {
      seq: 2,
      at: 2000,
      msg: {
        params: {
          update,
          _meta: {
            acpmux: {
              subagent: "native-agent",
              subagents: [{ id: "native-agent", parent: null, name: "native", state: "running" }],
            },
          },
        },
      },
    },
    update,
  );
  expect(child(fold, 5, { event: "started", shortName: "fix", harness: "codex" })).toBeUndefined();
  expect(fold.isRun("shell")).toBe(false);
});

test("a child's different explicit name cannot fall back to a matching prompt", () => {
  const { fold, send } = folder();
  send(call("shell", PARENT_RUN));
  expect(
    child(fold, 5, { event: "started", shortName: "fix-2", prompt: "Fix the flaky test", harness: "codex" }),
  ).toBeUndefined();
  expect(fold.isRun("shell")).toBe(false);
  expect(fold.all()).toEqual([]);
});

test("a lone run whose requested name the daemon lowercases still pairs with its child", () => {
  // The daemon claims `alpha` for `-n Alpha` (acpmux `short_name_of`): the call's requested name
  // is compared in that spelling, so the one unambiguous start keeps its card, reply and link.
  for (const requested of ["Alpha", "review/router"]) {
    const { fold, send } = folder();
    send(call("shell", `acpmux run --parent chat-1 -n ${requested} "Task"`));
    const claimed = requested === "Alpha" ? "alpha" : "review-router";
    expect(child(fold, 5, { event: "started", shortName: claimed, prompt: "Task", harness: "codex" })).toBe("shell");
    expect(fold.isRun("shell")).toBe(true);
    expect(fold.all()[0]).toMatchObject({ session: claimed, child: "child-1" });
  }
});

test("an explicitly requested -N name with no competing base name pairs with its child", () => {
  // `-n fix-2` claims `fix-2` itself; the suffix is a daemon rename only when `fix` competes.
  const { fold, send } = folder();
  send(call("shell", `acpmux run --parent chat-1 -n fix-2 "Fix the flaky test"`));
  expect(child(fold, 5, { event: "started", shortName: "fix-2", prompt: "Fix the flaky test", harness: "codex" })).toBe(
    "shell",
  );
  expect(fold.isRun("shell")).toBe(true);
  expect(fold.all()[0]).toMatchObject({ session: "fix-2", child: "child-1" });
});

test("an ended unnamed and unprompted parent run leaves no tombstone that blocks later starts", () => {
  // A `--prompt-file` run says neither name nor prompt: its identity overlaps nothing it can prove.
  const { fold, send } = folder();
  send(call("file", `acpmux run --parent chat-1 --prompt-file /tmp/task.md`));
  send({ sessionUpdate: "tool_call_update", toolCallId: "file", status: "failed" });
  send(call("shell", PARENT_RUN));
  expect(child(fold, 5, { event: "started", shortName: "fix", prompt: "Fix the flaky test", harness: "codex" })).toBe(
    "shell",
  );
  expect(fold.isRun("shell")).toBe(true);
});

test("a known background parent run that times out or is cancelled ends, never stuck running", () => {
  for (const [state, ended] of [
    ["timed_out", "failed"],
    ["timed-out", "failed"],
    ["timeout", "failed"],
    ["cancelled", "cancelled"],
    ["stopped", "cancelled"],
  ] as const) {
    const { fold, send } = folder();
    expect(send(call("c1", PARENT_RUN, { run_in_background: true }))).toBe(false);
    send({
      sessionUpdate: "tool_call_update",
      toolCallId: "c1",
      status: "completed",
      content: text("Command running in background with ID: c1. Output is being written to: /tmp/c1.output."),
    });
    child(fold, 2, { event: "started", shortName: "fix", prompt: "Fix the flaky test", harness: "codex" });
    expect(fold.isRun("c1")).toBe(true);
    expect(fold.all()[0]!.state).toBe("running");
    expect(send({ sessionUpdate: "background_task_update", toolCallId: "c1", state })).toBe(true);
    expect(fold.all()[0]).toMatchObject({ state: ended, endedAt: 3000 });
  }
});
