import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { subagentsIn } from "../src/agent-session/acpmux/subagents/subagentRows";
import { chatHasSummaryContent } from "../src/agent-session/acpmux/summary/summaryContent";

// The chat asks on every streamed snapshot whether its summary has content, and lists its
// subagents. A row already answered is not examined again, and the subagent scan reads the rows
// in place.

const row = (id: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "assistant",
  text: "plain reply",
  ...fields,
});
const tool = (fields: Record<string, unknown>) => ({
  kind: "tool",
  text: "",
  tool: { id: "t", title: "Run", status: "completed", ...fields },
});

test("the summary has content for each kind of row it lists", () => {
  const cases: Array<[string, AcpmuxRow, boolean]> = [
    ["plain reply", row("a"), false],
    ["background task", row("b", { kind: "backgroundTask", backgroundTask: {} as AcpmuxRow["backgroundTask"] }), true],
    ["subagents", row("c", { kind: "subagents", subagents: [{ id: "s" } as never] }), true],
    ["empty subagents", row("d", { kind: "subagents", subagents: [] }), false],
    ["an edit", row("e", { kind: "activity", items: [tool({ diffs: [{}] })] }), true],
    ["a fetch", row("f", { kind: "activity", items: [tool({ kind: "fetch" })] }), true],
    ["a wakeup", row("g", { kind: "activity", items: [tool({ title: "ScheduleWakeup in 5m" })] }), true],
    [
      "a failed wakeup",
      row("h", { kind: "activity", items: [tool({ title: "ScheduleWakeup", status: "failed" })] }),
      false,
    ],
    [
      "a background shell",
      row("i", { kind: "activity", items: [tool({ kind: "execute", inputSummary: '{"run_in_background":true}' })] }),
      true,
    ],
    ["gh pr create", row("j", { kind: "activity", items: [tool({ kind: "execute", command: "gh pr create" })] }), true],
    ["a plain command", row("k", { kind: "activity", items: [tool({ kind: "execute", command: "ls" })] }), false],
  ];
  for (const [name, value, expected] of cases)
    expect([name, chatHasSummaryContent([row("u", { kind: "user", text: "hi" }), value])]).toEqual([name, expected]);
});

test("a reply's image counts through the gallery", () => {
  const image = row("img", { text: "![shot](data:image/png;base64,AAAA)" });
  expect(chatHasSummaryContent([row("u", { kind: "user" }), image])).toBe(true);
});

test("a row is examined once across snapshots", () => {
  let reads = 0;
  const edit = {
    id: "edit",
    version: 1,
    at: 0,
    kind: "activity",
    get items() {
      reads += 1;
      return [tool({ diffs: [{}] })];
    },
  } as AcpmuxRow;
  const rows = [row("u", { kind: "user" }), edit];
  for (let snapshot = 0; snapshot < 5; snapshot++) {
    expect(chatHasSummaryContent([...rows, row(`live-${snapshot}`, { text: "x".repeat(snapshot) })])).toBe(true);
  }
  expect(reads).toBe(1);
});

test("subagentsIn lists the rows' and every view's subagents, later ones winning", () => {
  const agent = (id: string, name: string) => ({ id, name }) as never;
  const rows = [row("g1", { kind: "subagents", subagents: [agent("a", "first"), agent("b", "b")] })];
  const views = {
    a: [row("g2", { kind: "subagents", subagents: [agent("a", "renamed"), agent("c", "c")] })],
  };
  const found = subagentsIn(rows, views);
  expect([...found.keys()]).toEqual(["a", "b", "c"]);
  expect((found.get("a") as unknown as { name: string }).name).toBe("renamed");
  expect([...subagentsIn(rows).keys()]).toEqual(["a", "b"]);
});
