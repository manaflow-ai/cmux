// l10n-allow-file: a measurement script, not shipped.
// What one streamed record costs a long running turn: the drawn rows that come back as new objects
// (each is laid out, measured and rendered again downstream) and the time to shape and lay out.
// A coordinator's running turn holds thousands of rows (steers keep it open), so this is the work a
// token does in Leo's long chat. Run: bun src/agent-session/acpmux/conversation/liveTurnChurn.bench.ts
import type { AcpmuxRow } from "../model";
import { layoutConversation } from "../model";
import { turnViewFrom, type TurnView } from "./turns";

const sizes = (process.env.CHURN_SIZES ?? "100,1000,4000").split(",").map(Number);
const records = Number(process.env.CHURN_RECORDS ?? 60);

function runningTurn(steps: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [{ id: "prompt", version: 1, at: 1_000, kind: "user", text: "coordinate the lanes" }];
  for (let step = 0; step < steps; step += 1) {
    const at = 2_000 + step * 10;
    rows.push({ id: `reply-${step}`, version: 1, at, kind: "assistant", text: `Step ${step}: checked the lane.` });
    rows.push({
      id: `tools-${step}`,
      version: 1,
      at: at + 5,
      kind: "activity",
      items: [{ id: `call-${step}`, kind: "execute", title: `cmux-ci status ${step}`, status: "completed" }],
      toolCount: 1,
    } as unknown as AcpmuxRow);
  }
  return rows;
}

function median(values: number[]): number {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[sorted.length >> 1] ?? 0;
}

const folds = new Set<string>();
const options = (now: number) => ({ now, working: true, turnStartedAtMs: 1_000 });
const results: Record<string, unknown>[] = [];
for (const size of sizes) {
  let rows = runningTurn(size / 2);
  let view: TurnView = turnViewFrom(rows, folds, options(10_000));
  const heights = () => 40;
  let layout = layoutConversation(view.rows, 800, new Map(), heights);
  const changed: number[] = [];
  const shapeMs: number[] = [];
  const layoutMs: number[] = [];
  for (let record = 0; record < records; record += 1) {
    // One streamed token: the latest reply's text grows.
    const last = rows.length - 2;
    const reply = rows[last]!;
    rows = rows.slice();
    rows[last] = { ...reply, version: reply.version + 1, text: `${reply.text ?? ""} more` };
    const t0 = performance.now();
    const next = turnViewFrom(rows, folds, options(10_000 + record), view);
    const t1 = performance.now();
    const nextLayout = layoutConversation(next.rows, 800, new Map(), heights, undefined, {
      rows: view.rows,
      layout,
    });
    const t2 = performance.now();
    const before = new Map(view.rows.map((row) => [row.id, row]));
    changed.push(next.rows.filter((row) => before.get(row.id) !== row).length);
    shapeMs.push(t1 - t0);
    layoutMs.push(t2 - t1);
    view = next;
    layout = nextLayout;
  }
  results.push({
    rows: view.rows.length,
    changedRowsPerRecord: median(changed),
    shapeMsP50: Number(median(shapeMs).toFixed(3)),
    layoutMsP50: Number(median(layoutMs).toFixed(3)),
  });
}
console.log(JSON.stringify({ bench: "live-turn-churn", records, results }));
