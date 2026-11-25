// l10n-allow-file: bench fixture chat text, not shipped UI.
// A long agent chat shaped like a real coding session, for pane-resize-drag.bench.ts: `turns` turns,
// each a prompt, the turn's tool calls (reads, searches, test runs, a thought, and every sixth turn
// an edit with its diff), a Markdown reply and the turn's summary. The replies rotate through five
// shapes so the chat holds what a person's long chat holds: headings, bullet and numbered lists,
// nested lists, fenced code (TypeScript, Rust, shell), GitHub tables of 3 to 5 columns and inline
// code. Every turn's text carries its number, so no cache keyed on content repeats across turns
// (what makes a 700-turn chat cost 700 turns, not 5).
//
// syntheticRows (src/agent-session/acpmux/synthetic.ts) is the transcript benches' usual fixture,
// but it has no tables, no tool rows and no diffs, and its replies are one to five sentences, so a
// drag beside it measures a far lighter chat than the one Leo recorded (2026-11-18, 700 turns).
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";

const SECOND = 1_000;
/// About how long a turn takes, for the rows' times (a turn every 90 s).
const TURN_MS = 90 * SECOND;

const lines = (count: number, line: (index: number) => string) =>
  Array.from({ length: count }, (_, index) => line(index)).join("\n");

const FILES = [
  "src/net/fetchWithRetry.ts",
  "src/agent/transcript/layout.ts",
  "src/agent/composer/field.tsx",
  "cmux-tui/src/session/store.rs",
  "src/settings/schema.ts",
  "src/ui/VirtualList.tsx",
  "scripts/ci/run-tests.sh",
  "src/pages/history/HistoryScreen.tsx",
];
const fileOf = (turn: number, shift = 0) => FILES[(turn + shift) % FILES.length]!;

/// A TypeScript module of `count` lines that varies with `turn` (diffs and code blocks).
function tsSource(turn: number, count: number, variant = 0): string {
  return lines(count, (index) => {
    const n = turn * 31 + index + variant * 7;
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

function rustSource(turn: number, count: number): string {
  return lines(count, (index) => {
    const n = turn * 17 + index;
    switch (index % 5) {
      case 0:
        return `pub fn record_${n}(store: &mut SessionStore, seq: u64) -> Result<(), StoreError> {`;
      case 1:
        return `    let entry = store.entries.get(&seq).ok_or(StoreError::Missing(seq + ${n % 23}))?;`;
      case 2:
        return `    store.index.insert(entry.id.clone(), seq); // turn ${turn}`;
      case 3:
        return "    Ok(())";
      default:
        return "}";
    }
  });
}

/// A GitHub table of `columns` columns and `rows` rows, its cells varying with `turn`.
function table(turn: number, columns: number, rows: number): string {
  const heads = ["Case", "Before (ms)", "After (ms)", "Rows", "Notes"].slice(0, columns);
  const head = `| ${heads.join(" | ")} |`;
  const rule = `| ${heads.map((_, index) => (index === 0 ? "---" : "---:")).join(" | ")} |`;
  const body = Array.from({ length: rows }, (_, row) => {
    const n = turn * 7 + row;
    const cells = [
      `\`case-${n}\` ${["cold open", "warm switch", "resize drag", "scroll up", "stream"][row % 5]}`,
      String(((n * 37) % 900) + 40),
      String(((n * 13) % 120) + 8),
      String(((n * 101) % 9000) + 100),
      ["within budget", "**over budget**", "flaky on WebKit", "needs a second run", "fixed in this turn"][n % 5],
    ];
    return `| ${cells.slice(0, columns).join(" | ")} |`;
  });
  return [head, rule, ...body].join("\n");
}

/// The turn's Markdown reply, one of five shapes, all with the turn's number in them.
function reply(turn: number): string {
  const file = fileOf(turn);
  const prose = (count: number) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index + 1} of turn ${turn}: the change in \`${file}\` keeps the ${["layout", "retry", "index", "cache"][index % 4]} ` +
        `path O(rows in view) instead of O(rows), so a chat of ${turn * 10 + 300} rows pays the same per frame as a short one. ` +
        "It also keeps the existing callers working without a migration, and the tests below cover both the old and the new shape.",
    ).join("\n\n");
  switch (turn % 5) {
    case 0:
      return [
        `## Turn ${turn}: what changed`,
        prose(2),
        "- Moved the measuring out of the render path",
        `- Cached prepared text per row (turn ${turn})`,
        "- Kept the anchor row in place while the width changes",
        "- Added a regression test for the narrow pane",
        "```ts",
        tsSource(turn, 12 + (turn % 18)),
        "```",
        table(turn, 4, 6),
        `The numbers above are from turn ${turn}'s run; the over-budget case is the one the next turn looks at.`,
      ].join("\n\n");
    case 1:
      return [
        prose(3),
        `1. Read \`${file}\` and its callers\n2. Found the second pass in turn ${turn}\n3. Removed it and re-ran the suite\n4. Checked the narrow pane by hand`,
      ].join("\n\n");
    case 2:
      return [
        `### Results for turn ${turn}`,
        table(turn, 3, 10),
        `Everything except \`case-${turn * 7 + 1}\` is within budget. ${prose(1)}`,
      ].join("\n\n");
    case 3:
      return `Done: turn ${turn} only needed a one-line fix in \`${file}\`, and the tests pass.`;
    default:
      return [
        `## Plan for turn ${turn}`,
        `- Measure first\n  - p50, p95 and the longest frame\n  - before and after on the same runner\n- Then fix the slowest step (\`${file}\`)\n  - keep the fix O(1) per frame\n- Re-run the bench`,
        "```bash",
        `bun bench/pane-resize-drag.bench.ts --turns=${turn + 100} --engines=chromium\ncmux-ci test -- bun run check:pieces\ngit log --oneline -5 -- ${file}`,
        "```",
        prose(1),
        table(turn, 5, 4),
        "```rust",
        rustSource(turn, 8 + (turn % 10)),
        "```",
      ].join("\n\n");
  }
}

function prompt(turn: number): string {
  if (turn % 9 === 4)
    return (
      `Turn ${turn}: the resize is still slow when the chat is narrow. Here is what I see:\n\n` +
      "```\n" +
      lines(6, (index) => `frame ${turn * 6 + index}: ${((turn + index) * 37) % 900} ms`) +
      "\n```\n\n" +
      `Can you find which step in \`${fileOf(turn)}\` is taking the time, and fix it without changing what the pane shows?`
    );
  if (turn % 4 === 1)
    return `Turn ${turn}: look at ${fileOf(turn)} and ${fileOf(turn, 3)}. Why does item ${turn % 97} move when the width changes, and what would it take to keep it still?`;
  return `Turn ${turn}: next, check item ${turn % 97} in ${fileOf(turn)}.`;
}

/// The turn's tool calls: two to six of read, search, test run, thought and (every sixth turn) edit.
function activity(turn: number, at: number): AcpmuxActivity[] {
  const file = fileOf(turn);
  const id = (name: string) => `long-${turn}-${name}`;
  const shell = (name: string, description: string, command: string, output: string, n: number): AcpmuxActivity => ({
    kind: "tool",
    text: command,
    tool: {
      id: id(name),
      title: command,
      kind: "execute",
      status: "completed",
      description,
      command,
      output,
      exitCode: 0,
      startedAt: at + (4 + n * 3) * SECOND,
      endedAt: at + (5 + n * 3) * SECOND,
    },
  });
  const items: AcpmuxActivity[] = [
    {
      kind: "tool",
      text: `Read ${file}`,
      tool: {
        id: id("read"),
        title: `Read ${file}`,
        kind: "read",
        status: "completed",
        inputSummary: file,
        output: tsSource(turn, 10, 1),
        startedAt: at + 2 * SECOND,
        endedAt: at + 3 * SECOND,
      },
    },
    shell(
      "search",
      `Find callers of step${turn * 31}`,
      `rg -n 'step${turn * 31}' src`,
      lines(
        3 + (turn % 5),
        (index) => `${fileOf(turn, index)}:${(turn * 7 + index * 13) % 400}:  step${turn * 31}(input);`,
      ),
      1,
    ),
  ];
  if (turn % 4 === 0)
    items.push({
      kind: "thought",
      text: `Turn ${turn}: the second measure pass only runs when the width holds, so the cost should be in the settle, not the drag frames. Check whether it walks every row.`,
      startedAt: at + 10 * SECOND,
      endedAt: at + 16 * SECOND,
    });
  if (turn % 3 !== 2)
    items.push(
      shell(
        "test",
        "Run the transcript tests",
        "bun test src/agent/transcript",
        lines(3 + (turn % 10), (index) => `✓ layout case ${turn}.${index} [${(turn + index) % 40}.${index}ms]`) +
          `\n\n${12 + (turn % 30)} pass\n0 fail\n`,
        2,
      ),
    );
  if (turn % 6 === 3) {
    const before = tsSource(turn, 20 + (turn % 40));
    const after = tsSource(turn, 20 + (turn % 40), 1);
    items.push({
      kind: "tool",
      text: "Edit",
      tool: {
        id: id("edit"),
        title: `Edit ${file.split("/").pop()}`,
        kind: "edit",
        status: "completed",
        diffs: [{ path: `/workspace/${file}`, oldText: before, newText: after, line: 1 }],
        startedAt: at + 20 * SECOND,
        endedAt: at + 21 * SECOND,
      },
    });
  }
  if (turn % 5 === 0) items.push(shell("status", "Check the branch is clean", "git status --short", ` M ${file}\n`, 3));
  return items;
}

/// The chat: `turns` turns, oldest first, ending `TURN_MS` before `now`.
export function longChatRows(turns: number, now = Date.now()): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  const start = now - (turns + 1) * TURN_MS;
  for (let turn = 0; turn < turns; turn += 1) {
    const at = start + turn * TURN_MS;
    const items = activity(turn, at);
    rows.push(
      { id: `long-user-${turn}`, version: 1, at, kind: "user", text: prompt(turn) },
      {
        id: `long-activity-${turn}`,
        version: 1,
        at: at + 2 * SECOND,
        kind: "activity",
        toolCount: items.filter((item) => item.kind === "tool").length,
        items,
      },
      { id: `long-reply-${turn}`, version: 1, at: at + 40 * SECOND, kind: "assistant", text: reply(turn) },
      {
        id: `long-end-${turn}`,
        version: 1,
        at: at + 42 * SECOND,
        kind: "turnSummary",
        durationMs: 42 * SECOND,
        toolCount: items.filter((item) => item.kind === "tool").length,
        status: "completed",
      },
    );
  }
  return rows;
}
