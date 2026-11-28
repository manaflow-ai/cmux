// l10n-allow-file: benchmark output, not shipped UI.
// The PERF_ROW lines (bench/perfRow.ts) of composer-typing.bench.ts's load modes (--mode L0,L1,L2,L3), which
// bench/web-ui-suite.ts collects for perf-cron.py's web-ui-typing part and `cmux-bench typing` records. Per load,
// engine and length (row prefix composer_typing.<mode>.<engine>.rows<length>):
//   invalid      1 when the load's receipt is invalid (lost or reordered keys, a stream that did not hold its rate,
//                clocks that disagree...), else 0; target 0. An invalid load prints no timing row, so a broken run
//                can never read as a fast one.
//   to_paint     DOM keydown to the paint of the key's frame (Chromium's element timing; WebKit's the after-frame
//                paint proxy; composer-load.ts): p50 of the samples, p95; target the load's
//                report-only budget_p95_ms (the app's 16 ms on its 120 Hz display, read on the harness's
//                display: 24.3 ms at 60 Hz; composer-load.ts displayBudgets).
//   to_paint_p99 its p99 as the row's value; target budget_p99_ms (33 ms on the app's display, 41.3 at 60 Hz).
// Targets are report-only: the cron lists rows over them, it never blocks a push or a pull request.
import type { PerfRow } from "./perfRow";

type LoadResult = {
  engine?: unknown;
  mode?: unknown;
  requested_rows?: unknown;
  valid?: unknown;
  to_paint_p95?: unknown;
  to_paint_p99?: unknown;
  budget_p95_ms?: unknown;
  budget_p99_ms?: unknown;
  samples?: unknown;
};

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

function median(values: number[]): number | undefined {
  if (values.length === 0) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

/// The rows of one run's table (pure). Rows without a load receipt (`valid`: the legacy idle/stream modes) print none.
export function composerTypingRows(table: readonly Record<string, unknown>[]): PerfRow[] {
  const rows: PerfRow[] = [];
  for (const result of table as readonly LoadResult[]) {
    if (typeof result.valid !== "boolean") continue;
    const prefix = `composer_typing.${String(result.mode).toLowerCase()}.${String(result.engine ?? "chromium")}.rows${String(result.requested_rows)}`;
    rows.push({
      name: `${prefix}.invalid`,
      p50: result.valid ? 0 : 1,
      p95: result.valid ? 0 : 1,
      unit: "count",
      target: 0,
      floor: 0.5,
    });
    if (!result.valid || !finite(result.to_paint_p95) || !finite(result.to_paint_p99)) continue;
    const paints = Array.isArray(result.samples)
      ? (result.samples as { paint?: unknown; painted?: unknown }[])
          .map((s) => (finite(s.painted) && s.painted >= 0 ? s.painted : s.paint))
          .filter(finite)
      : [];
    rows.push({
      name: `${prefix}.to_paint`,
      p50: median(paints) ?? result.to_paint_p95,
      p95: result.to_paint_p95,
      target: finite(result.budget_p95_ms) ? result.budget_p95_ms : 16,
    });
    rows.push({
      name: `${prefix}.to_paint_p99`,
      p50: result.to_paint_p99,
      p95: result.to_paint_p99,
      target: finite(result.budget_p99_ms) ? result.budget_p99_ms : 33,
    });
  }
  return rows;
}
