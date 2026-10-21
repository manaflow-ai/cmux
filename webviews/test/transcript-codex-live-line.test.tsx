// l10n-allow-file: test fixture commands and replies, not shipped UI.
// The running turn as the Codex app draws it (Leo 2026-10-20, stack-224..226.png): "Working for"
// stays over the turn's work, finished runs fold, and ONE live line at the bottom of the turn is
// replaced in place by each step: Thinking (shimmer) -> Running <short label> 13s -> Thinking.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { THINKING, turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { shortCommand } from "../src/agent-session/acpmux/conversation/shortCommand";

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
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
const codex = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true, liveRuns: true, lineBelow: true });
const kinds = (rows: AcpmuxRow[]) => rows.map((entry) => entry.kind).filter((kind) => kind !== "date");
const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("before any output the turn is one Thinking line, timed from the prompt", () => {
  const shaped = codex([row("u", "user")]);
  expect(kinds(shaped)).toEqual(["user", THINKING]);
  expect(shaped.at(-1)).toMatchObject({ id: "thinking-live", below: true });
  expect(shaped.at(-1)!.untimed).toBeUndefined();
});

test("a call in flight is the live line at the bottom, under Working for and the folded runs", () => {
  const shaped = codex([
    row("u", "user"),
    row("a", "assistant", { text: "On it." }),
    row("run", "activity", { items: [call("git log"), call("bun test src/net", "in_progress")] }),
  ]);
  expect(kinds(shaped)).toEqual(["user", WORKING, "assistant", "activity", THINKING]);
  const line = shaped.at(-1)!;
  expect(line).toMatchObject({ id: "thinking-live", doing: "bun test src/net", doingShell: true, untimed: false });
  // The run holds only the finished call, folded.
  const run = shaped.find((entry) => entry.id === "run")!;
  expect(run.items?.map((item) => item.tool?.id)).toEqual(["git log"]);
  expect(run.foldRun).toBe(true);
  // "Working for" stays a line over the work, not the bottom line.
  expect(shaped.find((entry) => entry.kind === WORKING)!.below).toBeUndefined();
});

test("each step replaces the line in place: Thinking, Running, Thinking, one id throughout", () => {
  const user = row("u", "user");
  const thinking = codex([user, row("run", "activity", { items: [call("git log"), thought("Now the tests")] })]);
  const running = codex([user, row("run", "activity", { items: [call("git log"), call("bun test", "in_progress")] })]);
  const after = codex([user, row("run", "activity", { items: [call("git log"), call("bun test")] })]);
  const lines = [thinking, running, after].map((shaped) => shaped.filter((entry) => entry.kind === THINKING));
  expect(lines.map((line) => line.length)).toEqual([1, 1, 1]);
  expect(lines.map((line) => line[0]!.id)).toEqual(["thinking-live", "thinking-live", "thinking-live"]);
  expect(lines.map((line) => line[0]!.doing)).toEqual([undefined, "bun test", undefined]);
  // No running row stacks up in the run.
  expect(running.find((entry) => entry.id === "run")!.items).toHaveLength(1);
});

test("a command reads its description, or its short command line without the setup", () => {
  const described = codex([
    row("u", "user"),
    row("run", "activity", {
      items: [call('export PATH="/a:$PATH"; gh run list', "in_progress", { description: "List the runs" })],
    }),
  ]).at(-1)!;
  expect(described).toMatchObject({ doing: "List the runs", doingShell: false });
  const raw = codex([
    row("u", "user"),
    row("run", "activity", { items: [call('export PATH="/a:$PATH"; B=~/x; gh run list -L 5', "in_progress")] }),
  ]).at(-1)!;
  expect(raw).toMatchObject({ doing: "gh run list -L 5", doingShell: true });
});

test("while text streams the line waits behind it, keyed by the text's version", () => {
  const shaped = codex([
    row("u", "user"),
    row("run", "activity", { items: [call("git log")] }),
    row("a", "assistant", { text: "The regression is", version: 7 }),
  ]);
  expect(shaped.at(-1)).toMatchObject({ kind: THINKING, quietKey: "a:7" });
});

test("the live line draws Running with the call's time, or Thinking alone; both shimmer", () => {
  const start = 1_000_000;
  const running = renderToStaticMarkup(
    <Thinking doing="bun test" doingShell doingAt={start} now={() => start + 13_000} untimed={false} />,
  );
  expect(words(running)).toBe("Running bun test 13s");
  expect(running).toContain("is-shimmer");
  const described = renderToStaticMarkup(
    <Thinking doing="Run the web tests" doingAt={start} now={() => start + 2_000} />,
  );
  expect(words(described)).toBe("Run the web tests 2s");
  expect(words(renderToStaticMarkup(<Thinking doing="" doingShell doingAt={start} now={() => start} />))).toBe(
    "Running a command 0s",
  );
  const thinking = renderToStaticMarkup(<Thinking since={start} untimed now={() => start + 9_000} />);
  expect(words(thinking)).toBe("Thinking");
  expect(thinking).toContain("is-shimmer");
  // Behind streaming text it keeps its height but draws nothing.
  expect(renderToStaticMarkup(<Thinking untimed quietKey="a:7" />)).toContain("cv-worked is-quiet");
});

test("shortCommand drops the setup a script starts with", () => {
  expect(shortCommand('export PATH="/Applications/cmux NIGHTLY.app/bin:$PATH"; B=~/p; gh pr view 1')).toBe(
    "gh pr view 1",
  );
  expect(shortCommand("cd ~/Projects/cmux && git status")).toBe("git status");
  expect(shortCommand("bun test")).toBe("bun test");
  expect(shortCommand("export A=1")).toBe("export A=1");
});

test("shortCommand drops environment set in front of the command, quoted values with spaces too", () => {
  expect(
    shortCommand('export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"\nacpmux ls 2>&1'),
  ).toBe("acpmux ls 2>&1");
  expect(shortCommand('PATH="/Applications/cmux NIGHTLY.app/bin:$PATH" acpmux ls')).toBe("acpmux ls");
  expect(shortCommand("A=1 B='x y' bun test src")).toBe("bun test src");
});

test("two runs with only a short note between them draw as one run, the note folded in", () => {
  const shaped = codex([
    row("u", "user"),
    row("r1", "activity", { items: [call("acpmux ls"), call("gh pr list")] }),
    row("n", "assistant", { text: "Relay the decisions, then answer." }),
    row("r2", "activity", { items: [call("gh pr view 1"), call("acpmux send", "in_progress")] }),
  ]);
  expect(kinds(shaped)).toEqual(["user", WORKING, "activity", THINKING]);
  const run = shaped.find((entry) => entry.kind === "activity")!;
  expect(run.id).toBe("r1");
  expect(run.items?.map((item) => item.tool?.id ?? item.text)).toEqual([
    "acpmux ls",
    "gh pr list",
    "Relay the decisions, then answer.",
    "gh pr view 1",
  ]);
  const html = renderToStaticMarkup(<ToolRows row={{ ...run, foldRun: false }} />);
  expect(html).toContain('<p class="cv-tool-note">Relay the decisions, then answer.</p>');
  expect(shaped.at(-1)!.doing).toBe("acpmux send");
});

test("a long note, or one with code, stays its own paragraph between the runs", () => {
  const long = "x".repeat(200);
  for (const text of [long, "First.\n\nSecond.", "Run ```bun test``` next"]) {
    const shaped = codex([
      row("u", "user"),
      row("r1", "activity", { items: [call("a")] }),
      row("n", "assistant", { text }),
      row("r2", "activity", { items: [call("b")] }),
    ]);
    expect(kinds(shaped)).toEqual(["user", WORKING, "activity", "assistant", "activity", THINKING]);
  }
});

test("an ended turn's open Worked for merges runs split by a short note too", () => {
  const rows = [
    row("u", "user"),
    row("r1", "activity", { items: [call("a"), call("b")] }),
    row("n", "assistant", { text: "Checking the logs next." }),
    row("r2", "activity", { items: [call("c")] }),
    row("ans", "assistant", { text: "Done: the fix is in." }),
    row("s", "turnSummary", { status: "completed", toolCount: 3 }),
  ];
  const open = turnView(rows, new Set(["worked-u"]), { liveRuns: true });
  expect(kinds(open)).toEqual(["user", "worked", "activity", "assistant", "turnSummary"]);
  expect(open.find((entry) => entry.kind === "assistant")!.id).toBe("ans");
});

test("Find and a shell's count reach every row a merged run absorbed", async () => {
  const { findRowIndex, isRevealRow } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const rows = [
    row("u", "user"),
    row("x", "activity", { items: [call("git log")] }),
    row("n", "assistant", { text: "Now checking the zebra config." }),
    row("y", "activity", { items: [call("cat bravo.json")] }),
    row("ans", "assistant", { text: "Done." }),
    row("s", "turnSummary", { status: "completed", toolCount: 2 }),
  ];
  const open = turnView(rows, new Set(["worked-u"]), { liveRuns: true });
  const merged = open.findIndex((entry) => entry.id === "x");
  expect(open[merged]!.joined).toEqual(["x", "n", "y"]);
  for (const id of ["x", "n", "y"]) expect(findRowIndex(open, id)).toBe(merged);
  expect(isRevealRow(open[merged]!, { rowId: "y", card: false })).toBe(true);
  const live = codex(rows.slice(0, 4));
  expect(findRowIndex(live, "n")).toBe(live.findIndex((entry) => entry.id === "x"));
});

test("shortCommand splits only outside quotes", () => {
  expect(shortCommand('cd ~/x && python -c "import x; print(1)"')).toBe('python -c "import x; print(1)"');
  expect(shortCommand("A='a;b' bun test; echo done")).toBe("bun test …");
  expect(shortCommand("make && rm -rf build")).toBe("make …");
});

test("a command with no line yet reads its title, or Running a command for the bare tool name", () => {
  const titled = codex([
    row("u", "user"),
    row("run", "activity", { items: [call("t1", "in_progress", { title: "Run make", command: undefined })] }),
  ]).at(-1)!;
  expect(titled).toMatchObject({ doing: "Run make", doingShell: false });
  const bare = codex([
    row("u", "user"),
    row("run", "activity", { items: [call("t2", "in_progress", { title: "Bash", command: undefined })] }),
  ]).at(-1)!;
  expect(bare).toMatchObject({ doing: "", doingShell: true });
});

test("with a todo list the activity line under it is the live line", () => {
  const plan = row("p", "plan", { plan: [{ content: "Fix the grid", status: "in_progress" }] });
  const shaped = turnView(
    [row("u", "user"), plan, row("run", "activity", { items: [call("git log"), call("bun test", "in_progress")] })],
    new Set(),
    { working: true, liveRuns: true, lineBelow: true, sessionStatus: true },
  );
  expect(kinds(shaped).slice(-2)).toEqual(["plan", "activityLine"]);
  expect(shaped.at(-1)!.text).toContain("bun test");
});
