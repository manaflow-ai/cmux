// The web UI perf harness lists rows slowest first relative to their target (bench/web-ui-suite.ts); a row whose
// target is 0 (a layout shift or an idle wakeup count, bench/stability.ts) is over it whenever it is above 0.
import { describe, expect, test } from "bun:test";
import {
  BENCHES,
  failureTail,
  overTarget,
  SHARED_BUILDS_CAP_MS,
  sharedEnv,
  slowestFirst,
  SUITE_CAP_MS,
} from "../bench/web-ui-suite";
import { PERF_ROW_MARK } from "../bench/perfRow";
import path from "node:path";

describe("web-ui-suite slowestFirst", () => {
  test("a target of 0 ranks above every finite ratio once missed, and with the met rows when met", () => {
    const rows = [
      { name: "a.settled", p95: 150, target: 100 },
      { name: "b.idle_wakeups", p95: 3, target: 0 },
      { name: "c.cls", p95: 0, target: 0 },
      { name: "d.long_ms", p95: 40 },
      { name: "e.latest", p95: 50, target: 100 },
    ];
    expect(slowestFirst(rows).map((row) => row.name)).toEqual([
      "b.idle_wakeups",
      "a.settled",
      "e.latest",
      "c.cls",
      "d.long_ms",
    ]);
    expect(overTarget({ name: "x", p95: 0, target: 0 })).toBe(0);
    expect(overTarget({ name: "x", p95: 1 })).toBe(-1);
  });
});

// A failed bench's report entry says why: state-growth printed its FAIL lines on stdout and nothing on stderr, and the
// suite kept only stderr, so the perf cron saw "state-growth: exit 1" with an empty tail (run 43331891010).
describe("web-ui-suite failureTail", () => {
  test("a bench that explains itself on stdout only still leaves its reason in the tail", () => {
    const stdout = [
      "chat-reopen small ops 120  FAIL",
      "  heap 4614 B/op over its band 4096",
      `${PERF_ROW_MARK}{"name":"x","p95":1}`,
      "",
    ].join("\n");
    expect(failureTail(stdout, "", [])).toEqual([
      "chat-reopen small ops 120  FAIL",
      "  heap 4614 B/op over its band 4096",
    ]);
  });

  test("malformed rows, then stdout, then stderr, each bounded", () => {
    const stdout = Array.from({ length: 20 }, (_, i) => `out ${i}`).join("\n");
    const stderr = Array.from({ length: 20 }, (_, i) => `err ${i}`).join("\n");
    const tail = failureTail(stdout, stderr, [`${PERF_ROW_MARK}{bad`]);
    expect(tail[0]).toBe(`${PERF_ROW_MARK}{bad`);
    expect(tail.slice(1, 9)).toEqual(Array.from({ length: 8 }, (_, i) => `out ${i + 12}`));
    expect(tail.slice(9)).toEqual(Array.from({ length: 12 }, (_, i) => `err ${i + 8}`));
  });
});

// A bench's timeout raised past the suite's cap would let perf-cron.py kill the whole suite with no report at all.
describe("web-ui-suite timeouts", () => {
  test("the benches the suite runs by default fit perf-cron.py's cap on it", () => {
    const sum = BENCHES.filter((bench) => !bench.ownPart).reduce((total, bench) => total + bench.timeoutMs, 0);
    expect(sum + SHARED_BUILDS_CAP_MS).toBeLessThanOrEqual(SUITE_CAP_MS);
  });
});

// Each browser bench built its page cold inside its own timeout, and on a small Linux pool runner the builds ate the
// timeouts: seven benches killed with exit 137 and no row stored (perf cron run 45457645242).
describe("web-ui-suite shared builds", () => {
  test("every bench that builds the agent pane, the fling page or the gallery takes the suite's build", () => {
    const named = (build: string) =>
      BENCHES.filter((bench) => bench.builds?.includes(build as never))
        .map((bench) => bench.name)
        .sort();
    expect(named("pane")).toEqual([
      "chat-open",
      "chat-switch",
      "thread-rail-jump",
      "tool-call-burst",
      "transcript-replay",
      "transcript-turn-end-shift",
    ]);
    expect(named("page:/test/browser/transcript-fling.html")).toEqual(["transcript-scroll-frame"]);
    expect(named("gallery")).toEqual(["ui-stability"]);
  });

  test("a bench is handed only the finished builds it names", () => {
    const bench = BENCHES.find((each) => each.name === "transcript-scroll-frame")!;
    const pane = BENCHES.find((each) => each.name === "chat-open")!;
    const dirs = new Map([["pane", "/tmp/pane"]] as const);
    expect(sharedEnv(pane, { dirs })).toEqual({ CMUX_BENCH_PANE_DIR: "/tmp/pane" });
    expect(sharedEnv(bench, { dirs })).toEqual({});
    const withPage = new Map<never, string>([["page:/test/browser/transcript-fling.html" as never, "/tmp/p/x"]]);
    expect(sharedEnv(bench, { dirs: withPage, pagesDir: "/tmp/p" })).toEqual({ CMUX_BENCH_PAGES_DIR: "/tmp/p" });
  });
});

// The nightly interaction-latency job runs one bench at a time on a slower runner and passes its own timeout.
describe("web-ui-suite --timeout-s", () => {
  test("it needs --only and a positive number", () => {
    const suite = path.join(import.meta.dir, "..", "bench", "web-ui-suite.ts");
    for (const args of [
      ["--timeout-s", "5"],
      ["--only", "edit-turns-stream", "--timeout-s", "0"],
    ]) {
      const got = Bun.spawnSync(["bun", suite, ...args], { cwd: path.join(import.meta.dir, "..") });
      expect(got.exitCode).toBe(2);
      expect(got.stderr.toString()).toContain("--timeout-s");
    }
  });

  test("a valid one replaces the bench's own timeout and names itself when it fires", () => {
    // edit-turns-stream's own timeout is 30 s; 0.01 s kills it before Bun has started it.
    const suite = path.join(import.meta.dir, "..", "bench", "web-ui-suite.ts");
    const got = Bun.spawnSync(["bun", suite, "--only", "edit-turns-stream", "--timeout-s", "0.01"], {
      cwd: path.join(import.meta.dir, ".."),
    });
    expect(got.stdout.toString()).toContain("edit-turns-stream FAILED (timed out after 0.01 s)");
  });
});
