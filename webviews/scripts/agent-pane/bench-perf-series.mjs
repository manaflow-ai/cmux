// The result-v1 series of the agent pane's browser benches, apart from the
// benches so they are tested without a browser (test/perf-result.test.ts): chat-load/browser_bench.mjs
// and bench-switch-intent.mjs. A run that hit its limit is recorded at that limit and counted in a
// .timed_out series, so a regression to never finishing raises the series instead of leaving it.
import { perfSeries } from "../perf-result.mjs";

/// browser_bench run row key -> [result-v1 metric suffix, unit, factor]. bytes_in counts UTF-16
/// units, not bytes.
const CHAT_LOAD_ROW_SERIES = {
  first_paint_ms: ["first_paint", "ms", 1],
  interactive_ms: ["interactive", "ms", 1],
  pane_painted_ms: ["pane_painted", "ms", 1],
  seed_ms: ["seed", "ms", 1],
  bytes_in: ["utf16_in", "count", 1],
  requests: ["requests", "count", 1],
  dom_nodes: ["dom_nodes", "count", 1],
  daemon_cpu_ms: ["daemon_cpu", "ms", 1],
  script_ms: ["script", "ms", 1],
  layout_ms: ["layout", "ms", 1],
  style_ms: ["style", "ms", 1],
  task_ms: ["task", "ms", 1],
  heap_mb: ["heap", "bytes", 1e6],
};
const CHAT_LOAD_LATENCY_KEYS = new Set(["first_paint_ms", "interactive_ms"]);

/**
 * The series of a browser_bench page stage: each run row's numbers and the scroll to the first
 * message, under web.chat_load.{open,switch,mock}.<t<turns>|default>. A run that timed out records
 * a missing first paint and its interactive at `settleTimeoutMs` (they took at least that long),
 * counts in .timed_out, and leaves its other numbers out: they were read from a page that never
 * settled.
 * @param {{ sessions: any[], switch?: any[], mock: any[] }} results browser_bench's report
 * @param {number} settleTimeoutMs
 */
export function chatLoadPerfSeries({ sessions, switch: switches = [], mock }, settleTimeoutMs) {
  const scrollSeries = (prefix, scroll) =>
    scroll?.found
      ? [
          perfSeries(`${prefix}.scroll.wall`, "ms", [scroll.ms]),
          perfSeries(`${prefix}.scroll.utf16_in`, "count", [scroll.bytes_in]),
          perfSeries(`${prefix}.scroll.requests`, "count", [scroll.requests]),
        ]
      : [];
  const value = (run, key) => {
    const raw = typeof run[key] === "number" ? run[key] : undefined;
    if (!run.timed_out) return raw;
    return CHAT_LOAD_LATENCY_KEYS.has(key) ? (raw ?? settleTimeoutMs) : undefined;
  };
  const rowSeries = (prefix, runs) => [
    ...Object.entries(CHAT_LOAD_ROW_SERIES).map(([key, [name, unit, scale]]) =>
      perfSeries(
        `${prefix}.${name}`,
        unit,
        runs.map((run) => {
          const raw = value(run, key);
          return raw === undefined ? undefined : raw * scale;
        }),
      ),
    ),
    perfSeries(
      `${prefix}.timed_out`,
      "count",
      runs.map((run) => (run.timed_out ? 1 : 0)),
    ),
  ];
  return [
    ...sessions.flatMap((entry) => [
      ...rowSeries(`web.chat_load.open.t${entry.turns}`, entry.runs),
      ...scrollSeries(`web.chat_load.open.t${entry.turns}`, entry.scroll),
    ]),
    ...switches.flatMap((entry) => rowSeries(`web.chat_load.switch.t${entry.turns}`, entry.runs)),
    ...mock.flatMap((entry) => {
      const prefix = `web.chat_load.mock.${entry.turns === undefined ? "default" : `t${entry.turns}`}`;
      return [...rowSeries(prefix, entry.runs), ...scrollSeries(prefix, entry.scroll)];
    }),
  ];
}

/**
 * The series of bench-switch-intent's picks, one per harness asked for (`picked`), pick kind and
 * mark: harnesses are separate populations, so a regression in one is not averaged away by
 * another, and the names do not depend on --sequence. A pick that timed out records each mark it
 * was waiting for at `limitMs` and counts in .timed_out.
 * @param {ReadonlyArray<{ picked: string, kind: "first" | "repeat", timedOut?: boolean } & Record<string, unknown>>} picks
 * @param {{ prompted: boolean, limitMs: number }} options `prompted`: the run sent a prompt, so
 *   `sent` and `reply` were waited for too.
 */
export function switchIntentPerfSeries(picks, { prompted, limitMs }) {
  const marks = prompted ? ["paint", "ready", "sent", "reply"] : ["paint", "ready"];
  const at = (entry, mark) => entry[mark] ?? (entry.timedOut ? limitMs : undefined);
  const harnesses = [...new Set(picks.map((entry) => entry.picked))];
  return harnesses.flatMap((harness) =>
    ["first", "repeat"].flatMap((kind) => {
      const group = picks.filter((entry) => entry.picked === harness && entry.kind === kind);
      if (group.length === 0) return [];
      const prefix = `web.switch_intent.${harness.replace(/[^A-Za-z0-9]+/g, "_")}.${kind}`;
      return [
        ...marks.map((mark) =>
          perfSeries(
            `${prefix}.${mark}`,
            "ms",
            group.map((entry) => at(entry, mark)),
          ),
        ),
        perfSeries(
          `${prefix}.timed_out`,
          "count",
          group.map((entry) => (entry.timedOut ? 1 : 0)),
        ),
      ];
    }),
  );
}
