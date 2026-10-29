// l10n-allow-file: a debug load fixture (debug.agent_pane load_seed), never shown to a user.
// A long, heavy session for `debug.agent_pane load_seed` / `load_run` (loadDebug.ts): thousands
// of turns shaped like a real coding agent's, each with Markdown, a read, and every few turns a
// large edit diff and a long shell log, as ACP events the mock daemon (mock.ts) records and
// streams. Every turn's text differs (its number runs through it), so nothing a cache keys on
// content repeats across turns.

type Update = Record<string, unknown>;
export type LoadStep = { update: Update } | { mux: string; msg?: Record<string, unknown> };

const text = (value: string): Update => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: value },
});
const output = (value: string) => [{ type: "content", content: { type: "text", text: value } }];

const lines = (count: number, line: (index: number) => string) =>
  Array.from({ length: count }, (_, index) => line(index)).join("\n");

/// A TypeScript module of `count` lines that varies with `turn`.
export function sourceFile(turn: number, count: number): string {
  return lines(count, (index) => {
    const n = turn * 31 + index;
    switch (index % 6) {
      case 0:
        return `export function step${n}(input: Record<string, number>, limit = ${n % 97}): number {`;
      case 1:
        return `  const total = Object.values(input).reduce((sum, value) => sum + value * ${(n % 13) + 1}, 0);`;
      case 2:
        return `  if (total > limit) return Math.min(total, limit * ${(n % 7) + 2}); // clamp ${n}`;
      case 3:
        return `  console.debug("step${n}", { total, limit, label: "turn ${turn}" });`;
      case 4:
        return `  return total - ${n % 11};`;
      default:
        return "}";
    }
  });
}

/// `before` with every 9th line changed and a few lines added, as an agent's edit.
function edited(before: string, turn: number): string {
  return before
    .split("\n")
    .flatMap((line, index) =>
      index % 9 === 4
        ? [line.replace("limit", "ceiling"), `  // turn ${turn}: ceiling replaces limit at line ${index}`]
        : [line],
    )
    .join("\n");
}

/// A test run's log of `count` lines.
function shellLog(turn: number, count: number): string {
  return lines(count, (index) =>
    index % 25 === 24
      ? `\nSources/Feature${turn}/case${index}.test.ts:`
      : `✓ turn ${turn} case ${index} keeps the ${["cache", "queue", "layout", "parser"][index % 4]} stable [${((index * 7 + turn) % 50) / 10}ms]`,
  );
}

const paragraph = (turn: number) =>
  `Turn ${turn}: I read the module and the failing case. The **ceiling** check runs after the ` +
  `total, so a value past \`limit\` slipped through on the ${turn % 2 ? "second" : "first"} pass. ` +
  `I'll change the guard, keep the old name as an alias, and rerun the ${turn % 3 ? "unit" : "integration"} suite.`;

/// One finished turn: prompt, Markdown, a read with its output, every 3rd turn a large edit,
/// every 5th a long shell log, a closing answer with a list and a code block.
export function loadTurn(turn: number, opts: { diffLines?: number; logLines?: number } = {}): LoadStep[] {
  const diffLines = opts.diffLines ?? 150;
  const logLines = opts.logLines ?? 300;
  const path = `/mock/project/src/feature${turn % 40}/step${turn}.ts`;
  const before = sourceFile(turn, turn % 3 === 0 ? diffLines : 24);
  const steps: LoadStep[] = [
    { mux: "user_message", msg: { text: `Turn ${turn}: why does step ${turn} let values past the limit through?` } },
    { mux: "turn_started" },
    { update: text(paragraph(turn)) },
    {
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `load-read-${turn}`,
        kind: "read",
        title: `Read src/feature${turn % 40}/step${turn}.ts`,
        status: "completed",
        locations: [{ path }],
        content: output(sourceFile(turn, 40)),
      },
    },
  ];
  if (turn % 3 === 0)
    steps.push({
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `load-edit-${turn}`,
        kind: "edit",
        title: `Edit src/feature${turn % 40}/step${turn}.ts`,
        status: "completed",
        locations: [{ path, line: 1 }],
        content: [{ type: "diff", path, oldText: before, newText: edited(before, turn) }],
      },
    });
  if (turn % 5 === 0)
    steps.push({
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `load-test-${turn}`,
        kind: "execute",
        title: `Run bun test src/feature${turn % 40}`,
        status: "completed",
        rawInput: { command: `bun test src/feature${turn % 40}` },
        rawOutput: { exit_code: 0 },
        content: output(shellLog(turn, logLines)),
      },
    });
  steps.push(
    {
      update: text(
        `\n\nDone with turn ${turn}:\n\n- the guard compares against \`ceiling\`\n- \`limit\` stays as an alias\n` +
          `- ${turn % 5 === 0 ? "the suite passes" : "no tests needed"}\n\n` +
          "```ts\n" +
          sourceFile(turn + 1, 12) +
          "\n```\n",
      ),
    },
    { mux: "turn_result", msg: { status: "completed" } },
  );
  return steps;
}

/// The text a streamed turn sends, cut into `chunk`-character deltas by the caller.
export function streamedReply(turn: number, paragraphs: number): string {
  return Array.from({ length: paragraphs }, (_, index) =>
    index % 4 === 3
      ? "```ts\n" + sourceFile(turn * 100 + index, 10) + "\n```\n\n"
      : `${paragraph(turn * 100 + index)} See \`step${index}\` and the [notes](https://example.com/${index}).\n\n` +
        (index % 4 === 1 ? `- point ${index} one\n- point ${index} two\n- point ${index} three\n\n` : ""),
  ).join("");
}

/// A tool call the streamed turn makes mid-reply: a long log or a large edit, alternating.
export function streamedTool(
  turn: number,
  index: number,
  opts: { diffLines?: number; logLines?: number } = {},
): Update {
  const id = `load-live-${turn}-${index}`;
  if (index % 2 === 0)
    return {
      sessionUpdate: "tool_call",
      toolCallId: id,
      kind: "execute",
      title: `Run bun test live${index}`,
      status: "completed",
      rawInput: { command: `bun test live${index}` },
      rawOutput: { exit_code: 0 },
      content: output(shellLog(turn * 100 + index, opts.logLines ?? 300)),
    };
  const path = `/mock/project/src/live/step${index}.ts`;
  const before = sourceFile(turn * 100 + index, opts.diffLines ?? 150);
  return {
    sessionUpdate: "tool_call",
    toolCallId: id,
    kind: "edit",
    title: `Edit src/live/step${index}.ts`,
    status: "completed",
    locations: [{ path, line: 1 }],
    content: [{ type: "diff", path, oldText: before, newText: edited(before, turn) }],
  };
}

/// A finished `start_session` call to the cmux-subsessions server, as Claude Code records one: the
/// transcript draws it as sub-session `sessionId`'s card (conversation/SubsessionCallCard.tsx).
export function subsessionStart(index: number, sessionId: string, shortName: string): Update {
  return {
    sessionUpdate: "tool_call",
    toolCallId: `load-start-${index}`,
    kind: "other",
    title: "mcp__cmux-subsessions__start_session",
    status: "completed",
    rawInput: { prompt: `Own the ${shortName} lane`, name: shortName },
    content: output(
      `Started sub-session ${shortName} (sessionId ${sessionId}, depth 1). The user sees it under your chat in the sidebar. It works in parallel; use wait_for_sessions to get its result.`,
    ),
  };
}
