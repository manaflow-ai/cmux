import { expect, spyOn, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { groupAgentMessages } from "./waitingMessages";
import * as waitingMessages from "./waitingMessages";
import { turnViewFrom } from "./turns";
import { withShellRows, type ShellRun } from "../shell/shellRuns";

function message(id: string, name = "claude-sr2", text = id): AcpmuxRow {
  return {
    id,
    version: 1,
    at: 1,
    kind: "user",
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
    untyped: true,
  };
}

test("keeps one received message as its ordinary row", () => {
  const one = message("m1");
  expect(groupAgentMessages([one])).toEqual([one]);
});

test("folds consecutive received messages into one reusable card row", () => {
  const rows: readonly AcpmuxRow[] = Object.freeze([message("m1"), message("m2"), message("m3")]);
  const grouped = groupAgentMessages(rows);
  const [fold] = grouped;
  expect(fold?.kind).toBe("waitingMessages");
  expect(fold?.waiting).toEqual({ delivery: "chat", rows });
  expect(fold?.joined).toEqual(["m1", "m2", "m3"]);
  expect(fold?.text).toBe("m1\n\nm2\n\nm3");
  expect(groupAgentMessages(rows)[0]).toBe(fold);
});

test("replaces a cached fold when a received message changes", () => {
  const first = message("m1");
  const previous = groupAgentMessages([first, message("m2")]);
  const updated = groupAgentMessages([first, message("m2", "claude-sr2", "updated")]);
  expect(updated[0]).not.toBe(previous[0]);
  expect(updated[0]?.text).toBe("m1\n\nupdated");
  expect(updated[0]?.version).toBe((previous[0]?.version ?? 0) + 1);
});

test("a non-message row ends a fold and the next run starts independently", () => {
  const first = message("m1");
  const second = message("m2");
  const third = message("m3");
  const assistant: AcpmuxRow = { id: "answer", version: 1, at: 1, kind: "assistant", text: "done" };
  const result = groupAgentMessages([first, second, assistant, third, message("m4")]);
  expect(result.map((row) => row.id)).toEqual(["messages-m1", "answer", "messages-m3"]);
  expect(result[0]?.joined).toEqual(["m1", "m2"]);
  expect(result[2]?.waiting?.rows.map((row) => row.id)).toEqual(["m3", "m4"]);
});

function answer(id: string, text = "reply"): AcpmuxRow {
  return { id, version: 1, at: 2, kind: "assistant", text };
}

test("streaming fresh tail objects visits a constant number of fold rows", () => {
  const history: AcpmuxRow[] = [];
  for (let i = 0; i < 1_000; i += 1) history.push(message(`a-${i}`), message(`b-${i}`), answer(`reply-${i}`));
  const prompt = message("live-prompt");
  const expanded = new Set<string>();
  const options = { now: 2, working: true, lineBelow: true };
  let view = turnViewFrom([...history, prompt, answer("live")], expanded, options);
  const firstFold = view.rows.find((row) => row.waiting?.delivery === "chat");
  const group = groupAgentMessages;
  let visits = 0;
  const spy = spyOn(waitingMessages, "groupAgentMessages").mockImplementation((rows, out) =>
    group(rows, out, () => (visits += 1)),
  );
  try {
    const tokens = 100;
    for (let token = 0; token < tokens; token += 1) {
      const before = view;
      const oldRows = before.rows.slice();
      view = turnViewFrom([...history, prompt, answer("live", `token ${token}`)], expanded, options, before);
      expect(before.rows).toEqual(oldRows);
      expect(view.rows.find((row) => row.waiting?.delivery === "chat")).toBe(firstFold);
      expect(view.rows.some((row) => row.text === `token ${token}`)).toBe(true);
    }
    expect(visits).toBeGreaterThan(0);
    expect(visits).toBeLessThanOrEqual(tokens * 4);
    console.log(`agent-message-fold visits=${visits} tokens=${tokens} historyRows=${history.length}`);
  } finally {
    spy.mockRestore();
  }
});

test("a fold crossing a reused turn boundary neither duplicates nor drops messages", () => {
  const first = message("a");
  const third = message("c");
  const rows = [first, message("b"), third, answer("live")];
  const expanded = new Set<string>();
  const options = { now: 2, working: true, lineBelow: true };
  const previous = turnViewFrom(rows, expanded, options);
  const next = turnViewFrom([...rows.slice(0, -1), answer("live", "next")], expanded, options, previous);
  const fold = next.rows.find((row) => row.waiting?.delivery === "chat");
  expect(fold?.joined).toEqual(["a", "b", "c"]);
  expect(next.rows.filter((row) => row.waiting?.delivery === "chat")).toHaveLength(1);
  expect(fold).toBe(previous.rows.find((row) => row.waiting?.delivery === "chat"));

  const changed = turnViewFrom(
    [first, message("b", "claude-sr2", "edited"), third, answer("live", "next")],
    expanded,
    options,
    next,
  );
  expect(changed.rows.find((row) => row.waiting?.delivery === "chat")?.text).toBe("a\n\nedited\n\nc");
});

test("a synthetic shell block ends a received-message run, including a newly inserted block", () => {
  const first = { ...message("a"), at: 1 };
  const second = { ...message("b"), at: 3 };
  const rows = [first, second];
  const expanded = new Set<string>();
  const previous = turnViewFrom(rows, expanded, { now: 3 });
  expect(previous.rows.some((row) => row.waiting?.delivery === "chat")).toBe(true);
  for (const startedAt of [1, 2]) {
    const shell: ShellRun = {
      id: "cmd",
      command: "pwd",
      startedAt,
      status: "done",
      output: "/tmp",
      truncated: false,
      version: 1,
    };
    const view = turnViewFrom(rows, expanded, { now: 3, messageBreaks: [startedAt] }, previous);
    const shown = withShellRows(view.rows, [shell]).filter((row) => row.kind !== "date");
    expect(shown.map((row) => row.id)).toEqual(["a", "shell-cmd", "b"]);
    expect(shown.some((row) => row.waiting?.delivery === "chat")).toBe(false);
  }
  // Before or after the run: the messages remain adjacent and may still fold.
  for (const startedAt of [0, 3]) {
    const view = turnViewFrom(rows, expanded, { now: 3, messageBreaks: [startedAt] }, previous);
    expect(view.rows.find((row) => row.waiting?.delivery === "chat")?.joined).toEqual(["a", "b"]);
  }
});
