// l10n-allow-file: test fixture commands and replies, not shipped UI.
// A running command is the live line, never a row of its own with the ⌃B hint (Leo, 2026-10-22:
// "this cmd b to run in background or whatever ctrl b it should prob go down...? likewise with teh
// ran whatever. the ran thing basiclly replcaes the thinking usually"). His chat had a `cp` still
// running in an earlier run while the agent messaged others: the row read "Ran cp …" with
// "⌃B to run in background" beside it, and the line at the bottom read "Thinking".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { RunInBackgroundContext } from "../src/agent-session/acpmux/conversation/runInBackground";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (id: string, status = "completed", extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status, command: id, startedAt: at, ...extra },
});
const codex = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true, liveRuns: true, lineBelow: true });
const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const withCtrlB = (node: React.ReactNode) =>
  renderToStaticMarkup(<RunInBackgroundContext.Provider value={() => {}}>{node}</RunInBackgroundContext.Provider>);
const LONG_NOTE = "I'll message the other lanes with the summary while the copy runs. ".repeat(4);

test("a command still running in an earlier run is the live line, not Thinking under its row", () => {
  const cp = "cp /private/tmp/session.jsonl ~/Projects/recovery/";
  const shaped = codex([
    row("u", "user"),
    row("r1", "activity", { items: [call(cp, "in_progress")] }),
    row("a", "assistant", { text: LONG_NOTE }),
    row("r2", "activity", { items: [call("git log")] }),
  ]);
  const line = shaped.at(-1)!;
  expect(line).toMatchObject({ kind: THINKING, doing: cp, doingShell: true, doingCommand: true });
  // The running cp left its run, so it reads once, on the line.
  const tools = shaped.flatMap((entry) => entry.items ?? []).map((item) => item.tool?.id);
  expect(tools).toEqual(["git log"]);
  expect(shaped.some((entry) => entry.id === "r1")).toBe(false);
  expect(
    words(
      withCtrlB(
        <Thinking doing={line.doing} doingAt={line.doingAt} doingShell command now={() => line.doingAt! + 12_000} />,
      ),
    ),
  ).toBe(`Running ${cp} 12s ⌃B to run in background`);
});

test("the call in the latest step still names the line before an older command", () => {
  const shaped = codex([
    row("u", "user"),
    row("r1", "activity", { items: [call("cp a b", "in_progress")] }),
    row("a", "assistant", { text: LONG_NOTE }),
    row("r2", "activity", { items: [call("bun test", "in_progress")] }),
  ]);
  expect(shaped.at(-1)).toMatchObject({ doing: "bun test", doingCommand: true });
  // The older command keeps its row, which says it is still running and offers no ⌃B.
  expect(shaped.find((entry) => entry.id === "r1")?.items?.map((item) => item.tool?.id)).toEqual(["cp a b"]);
});

test("a backgrounded command stays in its run and never takes the line", () => {
  const shaped = codex([
    row("u", "user"),
    row("r1", "activity", {
      items: [call("cargo watch", "in_progress", { background: { state: "running" } as Tool["background"] })],
    }),
    row("a", "assistant", { text: LONG_NOTE }),
    row("r2", "activity", { items: [call("git log")] }),
  ]);
  expect(shaped.at(-1)!.doing).toBeUndefined();
  expect(shaped.some((entry) => entry.id === "r1")).toBe(true);
});

test("a running command's row has no ⌃B hint and reads Running, then Ran", () => {
  const running = call("cp a b", "in_progress").tool!;
  const item = { kind: "tool", text: "", tool: running } as AcpmuxActivity;
  for (const html of [withCtrlB(<CommandRow item={item} />), withCtrlB(<ToolRow item={item} />)]) {
    expect(html).not.toContain("cv-command__bg");
    expect(words(html)).toContain("Running cp a b");
    expect(words(html)).not.toContain("Ran ");
  }
  const done = { ...item, tool: { ...running, status: "completed", exitCode: 0 } } as AcpmuxActivity;
  expect(words(withCtrlB(<CommandRow item={done} />))).toContain("Ran cp a b");
});

test("the older live line (Working for) carries the hint too, even while the command's row shows", () => {
  const html = withCtrlB(
    <WorkingFor
      row={{ id: "w", kind: "working", version: 1, at: 0, below: true, doingCommand: true }}
      now={() => 5_000}
    />,
  );
  expect(html).toContain("cv-command__bg");
});
