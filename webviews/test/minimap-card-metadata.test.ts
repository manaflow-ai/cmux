import { expect, test } from "bun:test";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (partial: Partial<AcpmuxRow> & Pick<AcpmuxRow, "id" | "kind" | "at">): AcpmuxRow => ({
  version: 1,
  ...partial,
});

test("a minimap card keeps the turn metadata needed for a compact hover summary", () => {
  const rows: AcpmuxRow[] = [
    row({ id: "u1", kind: "user", at: 1_700_000_000_000, text: "Review https://github.com/manaflow-ai/cmux/pull/25794" }),
    row({
      id: "a1",
      kind: "activity",
      at: 1_700_000_010_000,
      items: [
        {
          kind: "tool",
          text: "edit",
          tool: {
            id: "t1",
            title: "Edit",
            status: "completed",
            diffs: [{ path: "src/App.tsx", newText: "next" }],
            locations: [{ path: "src/App.tsx" }, { path: "README.md" }],
          },
        },
      ],
    }),
    row({ id: "reply", kind: "assistant", at: 1_700_000_020_000, text: "**Ready**\n\nThe card keeps the useful Markdown preview." }),
    row({
      id: "summary",
      kind: "turnSummary",
      at: 1_700_000_042_000,
      status: "failed",
      durationMs: 42_000,
      toolCount: 3,
      error: "peer disconnected while waiting for the agent to answer",
    }),
  ];
  expect(minimapTurns(rows).turns[0]?.metadata).toEqual({
    at: 1_700_000_000_000,
    durationMs: 42_000,
    toolCount: 3,
    fileCount: 1,
    links: ["https://github.com/manaflow-ai/cmux/pull/25794"],
    failure: "peer disconnected while waiting for the agent to answer",
  });
});
