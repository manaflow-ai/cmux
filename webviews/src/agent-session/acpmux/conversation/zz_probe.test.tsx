// l10n-allow-file: probe
import { afterAll, beforeAll, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
beforeAll(() => {
  delete globalThis.cmuxExperiments;
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
        .map(
          (r) =>
            `${r.kind}:${r.id}${r.foldOpen ? "(open)" : ""}${r.backgroundRun ? "[" + r.backgroundRun.rows.length + " f" + r.backgroundRun.failed + "]" : ""}`,
        ),
    ),
  );
const before = (burst: AcpmuxRow[]): AcpmuxRow[] => {
  const r = steered([]);
  r.splice(4, 0, ...burst.map((b) => ({ ...b, at: START + 200_000 + b.at - START - 400_000 })));
  return r;
};
test("probe", () => {
  dump("B5failed", before(Array.from({ length: 5 }, (_, i) => ended(i, "failed"))));
  dump(
    "Bmixed",
    before([ended(0, "completed"), ended(1, "failed"), ended(2, "completed"), ended(3, "failed"), ended(4, "failed")]),
  );
  dump(
    "Bmixed2",
    before([ended(0, "completed"), ended(1, "failed"), ended(3, "failed"), ended(4, "failed"), ended(2, "completed")]),
  );
  dump("5disc", steered(Array.from({ length: 5 }, (_, i) => ended(i, "disconnected"))));
  dump("5failed", steered(Array.from({ length: 5 }, (_, i) => ended(i, "failed"))));
  dump(
    "mixed",
    steered([ended(0, "completed"), ended(1, "failed"), ended(2, "completed"), ended(3, "failed"), ended(4, "failed")]),
  );
  dump(
    "mixed2",
    steered([ended(0, "completed"), ended(1, "failed"), ended(3, "failed"), ended(4, "failed"), ended(2, "completed")]),
  );
  dump("1failed", steered([ended(0, "failed")]));
  dump("steerbetween", [
    ...steered([ended(0, "failed"), ended(1, "failed")]),
    row("s-2", "user", 450, { text: "stop", steer: "landed" }),
    ended(5, "failed"),
    ended(6, "failed"),
  ]);
});
