// Lazy fixture loading must keep the debug seed's state and wait for the pane's actual commit.
import { expect, spyOn, test } from "bun:test";
import { createAcpmuxDebug } from "../src/agent-session/acpmux/debug";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { acpmuxPerf } from "../src/agent-session/acpmux/perf";

function pane() {
  let rows: AcpmuxRow[] = [];
  const debug = createAcpmuxDebug({
    replaceRows(next) {
      rows = next;
      queueMicrotask(() => acpmuxPerf.commit(0, 0, [], performance.now()));
    },
    rowCount: () => rows.length,
  });
  return { debug, rows: () => rows };
}

test("lazy subagent seeds retain their origin across steps and reset independently per pane", async () => {
  const now = spyOn(Date, "now");
  const wasEnabled = acpmuxPerf.enabled;
  const start = Date.UTC(2026, 10, 3, 12);
  try {
    now.mockReturnValue(start);
    const first = pane();
    await first.debug.seedRows(0, "subagents");
    const origin = first.rows()[0]?.at;
    expect(origin).toBe(start - 60_000);

    now.mockReturnValue(start + 10_000);
    await first.debug.seedRows(1, "subagents", 4);
    const running = first.rows().find((row) => row.id === "subagents-group")?.subagents;
    expect(running).toHaveLength(4);
    expect(running?.map((agent) => agent.state)).toEqual(["running", "running", "running", "running"]);

    now.mockReturnValue(start + 45_000);
    await first.debug.seedRows(3, "subagents", 4);
    const finished = first.rows().find((row) => row.id === "subagents-group")?.subagents;
    expect(first.rows()[0]?.at).toBe(origin);
    expect(finished?.map((agent) => agent.startedAt)).toEqual(running?.map((agent) => agent.startedAt));
    expect(finished?.map((agent) => agent.state)).toEqual(["completed", "running", "running", "running"]);

    const second = pane();
    await second.debug.seedRows(1, "subagents");
    expect(second.rows()[0]?.at).toBe(start + 45_000 - 60_000);
    expect(first.rows()[0]?.at).toBe(origin);

    now.mockReturnValue(start + 90_000);
    await first.debug.seedRows(0, "subagents");
    expect(first.rows()[0]?.at).toBe(start + 90_000 - 60_000);
    expect(first.rows().some((row) => row.id === "subagents-group")).toBe(false);
  } finally {
    now.mockRestore();
    acpmuxPerf.enabled = wasEnabled;
  }
});

test("a lazy seed finishes only after the pane commits its replacement rows", async () => {
  const wasEnabled = acpmuxPerf.enabled;
  let rows: AcpmuxRow[] = [];
  let replaced: (() => void) | undefined;
  const receivedRows = new Promise<void>((resolve) => {
    replaced = resolve;
  });
  const debug = createAcpmuxDebug({
    replaceRows(next) {
      rows = next;
      replaced?.();
    },
    rowCount: () => rows.length,
  });
  let settled = false;
  const seed = debug.seedRows(3, "short").then((result) => {
    settled = true;
    return result;
  });
  try {
    await receivedRows;
    await Promise.resolve();
    expect(rows.length).toBeGreaterThan(0);
    expect(settled).toBe(false);
    acpmuxPerf.commit(0, 0, [], performance.now());
    const result = await seed;
    expect(result.rows).toBe(rows.length);
    expect(typeof result.commit_ms).toBe("number");
  } finally {
    acpmuxPerf.commit(0, 0, [], performance.now());
    acpmuxPerf.enabled = wasEnabled;
  }
});
