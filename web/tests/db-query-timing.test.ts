import { afterEach, describe, expect, test } from "bun:test";
import postgres from "postgres";
import { observePostgresJsQueryTiming, setCloudDbQueryObserver, type CloudDbQueryTiming } from "../db/queryTiming";
import { recordVmRequestDbTiming, type VmRequestContext } from "../services/vms/requestContext";
import { vmDbSpanAttributes } from "../services/vms/routeHelpers";

// Review of #19982: a future stall must show whether a VM request waited for
// a pooled database connection. Every query's acquire wait (creation until
// postgres.js assigns it a statement on a connection) and duration reach the
// route span as cmux.db.* attributes.

afterEach(() => setCloudDbQueryObserver(undefined));

function fakeQuery() {
  const settled: string[] = [];
  return {
    statement: null as unknown,
    resolve: (value: unknown) => { settled.push(`resolved:${String(value)}`); },
    reject: (error: unknown) => { settled.push(`rejected:${String(error)}`); },
    then: () => { throw new Error("timing must never start the query"); },
    settled,
  };
}

describe("postgres.js query timing", () => {
  test("acquire wait runs to the statement assignment, duration to settlement", () => {
    const timings: CloudDbQueryTiming[] = [];
    setCloudDbQueryObserver(() => (timing) => timings.push(timing));
    let clock = 1_000;
    const query = fakeQuery();
    observePostgresJsQueryTiming(query, () => clock);
    clock = 1_400; // waited 400 ms for a pooled connection
    query.statement = { string: "select 1" };
    clock = 1_450;
    query.resolve("rows");
    expect(timings).toEqual([{ acquireWaitMs: 400, durationMs: 450, failed: false }]);
    expect(query.settled).toEqual(["resolved:rows"]);
  });

  test("a query that fails before it is sent counts its whole wait", () => {
    const timings: CloudDbQueryTiming[] = [];
    setCloudDbQueryObserver(() => (timing) => timings.push(timing));
    let clock = 0;
    const query = fakeQuery();
    observePostgresJsQueryTiming(query, () => clock);
    clock = 250;
    query.reject("cancelled");
    expect(timings).toEqual([{ acquireWaitMs: 250, durationMs: 250, failed: true }]);
  });

  test("without a request to attribute to, the query is left untouched", () => {
    setCloudDbQueryObserver(() => undefined);
    const query = fakeQuery();
    const resolve = query.resolve;
    observePostgresJsQueryTiming(query);
    expect(query.resolve).toBe(resolve);
  });

  test("a request's stats aggregate into route span attributes", () => {
    const context = { route: "/api/vm/[id]/stats" } as VmRequestContext;
    recordVmRequestDbTiming(context, { acquireWaitMs: 12.4, durationMs: 20, failed: false });
    recordVmRequestDbTiming(context, { acquireWaitMs: 1_800.6, durationMs: 1_900, failed: true });
    expect(vmDbSpanAttributes(context.dbStats)).toEqual({
      "cmux.db.query_count": 2,
      "cmux.db.acquire_wait_ms": 1_801,
      "cmux.db.acquire_wait_ms_total": 1_813,
      "cmux.db.query_ms_total": 1_920,
      "cmux.db.query_failed": 1,
    });
    expect(vmDbSpanAttributes(undefined)).toEqual({ "cmux.db.query_count": 0, "cmux.db.acquire_wait_ms": 0 });
  });
});

// Against a real Postgres (CMUX_TEST_PG_URL): with a one-connection pool, a
// query queued behind a 300 ms query reports that wait as its acquire wait.
const pgUrl = process.env.CMUX_TEST_PG_URL;
describe.skipIf(!pgUrl)("postgres.js query timing against a real pool", () => {
  test("a queued query's acquire wait is the time it waited for the connection", async () => {
    const timings: Array<CloudDbQueryTiming & { label: string }> = [];
    let label = "";
    setCloudDbQueryObserver(() => {
      const current = label;
      return (timing) => timings.push({ ...timing, label: current });
    });
    const sql = postgres(pgUrl!, { max: 1, prepare: false });
    try {
      label = "slow";
      const slow = sql.unsafe("select pg_sleep(0.3)");
      observePostgresJsQueryTiming(slow);
      label = "queued";
      const queued = sql.unsafe("select 1 as one");
      observePostgresJsQueryTiming(queued);
      await Promise.all([slow, queued]);
    } finally {
      await sql.end();
    }
    const queued = timings.find((timing) => timing.label === "queued");
    const slow = timings.find((timing) => timing.label === "slow");
    expect(slow?.failed).toBe(false);
    expect(queued?.failed).toBe(false);
    // The queued query was sent only after the slow one released the connection.
    expect(queued!.acquireWaitMs).toBeGreaterThan(slow!.acquireWaitMs);
    expect(queued!.acquireWaitMs).toBeGreaterThanOrEqual(slow!.durationMs - 50);
  });
});
