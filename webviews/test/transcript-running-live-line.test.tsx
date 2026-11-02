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
        <Thinking
          since={line.at}
          doing={line.doing}
          doingAt={line.doingAt}
          doingShell
          command
          now={() => line.at + 12_000}
        />,
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
  // The line holds the latest finished step instead, never the backgrounded command.
  expect(shaped.at(-1)).toMatchObject({ doing: "git log", doingDone: true });
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

// Review on #24305 (Codex xhigh): the run that gave its command to the line has its own version,
// never one another drawn state of that run shares, or the memoized row keeps the shorter list
// when the turn ends with its fold open (App.tsx compares ids and versions).
test("a run whose command is on the line never shares a version with its ended, open fold", () => {
  const user = row("u", "user");
  const run = row("r1", "activity", { items: [call("git log"), call("cp a b", "in_progress")] });
  const note = row("a", "assistant", { text: LONG_NOTE });
  const step = row("r2", "activity", { items: [call("git diff")] });
  const live = turnView([user, run, note, step], new Set(["worked-u"]), {
    working: true,
    liveRuns: true,
    lineBelow: true,
  });
  const lined = live.find((entry) => entry.id === "r1")!;
  expect(lined.items?.map((item) => item.tool?.id)).toEqual(["git log"]);
  // The turn ends with no new version for the earlier run (turn_result moves no tool row).
  const ended = turnView(
    [
      user,
      run,
      note,
      step,
      row("ans", "assistant", { text: "Done." }),
      row("s", "turnSummary", { status: "completed" }),
    ],
    new Set(["worked-u"]),
    { liveRuns: true, lineBelow: true },
  );
  const folded = ended.find((entry) => entry.id === "r1")!;
  expect(folded.items?.map((item) => item.tool?.id)).toEqual(["git log", "cp a b"]);
  expect(folded.version).not.toBe(lined.version);
});

test("with a todo list the activity line offers ⌃B for a running command", async () => {
  const { ActivityLine } = await import("../src/agent-session/acpmux/conversation/ActivityLine");
  const plan = row("p", "plan", { plan: [{ content: "Copy the logs", status: "in_progress" }] });
  for (const liveRuns of [false, true]) {
    const shaped = turnView(
      [row("u", "user"), plan, row("run", "activity", { items: [call("git log"), call("cp a b", "in_progress")] })],
      new Set(),
      { working: true, liveRuns, lineBelow: true, sessionStatus: true },
    );
    const line = shaped.at(-1)!;
    expect(line).toMatchObject({ kind: "activityLine", doingCommand: true });
    expect(withCtrlB(<ActivityLine row={line} />)).toContain("cv-command__bg");
  }
});

test("the older layout offers no ⌃B while the agent still writes the command", () => {
  const draft = call("Bash", "pending", { title: "Bash", command: undefined });
  for (const lineBelow of [false, true]) {
    const shaped = turnView(
      [row("u", "user"), row("run", "activity", { items: [call("git log"), draft] })],
      new Set(),
      {
        working: true,
        lineBelow,
      },
    );
    const line = shaped.find((entry) => entry.kind === "working")!;
    expect(line.doingDraft).toBe(true);
    expect(withCtrlB(<WorkingFor row={line} now={() => line.at + 5_000} />)).not.toContain("cv-command__bg");
  }
});

// Re-review on #24305 (Codex xhigh): with a todo list the activity line names the command the runs
// left out, even when a newer earlier run holds a read or a call Claude is still writing.
test("with a todo list the activity line names the command its run gave up", () => {
  const plan = row("p", "plan", { plan: [{ content: "Copy the logs", status: "in_progress" }] });
  const newer = [
    call("Bash", "pending", { title: "Bash", command: undefined }),
    call("Read session.log", "in_progress", { kind: "read", command: undefined }),
  ];
  for (const other of newer) {
    const shaped = turnView(
      [
        row("u", "user"),
        plan,
        row("r1", "activity", { items: [call("cp a b", "in_progress")] }),
        row("a1", "assistant", { text: LONG_NOTE }),
        row("r2", "activity", { items: [other] }),
        row("a2", "assistant", { text: LONG_NOTE }),
        row("r3", "activity", { items: [call("git status")] }),
      ],
      new Set(),
      { working: true, liveRuns: true, lineBelow: true, sessionStatus: true },
    );
    const line = shaped.at(-1)!;
    expect(line).toMatchObject({ kind: "activityLine", doingCommand: true });
    expect(line.text).toContain("cp a b");
    expect(shaped.some((entry) => entry.id === "r1")).toBe(false);
  }
});
