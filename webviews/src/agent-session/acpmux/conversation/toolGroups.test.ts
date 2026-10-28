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
const item = (tool: Omit<Tool, "id" | "status"> & { status?: string }): AcpmuxActivity => {
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

test("nonmutating read search fetch and MCP tools preserve recorded message bodies", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/observed.md <<'EOF'\nrecorded body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const send = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/observed.md",
    startedAt: 5,
    endedAt: 6,
  });
  const observers = [
    { title: "Read", kind: "read", locations: [{ path: "/tmp/observed.md" }] },
    { title: "Search", kind: "search" },
    { title: "Fetch", kind: "fetch" },
    { title: "mcp__fs__read_file", kind: "read", inputSummary: JSON.stringify({ path: "/tmp/observed.md" }) },
    {
      title: "github.search_issues call",
      kind: "search",
      inputSummary: JSON.stringify({ server: "github", tool: "search_issues", arguments: { q: "bug" } }),
    },
  ];
  for (const observer of observers) {
    // A read that failed or is still running cannot overwrite the file or block an ordered writer.
    for (const status of ["completed", "failed", "in_progress"]) {
      const read = item({ ...observer, status });
      const group = toolGroups([writer, read, send]).find((entry) => entry.type === "send");
      expect(group?.type).toBe("send");
      if (group?.type === "send") expect(group.send.text).toBe("recorded body\n");
      const later = { ...writer, tool: { ...writer.tool!, startedAt: 3, endedAt: 4 } };
      const after = toolGroups([writer, read, later, send]).find((entry) => entry.type === "send");
      expect(after?.type).toBe("send");
      if (after?.type === "send") expect(after.send.text).toBe("recorded body\n");
    }
  }
});

test("kindless observational MCP calls preserve recorded bodies without trusting read substrings", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/mcp-read.md <<'EOF'\nrecorded MCP body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const send = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/mcp-read.md",
    startedAt: 5,
    endedAt: 6,
  });
  for (const name of ["read_file", "list_files", "search_files", "get_file"]) {
    for (const fields of [
      { title: `mcp__fs__${name}`, inputSummary: JSON.stringify({ path: "/tmp/mcp-read.md" }) },
      {
        title: `fs.${name} call`,
        inputSummary: JSON.stringify({ server: "fs", tool: name, arguments: { path: "/tmp/mcp-read.md" } }),
      },
    ]) {
      const observer = item(fields);
      const group = toolGroups([writer, observer, send]).find((entry) => entry.type === "send");
      expect(group?.type).toBe("send");
      if (group?.type === "send") {
        try {
          expect(group.send.text).toBe("recorded MCP body\n");
        } catch (error) {
          throw new Error(`${fields.title} (${name}): ${String(error)}`);
        }
      }
    }
  }
  for (const fields of [
    ...[
      "write_readme",
      "update_read_file",
      "thread_read",
      "readwrite_file",
      "read_and_write",
      "search_and_delete",
      "read_and_message",
      "run",
    ].map((name) => ({
      title: `mcp__fs__${name}`,
    })),
    { title: "mcp__fs__read_file", kind: "edit" },
    { title: "mcp__fs__read_file", diffs: [{ path: "/tmp/mcp-read.md", newText: "changed" }] },
    { title: "mcp__fs__read_file", command: "truncate -s 0 /tmp/mcp-read.md" },
  ]) {
    const mutation = item({ ...fields, startedAt: 3, endedAt: 4 });
    const group = toolGroups([writer, mutation, send]).find((entry) => entry.type === "send");
    expect(group?.type).toBe("send");
    if (group?.type === "send") expect(group.send.text).toBeUndefined();
  }
});

test("a mutating MCP name overrides observational ACP kinds for recorded message bodies", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/mislabeled-mcp.md <<'EOF'\nrecorded old body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const send = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/mislabeled-mcp.md",
    startedAt: 5,
    endedAt: 6,
  });
  for (const kind of ["read", "search", "fetch"])
    for (const name of ["write_file", "read_and_write", "delete_file", "read_file"])
      for (const fields of [
        { title: `mcp__fs__${name}`, inputSummary: JSON.stringify({ path: "/tmp/mislabeled-mcp.md" }) },
        {
          title: `fs.${name} call`,
          inputSummary: JSON.stringify({
            server: "fs",
            tool: name,
            arguments: { path: "/tmp/mislabeled-mcp.md" },
          }),
        },
      ]) {
        const call = item({ ...fields, kind, startedAt: 3, endedAt: 4 });
        const group = toolGroups([writer, call, send]).find((entry) => entry.type === "send");
        expect(group?.type).toBe("send");
        if (group?.type === "send") {
          try {
            expect(group.send.text).toBe(name === "read_file" ? "recorded old body\n" : undefined);
          } catch (error) {
            throw new Error(`${kind} ${name}: ${String(error)}`);
          }
        }
      }
});

test("mutation capable and ambiguous tools still invalidate recorded message bodies", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/observed.md <<'EOF'\nstale body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const send = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send lane - < /tmp/observed.md",
    startedAt: 5,
    endedAt: 6,
  });
  const mutations = [
    ...["write", "edit", "delete", "move", "fileChange", "execute", "think", "other", undefined].map((kind) => ({
      title: "Possible mutation",
      kind,
    })),
    { title: "Read with changes", kind: "read", diffs: [{ path: "/tmp/observed.md", newText: "changed" }] },
    { title: "Read with shell input", kind: "read", command: "truncate -s 0 /tmp/observed.md" },
    { title: "mcp__fs__write_file", kind: "edit" },
    { title: "mcp__fs__write_file", kind: "other" },
    { title: "Bash", kind: "execute", command: "false && cat > /tmp/observed.md <<'EOF'\nskipped\nEOF" },
  ];
  for (const mutation of mutations) {
    for (const status of ["completed", "failed", "in_progress"]) {
      const tool = item({ ...mutation, status, startedAt: 3, endedAt: 4 });
      const group = toolGroups([writer, tool, send]).find((entry) => entry.type === "send");
      expect(group?.type).toBe("send");
      if (group?.type === "send") expect(group.send.text).toBeUndefined();
    }
  }
});

test("wrapped sends retain a prior same-turn recorded message body", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/wrapped.md <<'EOF'\nwrapped body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  for (const command of [
    "reach box acpmux send lane - < /tmp/wrapped.md",
    "bash -c 'acpmux send lane - < /tmp/wrapped.md'",
    "bash -c 'acpmux send lane -' < /tmp/wrapped.md",
    `reach box "bash -c 'acpmux send lane -'" < /tmp/wrapped.md`,
  ]) {
    const send = item({ title: "Bash", kind: "execute", command, startedAt: 3, endedAt: 4 });
    const group = toolGroups([writer, send]).find((entry) => entry.type === "send");
    expect(group?.type).toBe("send");
    if (group?.type === "send") expect(group.send.text).toBe("wrapped body\n");
  }
});

test("reach keeps remote file paths separate from locally opened recorded stdin", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/shared.md <<'EOF'\nlocal body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  for (const command of [
    "reach box 'acpmux send lane - < /tmp/shared.md'",
    `reach box "bash -c 'acpmux send lane - < /tmp/shared.md'"`,
    "reach box 'acpmux send lane - < /tmp/shared.md' < /tmp/shared.md",
    `bash -c "reach box 'acpmux send lane - < /tmp/shared.md'"`,
  ]) {
    const send = item({ title: "Bash", kind: "execute", command, startedAt: 3, endedAt: 4 });
    const group = toolGroups([writer, send]).find((entry) => entry.type === "send");
    expect(group?.type).toBe("send");
    if (group?.type === "send") expect(group.send.text).toBeUndefined();
  }
  for (const [command, text] of [
    ["reach box 'acpmux send lane -' < /tmp/shared.md", "local body\n"],
    ["reach box 'acpmux send lane -' <<'EOF'\nlocal stream\nEOF", "local stream\n"],
    ["reach box \"acpmux send lane - <<'EOF'\nremote literal\nEOF\"", "remote literal\n"],
  ]) {
    const send = item({ title: "Bash", kind: "execute", command, startedAt: 3, endedAt: 4 });
    const group = toolGroups([writer, send]).find((entry) => entry.type === "send");
    expect(group?.type).toBe("send");
    if (group?.type === "send") expect(group.send.text).toBe(text);
  }
});

test("bare cat pipelines forward inherited wrapper stdin and preserve the producer", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/pipeline.md <<'EOF'\nforwarded body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  for (const command of [
    "bash -c 'cat | acpmux send lane -' < /tmp/pipeline.md",
    "reach box 'cat | acpmux send lane -' < /tmp/pipeline.md",
    "bash -c 'cat | cat | acpmux send lane -' < /tmp/pipeline.md",
    `reach box "bash -c 'cat | acpmux send lane -'" < /tmp/pipeline.md`,
  ]) {
    const send = item({ title: "Bash", kind: "execute", command, startedAt: 3, endedAt: 4 });
    const after = item({
      title: "Bash",
      kind: "execute",
      command: "acpmux send after - < /tmp/pipeline.md",
      startedAt: 5,
      endedAt: 6,
    });
    const groups = toolGroups([writer, send, after]).filter((entry) => entry.type === "send");
    expect(groups.map((group) => group.send.text)).toEqual(["forwarded body\n", "forwarded body\n"]);
  }
  for (const command of [
    "bash -c 'cat 0<&- | acpmux send lane -' < /tmp/pipeline.md",
    "bash -c 'cat > /tmp/pipeline.md | acpmux send lane -' < /tmp/pipeline.md",
    "bash -c 'cat /tmp/other | acpmux send lane -' < /tmp/pipeline.md",
    "bash -c 'cat < /tmp/other | acpmux send lane -' < /tmp/pipeline.md",
    "bash -c 'false && cat | acpmux send lane -' < /tmp/pipeline.md",
  ]) {
    const send = item({ title: "Bash", kind: "execute", command, startedAt: 3, endedAt: 4 });
    const group = toolGroups([writer, send]).find((entry) => entry.type === "send");
    expect(group?.type).toBe("send");
    if (group?.type === "send") expect(group.send.text).toBeUndefined();
  }
});

test("quoted Markdown links and braces remain recorded message content", () => {
  const body = '[review](https://example.com)\n{"result":"pass"}\n';
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: `cat > /tmp/markdown.md <<'EOF'\n${body}EOF`,
    startedAt: 1,
    endedAt: 2,
  });
  const direct = item({
    title: "Bash",
    kind: "execute",
    command: `acpmux send direct '[review](https://example.com) {pass}'`,
    startedAt: 3,
    endedAt: 4,
  });
  const file = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send file - < /tmp/markdown.md",
    startedAt: 5,
    endedAt: 6,
  });
  const sends = toolGroups([writer, direct, file]).filter((entry) => entry.type === "send");
  expect(sends.map((group) => group.send.text)).toEqual(["[review](https://example.com) {pass}", body]);
});

test("successive sends retain a recorded body until a later uncertain mutation", () => {
  const writer = item({
    title: "Bash",
    kind: "execute",
    command: "cat > /tmp/reused.md <<'EOF'\nreused body\nEOF",
    startedAt: 1,
    endedAt: 2,
  });
  const sends = [
    "acpmux send first - < /tmp/reused.md",
    "bash -c 'acpmux send second - < /tmp/reused.md'",
    "reach box 'acpmux send third -' < /tmp/reused.md",
    "acpmux send fourth - < /tmp/reused.md",
  ].map((command, index) =>
    item({ title: "Bash", kind: "execute", command, startedAt: index * 2 + 3, endedAt: index * 2 + 4 }),
  );
  const groups = toolGroups([writer, ...sends]).filter((entry) => entry.type === "send");
  expect(groups.map((group) => group.send.text)).toEqual(Array(4).fill("reused body\n"));
  const after = item({
    title: "Bash",
    kind: "execute",
    command: "acpmux send after - < /tmp/reused.md",
    startedAt: 13,
    endedAt: 14,
  });
  for (const command of [
    "bash -c 'acpmux send unsafe - < /tmp/reused.md' > /tmp/reused.md",
    "bash -c 'acpmux send unsafe - > /tmp/reused.md' < /tmp/reused.md",
    "bash -c 'true || acpmux send unsafe -' < /tmp/reused.md",
  ]) {
    const unsafe = item({ title: "Bash", kind: "execute", command, startedAt: 11, endedAt: 12 });
    const invalidated = toolGroups([writer, ...sends, unsafe, after]).filter((entry) => entry.type === "send");
    expect(invalidated.slice(-2).map((group) => group.send.text)).toEqual([undefined, undefined]);
  }
  for (const fields of [{ status: "failed" }, { exitCode: 1 }, { startedAt: undefined }, { startedAt: 1 }]) {
    const uncertain = item({
      title: "Bash",
      kind: "execute",
      command: "acpmux send uncertain - < /tmp/reused.md",
      startedAt: 11,
      endedAt: 12,
      ...fields,
    });
    const groups = toolGroups([writer, ...sends, uncertain, after]).filter((entry) => entry.type === "send");
    expect(groups.at(-1)?.send.text).toBeUndefined();
  }
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

test("overlapping writer intervals invalidate bodies until a later ordered overwrite", () => {
  for (const first of [
    { endedAt: 10 },
    { endedAt: 2, background: { state: "completed", endedAt: 10 } },
    { endedAt: undefined },
  ] as const) {
    const slow = item({
      title: "Bash",
      kind: "execute",
      command: "cat > /tmp/overlap.md <<'EOF'\nslow\nEOF",
      startedAt: 1,
      ...first,
    });
    const fast = item({
      title: "Bash",
      kind: "execute",
      command: "cat > /tmp/overlap.md <<'EOF'\nfast\nEOF",
      startedAt: 3,
      endedAt: 4,
    });
    const send = item({
      title: "Bash",
      kind: "execute",
      command: "acpmux send lane - < /tmp/overlap.md",
      startedAt: 5,
      endedAt: 6,
    });
    const group = toolGroups([slow, fast, send]).find((entry) => entry.type === "send");
    expect(group?.type).toBe("send");
    if (group?.type === "send") expect(group.send.text).toBeUndefined();
    if (first.endedAt !== undefined) {
      const ordered = { ...fast, tool: { ...fast.tool!, startedAt: 11, endedAt: 12 } };
      const after = { ...send, tool: { ...send.tool!, startedAt: 13, endedAt: 14 } };
      const recovered = toolGroups([slow, fast, ordered, after]).find((entry) => entry.type === "send");
      expect(recovered?.type).toBe("send");
      if (recovered?.type === "send") expect(recovered.send.text).toBe("fast\n");
    }
  }
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

test("live immutable snapshots do not reparse on full 65 and 100 row replays", () => {
  resetRecordedMessageBodyCacheForTests();
  const rows = Array.from({ length: 100 }, (_, index) =>
    item({
      title: "Bash",
      kind: "execute",
      command: `cat > /tmp/message-${index}.md <<'EOF'\nbody ${index}\nEOF`,
      startedAt: index * 2 + 1,
      endedAt: index * 2 + 2,
    }),
  );
  toolGroups(rows.slice(0, 65));
  expect(recordedMessageBodyParseCountForTests()).toBe(65);
  toolGroups(rows.slice(0, 65));
  expect(recordedMessageBodyParseCountForTests()).toBe(65);
  toolGroups(rows);
  expect(recordedMessageBodyParseCountForTests()).toBe(100);
  // The memo follows live immutable tool snapshots without retaining them strongly.
  toolGroups(rows);
  expect(recordedMessageBodyParseCountForTests()).toBe(100);
});

test("parser memo can be reset for existing immutable snapshots", () => {
  resetRecordedMessageBodyCacheForTests();
  const rows = Array.from({ length: 65 }, (_, index) =>
    item({
      title: "Bash",
      kind: "execute",
      command: `cat > /tmp/eviction-${index}.md <<'EOF'\nbody ${index}\nEOF`,
      startedAt: index * 2 + 1,
      endedAt: index * 2 + 2,
    }),
  );
  toolGroups(rows);
  expect(recordedMessageBodyParseCountForTests()).toBe(65);
  toolGroups([rows[0]!]);
  expect(recordedMessageBodyParseCountForTests()).toBe(65);
  resetRecordedMessageBodyCacheForTests();
  toolGroups([rows[0]!]);
  expect(recordedMessageBodyParseCountForTests()).toBe(1);
});

test("unchanged streamed tool revisions reuse the lifetime-owned parser memo", () => {
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
