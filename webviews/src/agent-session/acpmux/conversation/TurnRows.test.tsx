import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { toolGroups } from "./toolGroups";
import { renderToStaticMarkup } from "react-dom/server";
import { runStretches, ToolRows, shouldFoldToolRun } from "./TurnRows";
import { Globe, MultiTool } from "./icons";

const command = (id: string, text: string): AcpmuxActivity => ({
  kind: "tool",
  text,
  tool: { id, title: "Shell", kind: "execute", status: "completed", command: text },
});

const message = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "Sent message to coordinator",
  tool: {
    id,
    title: "cmux send",
    kind: "execute",
    status: "completed",
    command: "cmux send --to coordinator --message done",
  },
});

const row = (items: AcpmuxActivity[], foldRun = true): AcpmuxRow => ({
  id: "activity",
  version: 1,
  at: 1,
  kind: "activity",
  settled: true,
  foldRun,
  items,
});

test("folds a run the Codex-style runs settled, made only of tool groups", () => {
  const items: AcpmuxActivity[] = [
    command("one", "bun test one"),
    { kind: "tool", text: "Read config", tool: { id: "read", title: "Read", kind: "read", status: "completed" } },
  ];
  expect(toolGroups(items)).toHaveLength(2);
  expect(shouldFoldToolRun(row(items), toolGroups(items))).toBe(true);
});

const fetchCall = (id: string, url: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Fetch ${url}`,
  tool: { id, title: `Fetch ${url}`, kind: "fetch", status: "completed" },
});

// The folded run's line: the several-tools glyph when its calls did more than one kind of work, the
// one kind's glyph otherwise.
test("a folded run of several kinds of work draws the several-tools glyph", () => {
  const items: AcpmuxActivity[] = [
    command("one", "bun test one"),
    { kind: "tool", text: "Read config", tool: { id: "read", title: "Read", kind: "read", status: "completed" } },
  ];
  const html = renderToStaticMarkup(<ToolRows row={row(items)} />);
  expect(html).toContain(renderToStaticMarkup(<MultiTool />));
});

test("a folded run of one kind of work keeps that kind's glyph", () => {
  const items = [fetchCall("one", "https://example.com/a"), fetchCall("two", "https://example.com/b")];
  expect(shouldFoldToolRun(row(items), toolGroups(items))).toBe(true);
  const html = renderToStaticMarkup(<ToolRows row={row(items)} />);
  expect(html).toContain(renderToStaticMarkup(<Globe size={16} strokeWidth={1.1} />));
  expect(html).not.toContain(renderToStaticMarkup(<MultiTool />));
});

test("keeps each group of an ended turn's run on its own line", () => {
  const items: AcpmuxActivity[] = [
    command("one", "bun test one"),
    { kind: "tool", text: "Read config", tool: { id: "read", title: "Read", kind: "read", status: "completed" } },
  ];
  expect(shouldFoldToolRun(row(items, false), toolGroups(items))).toBe(false);
});

test("keeps a coordination message visible beside settled tool calls", () => {
  const items = [message("message"), command("command", "bun test")];
  const groups = toolGroups(items);
  expect(groups.some((group) => group.type === "message")).toBe(true);
  expect(shouldFoldToolRun(row(items), groups)).toBe(false);
});

test("keeps a sub-session card visible beside settled tool calls", () => {
  const start: AcpmuxActivity = {
    kind: "tool",
    text: "mcp__cmux-subsessions__start_session",
    tool: {
      id: "start",
      title: "mcp__cmux-subsessions__start_session",
      status: "completed",
      inputSummary: JSON.stringify({ name: "tests", prompt: "Run the tests" }),
      output: "Started sub-session tests (sessionId 0199a-child, depth 1).",
    },
  };
  const items = [start, command("command", "bun test")];
  const groups = toolGroups(items);
  expect(groups.some((group) => group.type === "subsession")).toBe(true);
  expect(shouldFoldToolRun(row(items), groups)).toBe(false);
});

// Consecutive thoughts in one step are one row (Leo 2026-10-20): a call a permission ask holds out
// of the transcript (permissions/askRows.ts) can leave two thoughts side by side.
test("merges consecutive thoughts into one item with their texts and summed durations", () => {
  const first: AcpmuxActivity = { kind: "thought", text: "Read the helper first.", startedAt: 1_000, endedAt: 5_000 };
  const second: AcpmuxActivity = { kind: "thought", text: "Then check the retry.", startedAt: 9_000, endedAt: 17_000 };
  const groups = toolGroups([first, second, command("c1", "ls")]);
  expect(groups).toHaveLength(2);
  expect(groups[0]).toEqual({
    type: "item",
    item: {
      kind: "thought",
      text: "Read the helper first.\n\nThen check the retry.",
      startedAt: 1_000,
      endedAt: 13_000,
    },
  });
  // A call between two thoughts keeps them apart.
  expect(toolGroups([first, command("c2", "ls"), second])).toHaveLength(3);
});

test("grouped starts stay visible before an ordinary tool in a folded run", () => {
  const starts: AcpmuxActivity[] = ["tests", "docs", "lint"].map((name) => ({
    kind: "tool",
    text: "mcp__cmux-subsessions__start_session",
    tool: {
      id: `start-${name}`,
      title: "mcp__cmux-subsessions__start_session",
      status: "completed",
      inputSummary: JSON.stringify({ name, prompt: `Run ${name}` }),
      output: `Started sub-session ${name} (sessionId ${name}-id, depth 1).`,
    },
  }));
  const items = [...starts, command("ordinary", "bun test")];
  const groups = toolGroups(items);
  expect(groups[0]?.type).toBe("subsessionGroup");
  expect(runStretches(row(items), groups)[0]).toMatchObject({ fold: false, groups: [groups[0]] });
  const html = renderToStaticMarkup(<ToolRows row={row(items)} />);
  expect(html).toContain("Started 3 sub-sessions: tests, docs, lint");
  expect(html).toContain('class="cv-disclosure__line cv-agent-activity-row"');
});
