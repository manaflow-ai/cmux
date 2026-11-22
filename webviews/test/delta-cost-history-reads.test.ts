// A streamed delta's per-snapshot passes read only the rows it changed: the pane runs them on every
// snapshot (a token, a running call's output update), and each read every row of the chat, so each
// update cost more as the transcript grew (bench/transcript-replay.bench.ts long log). The rows
// here count every read of their fields: the 5,000 rows before the live one are never read again.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { renderPages } from "../src/agent-session/acpmux/conversation/renderCall";
import { withoutQuietThoughts } from "../src/agent-session/acpmux/conversation/thoughts";
import { transcriptBackground } from "../src/agent-session/acpmux/summary/sessionSummary";

const row = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind: "assistant", text: id, ...extra }) as AcpmuxRow;

/// Rows that count every read of their fields: a pass that reads only the rows a delta changed
/// touches none of the history's.
function countedRows(count: number, make: (index: number) => AcpmuxRow) {
  const reads = { count: 0 };
  const rows = Array.from({ length: count }, (_, index) => {
    const source = make(index) as unknown as Record<string, unknown>;
    const counted: Record<string, unknown> = {};
    for (const key of Object.keys(source))
      Object.defineProperty(counted, key, {
        enumerable: true,
        get: () => {
          reads.count += 1;
          return source[key];
        },
      });
    return counted as unknown as AcpmuxRow;
  });
  return { rows, reads };
}

test("a streamed delta's per-snapshot passes read none of the 5,000 rows before it", () => {
  const history = countedRows(5000, (index) =>
    index % 2
      ? row(`a${index}`, { text: `reply ${index}` })
      : row(`s${index}`, {
          kind: "activity",
          text: undefined,
          items: [
            { kind: "thought", text: "Thinking" },
            {
              kind: "tool",
              text: "",
              tool: {
                id: `t${index}`,
                title: "Run bun test",
                kind: "execute",
                status: "completed",
                inputSummary: "{}",
              },
            },
          ],
        } as Partial<AcpmuxRow>),
  );
  const live = (output: string) =>
    row("live", {
      kind: "activity",
      text: undefined,
      items: [
        {
          kind: "tool",
          text: "",
          tool: { id: "run", title: "Run bun test", kind: "execute", status: "in_progress", output },
        },
      ],
    } as Partial<AcpmuxRow>);
  const passes: [string, (rows: AcpmuxRow[]) => unknown][] = [
    ["renderPages", (rows) => renderPages(rows)],
    ["transcriptBackground", (rows) => transcriptBackground(rows)],
    ["withoutQuietThoughts", (rows) => withoutQuietThoughts(rows, true)],
  ];
  for (const [name, pass] of passes) {
    pass([...history.rows, live("a")]);
    history.reads.count = 0;
    for (const output of ["a b", "a b c", "a b c d"]) pass([...history.rows, live(output)]);
    expect(history.reads.count, `${name}: history row fields read over three output updates`).toBe(0);
  }
});
