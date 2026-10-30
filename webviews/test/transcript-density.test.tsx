// The transcript hid too much (Leo, 2026-10-20: "we're swallowing up a few too many of these"): a
// run of calls in an opened "Worked for" folded under one "Used tools, ran commands" line, each
// "Ran N commands" group was closed, and an MCP call ran as `mcp__cmux-subsessions__start_session`.
// Now every group keeps its own line and lists every call, as Claude Code desktop lists a run's
// steps (no "+K more" behind the latest few), and an MCP call reads as its server and action, with the raw id kept in the opened call.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const command = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${id}`,
  tool: { id, title: "Shell", kind: "execute", status: "completed", command: `echo ${id}` },
});
const read = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "Read config.ts",
  tool: { id, title: "Read config.ts", kind: "read", status: "completed" },
});
const startSession = (status: "completed" | "in_progress" = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: "mcp__cmux-subsessions__start_session",
  tool: {
    id: "start-1",
    title: "mcp__cmux-subsessions__start_session",
    kind: "other",
    status,
    inputSummary: JSON.stringify({ name: "sidebar-drag-bugs", prompt: "Fix the sidebar drag bugs" }),
  },
});

const settledRow = (items: AcpmuxActivity[]): AcpmuxRow => ({
  id: "activity",
  version: 1,
  at: 1,
  kind: "activity",
  settled: true,
  items,
});

async function render(row: AcpmuxRow) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row} />));
}

const texts = (selector: string) => [...host.querySelectorAll(selector)].map((node) => node.textContent?.trim());

test("an ended turn's run keeps each group on its own line, with every command listed", async () => {
  const ids = ["c1", "c2", "c3", "c4", "c5", "c6", "c7"];
  const commands = ids.map(command);
  await render(settledRow([...commands, read("r1")]));
  expect(host.textContent).not.toContain("Used tools");
  expect(host.textContent).not.toContain("ran commands");
  // The group's line is open, and lists all seven commands, one step each.
  expect(host.querySelector('button.cv-tool[aria-expanded="true"]')?.textContent).toContain("7");
  expect(texts(".cv-command__line")).toEqual(ids.map((id) => `echo ${id}`));
  expect(host.querySelectorAll(".cv-steps > .cv-step")).toHaveLength(7);
  expect(host.querySelector(".cv-tool-group__more")).toBeNull();
  // The read after the commands keeps its own row.
  expect(host.textContent).toContain("Read config.ts");
});

test("a short group lists every call with no +more line", async () => {
  await render(settledRow(["c1", "c2"].map(command)));
  expect(texts(".cv-command__line")).toEqual(["echo c1", "echo c2"]);
  expect(host.querySelector(".cv-tool-group__more")).toBeNull();
});

test("an MCP call reads as what it did, with its raw id in the opened call", async () => {
  await render(settledRow([startSession()]));
  const line = host.querySelector<HTMLButtonElement>("button.cv-tool")!;
  expect(line.textContent).toBe("Started session sidebar-drag-bugs");
  // No tooltip: the line's text already shows (test/tooltip-rules.ts).
  expect(line.title).toBe("");
  await act(async () => line.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  expect(host.querySelector(".cv-mcp-call__name")?.textContent).toBe("mcp__cmux-subsessions__start_session");
});

test("a running MCP call's line names its server and action, never the raw id", async () => {
  const { toolLabel } = await import("../src/agent-session/acpmux/toolPaths");
  const { mcpTitleName } = await import("../src/agent-session/acpmux/conversation/mcpCalls");
  const { turnView, WORKING } = await import("../src/agent-session/acpmux/conversation/turns");
  const call = startSession("in_progress");
  expect(toolLabel(call.tool!, call.text, (line) => line)).toBe("cmux-subsessions · start session sidebar-drag-bugs");
  expect(mcpTitleName("mcp__cmux__list_workspaces")).toBe("cmux · list workspaces");
  expect(mcpTitleName("Read config.ts")).toBeUndefined();
  // Two calls to one tool share a closed line, so the working line is what names the running one.
  const listing = (id: string, status: "completed" | "in_progress"): AcpmuxActivity => ({
    kind: "tool",
    text: "mcp__cmux__list_workspaces",
    tool: { id, title: "mcp__cmux__list_workspaces", kind: "other", status },
  });
  const user: AcpmuxRow = { id: "u1", version: 1, at: 0, kind: "user", text: "start one" };
  const run = (items: AcpmuxActivity[]): AcpmuxRow[] => [
    user,
    { id: "a1", version: 1, at: 1, kind: "activity", items },
  ];
  const doing = (items: AcpmuxActivity[]) =>
    turnView(run(items), new Set(), { working: true }).find((row) => row.kind === WORKING)?.doing;
  expect(doing([listing("list-0", "completed"), listing("list-1", "in_progress")])).toBe("cmux · list workspaces");
  // A running sub-session start draws its own card (subsessionCalls.ts), which names it: the line
  // does not say it again.
  const earlier = { ...startSession(), tool: { ...startSession().tool!, id: "start-0" } };
  expect(doing([earlier, call])).toBeUndefined();
});
