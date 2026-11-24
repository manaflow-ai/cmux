// l10n-allow-file: probe
import { afterAll, beforeAll, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
beforeAll(() => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
});
afterAll(() => {
  delete globalThis.cmuxExperiments;
});
const START = Date.UTC(2026, 10, 24, 1, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const ended = (index: number, state: string): AcpmuxRow =>
  row(`subagentDone:a${index}`, "subagentDone", 400 + index, {
    subagents: [
      {
        id: `a${index}`,
        parent: null,
        name: `helper-${index}`,
        task: `Check lane ${index}`,
        state,
        startedAt: START,
        endedAt: START + 400_000 + index,
      } as never,
    ],
  });
const work = row("t-1", "activity", 1, {
  items: [{ kind: "tool", text: "", tool: { id: "c1", title: "bun test", kind: "execute", status: "completed" } }],
});
const steered = (burst: AcpmuxRow[]): AcpmuxRow[] => [
  row("u-0", "user", 0, { text: "Land the lanes" }),
  work,
  row("s-1", "user", 100, { text: "Also check lane 9", steer: "landed" }),
  row("a-1", "assistant", 300, { text: "Checked; lane 9 is green." }),
  row("sum", "turnSummary", 310, { status: "completed", durationMs: 310_000, toolCount: 1 }),
  ...burst,
];
const dump = (name: string, rows: AcpmuxRow[]) =>
  console.log(
    name,
    JSON.stringify(
      turnView(rows, new Set(), { agentFamily: "claude", now: START + 900_000 })
        .filter((r) => r.kind !== "date")
        .map((r) => `${r.kind}:${r.id}${r.backgroundRun ? JSON.stringify(r.backgroundRun) : ""}`),
    ),
  );
test("probe", () => {
  dump("5failed", steered(Array.from({ length: 5 }, (_, i) => ended(i, "failed"))));
  dump(
    "mixed",
    steered([ended(0, "completed"), ended(1, "failed"), ended(2, "completed"), ended(3, "failed"), ended(4, "failed")]),
  );
  dump("1failed", steered([ended(0, "failed")]));
  dump("steerbetween", [
    ...steered([ended(0, "failed"), ended(1, "failed")]),
    row("s-2", "user", 450, { text: "stop", steer: "landed" }),
    ended(5, "failed"),
    ended(6, "failed"),
  ]);
});
