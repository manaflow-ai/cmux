// l10n-allow-file: test fixture commands and replies, not shipped UI.
// The running turn as the Codex app draws it (Leo 2026-10-20, stack-224..226.png): "Working for"
// stays over the turn's work, finished runs fold, and ONE live line at the bottom of the turn is
// replaced in place by each step: Thinking (shimmer) -> Running <short label> 13s -> Thinking.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { THINKING, turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { shortCommand } from "../src/agent-session/acpmux/toolPaths";

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
  const described = renderToStaticMarkup(<Thinking doing="Run the web tests" doingAt={start} now={() => start + 2_000} />);
  expect(words(described)).toBe("Run the web tests 2s");
  expect(words(renderToStaticMarkup(<Thinking doing="" doingShell doingAt={start} now={() => start}/>))).toBe(
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
