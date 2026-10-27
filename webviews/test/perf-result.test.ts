// scripts/perf-result.mjs, the result-v1 writer of the webviews benches and perf tests
// (p12-perf-process-219): nothing without PERF_RESULT_DIR, raw samples through
// scripts/perf-lab/bench_results.py with it, and a loud failure when the writer refuses.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { perfResultDir, perfSeries, recordPerfResults } from "../scripts/perf-result.mjs";

const SHA = "c".repeat(40);
const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** The bench's environment without the lab's run variables, recording into a new folder. */
function labEnv(): Record<string, string | undefined> {
  const dir = mkdtempSync(path.join(tmpdir(), "perf-result-"));
  dirs.push(dir);
  const env: Record<string, string | undefined> = { ...process.env, PERF_RESULT_DIR: dir, PERF_LAB_SHA: SHA };
  for (const name of ["PERF_LAB_STORY", "PERF_LAB_RUN_ID", "PERF_LAB_RUN_STARTED_AT", "PERF_LAB_HOST_FILE"]) {
    delete env[name];
  }
  return env;
}

describe("perfSeries", () => {
  test("keeps finite numbers only and drops a series with none", () => {
    expect(perfSeries("web.x", "ms", [1.5, null, undefined, Number.NaN, 2])).toEqual({
      metric: "web.x",
      unit: "ms",
      better: "lower",
      samples: [1.5, 2],
    });
    expect(perfSeries("web.x", "ms", [null, Number.POSITIVE_INFINITY])).toBeUndefined();
  });
});

describe("recordPerfResults", () => {
  test("starts nothing when PERF_RESULT_DIR is unset", () => {
    const spawn = () => {
      throw new Error("spawned");
    };
    expect(perfResultDir({ PERF_RESULT_DIR: " " })).toBeUndefined();
    expect(
      recordPerfResults(
        { story: "webviews", engine: "none", series: [perfSeries("web.x", "ms", [1])] },
        { env: {}, spawn: spawn as never },
      ),
    ).toBeUndefined();
  });

  test("writes one result-v1 line per series, all in one run", () => {
    const env = labEnv();
    const written = recordPerfResults(
      {
        story: "webviews",
        engine: "none",
        series: [
          perfSeries("web.ordered_rows.snapshot", "ms", [0.25, 0.5]),
          perfSeries("web.ordered_rows.turn_view", "ms", []),
          perfSeries("web.settings.toggle.bool.settings_list_reads", "count", [1, 2]),
        ],
      },
      { env },
    );
    expect(readdirSync(env.PERF_RESULT_DIR!)).toEqual([path.basename(written!)]);
    const lines = readFileSync(written!, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(lines.map((line) => [line.schema, line.story, line.metric, line.samples, line.build.sha])).toEqual([
      ["cmux-perf-result/v1", "webviews", "web.ordered_rows.snapshot", [0.25, 0.5], SHA],
      ["cmux-perf-result/v1", "webviews", "web.settings.toggle.bool.settings_list_reads", [1, 2], SHA],
    ]);
    expect(new Set(lines.map((line) => line.run.id)).size).toBe(1);
    expect(lines[0].host.display_hz).toBeNull();
  });

  test("the lab's story replaces the bench's own", () => {
    const env = { ...labEnv(), PERF_LAB_STORY: "webviews-chromium" };
    const written = recordPerfResults(
      { story: "webviews", engine: "chromium", series: [perfSeries("web.diff_paint.mixed.first_row", "ms", [400])] },
      { env },
    );
    expect(JSON.parse(readFileSync(written!, "utf8")).story).toBe("webviews-chromium");
  });

  test("throws when nothing is left to record or the writer refuses", () => {
    const env = labEnv();
    expect(() => recordPerfResults({ story: "webviews", engine: "none", series: [undefined] }, { env })).toThrow(
      "no samples",
    );
    expect(() =>
      recordPerfResults({ story: "webviews", engine: "none", series: [perfSeries("web.x", "frames", [1])] }, { env }),
    ).toThrow("was not recorded");
    expect(readdirSync(env.PERF_RESULT_DIR!)).toEqual([]);
  });
});
