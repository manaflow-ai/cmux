// l10n-allow-file: test fixtures.
// toolGroups routes every MCP call (mcpCalls.ts mcpCall) to an MCP, message or sub-session group, so
// it draws in McpCallRows, MessageCard or SubsessionCallCard and never in ToolRow. Find in Chat relies
// on this (chatFind.ts reads MCP calls as McpCallRows draws them, every other call as ToolRow does).
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";
import { toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

let ids = 0;
const item = (tool: Omit<Tool, "id" | "status">): AcpmuxActivity => {
  const full = { id: `call-${(ids += 1)}`, status: "completed", ...tool };
  return { kind: "tool", text: full.title, tool: full };
};

const text = (value: string) => JSON.stringify({ content: [{ type: "text", text: value }] });
const KINDS = ["read", "edit", "search", "execute", "fetch", "think", "other", undefined] as const;

/// MCP calls in both harness shapes, under every tool kind a harness gives them, with the
/// locations and diffs a read or an edit carries.
function mcpCalls(): AcpmuxActivity[] {
  return KINDS.flatMap((kind) => [
    item({
      title: "mcp__fs__read_file",
      ...(kind && { kind }),
      inputSummary: JSON.stringify({ path: "/repo/a.ts" }),
      locations: [{ path: "/repo/a.ts" }],
      output: text("one"),
    }),
    item({
      title: "mcp__fs__write_file",
      ...(kind && { kind }),
      inputSummary: JSON.stringify({ path: "/repo/b.ts", content: "x" }),
      diffs: [{ path: "/repo/b.ts", oldText: "", newText: "x" }],
      output: text("wrote"),
    }),
    item({
      title: "github.search_issues call",
      ...(kind && { kind }),
      inputSummary: JSON.stringify({ server: "github", tool: "search_issues", arguments: { q: "bug" } }),
      output: text("found"),
    }),
    item({
      title: "mcp__cmux-sessions__send_to_session",
      ...(kind && { kind }),
      inputSummary: JSON.stringify({ session: "lint", text: "go" }),
      output: text("sent"),
    }),
    item({
      title: "mcp__cmux-subsessions__start_session",
      ...(kind && { kind }),
      inputSummary: JSON.stringify({ prompt: "Run the tests", name: "tests" }),
      output: "Started sub-session tests (sessionId 0199a-child, depth 1).",
    }),
  ]);
}

/// Calls that are not MCP calls, which group or stand alone between them.
function otherCalls(): AcpmuxActivity[] {
  return [
    item({ title: "Read a.ts", kind: "read", locations: [{ path: "/repo/a.ts" }], output: "one" }),
    item({ title: "ls", kind: "execute", command: "ls", output: "a.ts" }),
    item({ title: "Fetch", kind: "fetch", inputSummary: JSON.stringify({ url: "https://example.com" }) }),
  ];
}

function drawnByToolRow(groups: ReturnType<typeof toolGroups>): AcpmuxActivity[] {
  return groups.flatMap((group) => (group.type === "group" ? group.items : group.type === "item" ? [group.item] : []));
}

test("every MCP call draws in an MCP, message or sub-session card, never as a ToolRow", () => {
  const calls = mcpCalls();
  expect(calls.every((call) => mcpCall(call.tool!))).toBe(true);
  const others = otherCalls();
  // Alone, in runs of their own, and between other calls in both orders.
  const orders = [
    calls,
    calls.flatMap((call) => [call, ...others]),
    others.flatMap((other) => [other, ...calls]),
    calls.flatMap((call) => [others[0]!, call, others[1]!]),
  ];
  for (const items of orders) {
    const groups = toolGroups(items);
    expect(drawnByToolRow(groups).filter((entry) => entry.tool && mcpCall(entry.tool))).toEqual([]);
    const carded = groups.flatMap((group) =>
      group.type === "mcp" ? group.items : group.type === "message" || group.type === "subsession" ? [group.item] : [],
    );
    expect(carded).toHaveLength(items.filter((entry) => mcpCall(entry.tool!)).length);
  }
});

test("the other calls still draw as ToolRows around them", () => {
  const items = [...otherCalls(), ...mcpCalls(), ...otherCalls()];
  const drawn = drawnByToolRow(toolGroups(items));
  expect(drawn.map((entry) => entry.tool!.title).sort()).toEqual(
    ["Fetch", "Fetch", "Read a.ts", "Read a.ts", "ls", "ls"].sort(),
  );
});
