// l10n-allow-file: test fixtures.
// toolGroups routes every MCP call (mcpCalls.ts mcpCall) to an MCP, message or sub-session group, so
// it draws in McpCallRows, MessageCard or SubsessionCallCard and never in ToolRow. Find in Chat relies
// on this (chatFind.ts reads MCP calls as McpCallRows draws them, every other call as ToolRow does).
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";
import { toolGroups } from "./toolGroups";
import { recordedMessageBodyParseCountForTests, resetRecordedMessageBodyCacheForTests } from "./acpmuxSends";

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

test("a later Bash send resolves only a prior same-turn recorded message write", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/review.md <<'EOF'\n## Ready\n\n- checks pass\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const send = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send --no-wait coord-deputy - < /tmp/review.md",
    output: "queued",
    startedAt: 3,
    endedAt: 4,
  });
  const group = toolGroups([writer, send]).find((entry) => entry.type === "send");
  expect(group?.type).toBe("send");
  if (group?.type === "send") {
    expect(group.send.text).toBe("## Ready\n\n- checks pass\n");
    expect(group.send.others).toBeUndefined();
  }
  const standalone = toolGroups([send]).find((entry) => entry.type === "send");
  expect(standalone?.type).toBe("send");
  if (standalone?.type === "send") expect(standalone.send.text).toBeUndefined();
});

test("a later accepted writer replaces all prior path spellings, and unknown timing drops bodies", () => {
  const first = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/a <<'EOF'\nOLD\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const alias = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /private/tmp/a <<'EOF'\nNEW\nEOF",
    startedAt: 3,
    endedAt: 4,
  });
  const send = item({ title: "Bash", kind: "execute", command: "acpmux send lane - < /tmp/a", startedAt: 5 });
  const body = toolGroups([first, alias, send]).find((entry) => entry.type === "send");
  expect(body?.type).toBe("send");
  if (body?.type === "send") expect(body.send.text).toBeUndefined();
  const unknownOrder = toolGroups([first, { ...send, tool: { ...send.tool!, startedAt: undefined } }]).find(
    (entry) => entry.type === "send",
  );
  expect(unknownOrder?.type).toBe("send");
  if (unknownOrder?.type === "send") expect(unknownOrder.send.text).toBeUndefined();

  const overlap = toolGroups([
    first,
    { ...alias, tool: { ...alias.tool!, endedAt: 8 } },
    { ...send, tool: { ...send.tool!, startedAt: 5 } },
  ]).find((entry) => entry.type === "send");
  expect(overlap?.type).toBe("send");
  if (overlap?.type === "send") expect(overlap.send.text).toBeUndefined();
});

test("background writers use their completion time for send provenance", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/background.md <<'EOF'\nfinished later\nEOF",
    startedAt: 1,
    // The foreground call ended before the background shell did.
    endedAt: 2,
    background: { state: "completed", endedAt: 10 },
  });
  const beforeBackgroundEnds = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/background.md",
    startedAt: 5,
  });
  const unresolved = toolGroups([writer, beforeBackgroundEnds]).find((entry) => entry.type === "send");
  expect(unresolved?.type).toBe("send");
  if (unresolved?.type === "send") expect(unresolved.send.text).toBeUndefined();

  const afterBackgroundEnds = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/background.md",
    startedAt: 11,
  });
  const resolved = toolGroups([writer, afterBackgroundEnds]).find((entry) => entry.type === "send");
  expect(resolved?.type).toBe("send");
  if (resolved?.type === "send") expect(resolved.send.text).toBe("finished later\n");
});

test("producer cache remains bounded across many completed writer replays", () => {
  resetRecordedMessageBodyCacheForTests();
  const rows = Array.from({ length: 65 }, (_, index) =>
    item({
      title: "Bash",
      kind: "execute",
      command: `cat > /tmp/message-${index}.md <<'EOF'\nbody ${index}\nEOF`,
      startedAt: index * 2 + 1,
      endedAt: index * 2 + 2,
    }),
  );
  toolGroups(rows);
  expect(recordedMessageBodyParseCountForTests()).toBe(65);
  toolGroups(rows.slice(1));
  // WeakMap parsing by immutable tool object keeps all unchanged revisions from replaying.
  expect(recordedMessageBodyParseCountForTests()).toBe(65);
});

test("unchanged streamed tool revisions reuse the bounded body parser cache", () => {
  resetRecordedMessageBodyCacheForTests();
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/review.md <<'EOF'\nready\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const send = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/review.md",
    startedAt: 3,
    endedAt: 4,
  });
  toolGroups([writer, send]);
  expect(recordedMessageBodyParseCountForTests()).toBe(2);
  // Streaming appends a new tool but keeps the prior tool snapshots unchanged.
  const later = item({ title: "Bash", kind: "execute", command: "echo done", startedAt: 5, endedAt: 6 });
  toolGroups([writer, send, later]);
  expect(recordedMessageBodyParseCountForTests()).toBe(3);
  toolGroups([writer, send, later]);
  expect(recordedMessageBodyParseCountForTests()).toBe(3);
  // A same-id command revision is a new cache key, so stale content cannot survive an overwrite.
  const changedWriter = { ...writer, tool: { ...writer.tool!, command: "echo replacement > /tmp/review.md" } };
  const changed = toolGroups([changedWriter, send]);
  expect(recordedMessageBodyParseCountForTests()).toBe(4);
  const changedSend = changed.find((entry) => entry.type === "send");
  expect(changedSend?.type).toBe("send");
  if (changedSend?.type === "send") expect(changedSend.send.text).toBeUndefined();

  const skippedWriter = {
    ...writer,
    tool: { ...writer.tool!, command: "true || cat > /tmp/review.md <<'EOF'\nskipped\nEOF" },
  };
  const skipped = toolGroups([writer, skippedWriter, send]).find((entry) => entry.type === "send");
  expect(skipped?.type).toBe("send");
  if (skipped?.type === "send") expect(skipped.send.text).toBeUndefined();

  const failedWriter = { ...writer, tool: { ...writer.tool!, status: "failed" } };
  const failed = toolGroups([writer, failedWriter, send]).find((entry) => entry.type === "send");
  expect(failed?.type).toBe("send");
  if (failed?.type === "send") expect(failed.send.text).toBeUndefined();
});
