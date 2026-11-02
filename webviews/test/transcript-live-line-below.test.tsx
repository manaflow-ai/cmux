// l10n-allow-file: test fixture prompts, replies and tool titles, not shipped UI.
// A running turn's status line as its last row (Debug Settings agentPane.debug.liveLineBelow, on
// by default), as Claude desktop draws it: what the agent is doing now and the
// turn's time. Leo (2026-10-19): "when a chat is thinking ... it doesn't do anything a lot of the
// time". The old line sat over the turn's work, so a long turn scrolled it out of view; its clock
// stopped whenever text was the latest row, though the agent went on thinking or writing a tool's
// input; and a turn that had only streamed text drew no line at all. Before the first output it
// read a bare "Thinking" with no time.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { configureLiveLineBelow, useLiveLineBelow } from "../src/agent-session/acpmux/liveLineBelow";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingFor } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { THINKING, turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { insertByTime } from "../src/agent-session/acpmux/shell/shellRuns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, status: string) => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status },
});
const thought = { kind: "thought", text: "Weighing the two parsers" };
const shaped = (rows: AcpmuxRow[], lineBelow = true) => turnView(rows, new Set(), { working: true, lineBelow });
/// The kinds drawn, without the date line an old fixture time puts over the prompt.
const kinds = (rows: AcpmuxRow[]) => rows.map((entry) => entry.kind).filter((kind) => kind !== "date");
const lineOf = (rows: AcpmuxRow[]) => rows.find((entry) => entry.kind === WORKING || entry.kind === THINKING);
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
/// The line drawn 26s after the prompt.
const drawn = (line: AcpmuxRow, prompt: AcpmuxRow) =>
  renderToStaticMarkup(<WorkingFor row={line} now={() => prompt.at + 26_000} />);

test("before any output, the last row reads Thinking with the turn's time", () => {
  const prompt = row("u", "user");
  const rows = shaped([prompt]);
  const line = rows.at(-1)!;
  expect(line.kind).toBe(WORKING);
  expect(text(drawn(line, prompt))).toBe("Thinking 26s");
});

test("while the answer streams, the line stays under it and its clock keeps going", () => {
  const prompt = row("u", "user");
  const answer = row("a", "assistant", { text: "Looking", streaming: true });
  const rows = shaped([prompt, answer]);
  expect(kinds(rows)).toEqual(["user", "assistant", WORKING]);
  expect(text(drawn(rows.at(-1)!, prompt))).toBe("Working for 26s");
});

test("text after work does not stop the clock: the agent may still think or write a call", () => {
  const prompt = row("u", "user");
  const rows = shaped([
    prompt,
    row("run", "activity", { items: [call("git log", "completed")] }),
    row("a", "assistant", { text: "Now I'll write the parser." }),
  ]);
  const line = rows.at(-1)!;
  expect(line.kind).toBe(WORKING);
  expect(line.durationMs).toBeUndefined();
  expect(text(drawn(line, prompt))).toBe("Working for 26s");
});

test("a lone call in flight is named on its own row, so the last row only times the turn", () => {
  // One running call reads once (#23090): its tool row names it.
  const prompt = row("u", "user");
  const rows = shaped([prompt, row("run", "activity", { items: [call("bun test", "in_progress")] })]);
  expect(kinds(rows)).toEqual(["user", "activity", WORKING]);
  expect(text(drawn(rows.at(-1)!, prompt))).toBe("Working for 26s");
});

test("a thought coming in labels itself, so the line does not say Thinking twice", () => {
  const prompt = row("u", "user");
  const rows = shaped([prompt, row("run", "activity", { items: [call("git log", "completed"), thought] })]);
  expect(text(drawn(rows.at(-1)!, prompt))).toBe("Working for 26s");
});

test("a prompt the turn holds (a steer not yet read) draws above the line, which stays last", () => {
  const prompt = row("u", "user");
  const work = row("run", "activity", { items: [call("bun test", "in_progress")] });
  const steer = row("s", "user", { text: "also check the docs", pending: true });
  const rows = shaped([prompt, work, steer]);
  expect(kinds(rows)).toEqual(["user", "activity", "user", WORKING]);
});

test("a shell command run during the turn goes above the line", () => {
  const prompt = row("u", "user");
  const rows = shaped([prompt, row("run", "activity", { items: [call("bun test", "in_progress")] })]);
  const shell = { id: "shell-1", kind: "shell", version: 1, at: (at += 1_000) };
  expect(kinds(insertByTime(rows, [shell]))).toEqual(["user", "activity", "shell", WORKING]);
});

test("the line keeps one row from send to the first output, and draws no rule under it", () => {
  const prompt = row("u", "user");
  const before = lineOf(shaped([prompt]))!;
  const after = lineOf(shaped([prompt, row("run", "activity", { items: [call("ls", "in_progress")] })]))!;
  expect(after.id).toBe(before.id);
  expect(drawn(after, prompt)).not.toContain("has-divider");
});

test("with the toggle off, the line sits over the work and holds while text streams", () => {
  const prompt = row("u", "user");
  const work = row("run", "activity", { items: [call("git log", "completed")] });
  const answer = row("a", "assistant", { text: "Done." });
  const rows = shaped([prompt, work, answer], false);
  expect(kinds(rows)).toEqual(["user", WORKING, "activity", "assistant"]);
  expect(lineOf(rows)!.durationMs).toBe(answer.at - prompt.at);
});

test("the first Thinking line ticks from the prompt, also while its agent starts", () => {
  expect(text(renderToStaticMarkup(<Thinking since={1_000} now={() => 13_000} />))).toBe("Thinking 12s");
  // No "Starting Claude Code…" (Leo, 2026-11-01): the default start look is the same line.
  expect(text(renderToStaticMarkup(<Thinking starting since={1_000} now={() => 13_000} />))).toBe("Thinking 12s");
});

test("the toggle is on unless the host turns it off", () => {
  const read = () => {
    let value: boolean | undefined;
    function Probe() {
      value = useLiveLineBelow();
      return null;
    }
    renderToStaticMarkup(<Probe />);
    return value;
  };
  expect(read()).toBe(true);
  configureLiveLineBelow(false);
  expect(read()).toBe(false);
  configureLiveLineBelow(undefined);
  expect(read()).toBe(true);
});
