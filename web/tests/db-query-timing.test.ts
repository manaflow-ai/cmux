import { afterEach, describe, expect, test } from "bun:test";
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

// Against a real Postgres (the web-database-tests CI job sets CMUX_DB_TEST=1
// and DATABASE_URL; locally, point DATABASE_URL at any scratch database).
// Through cloudDb(), so the postgres.js wrapper that tags, cancels and times
// queries (installPostgresJsQueryCancellation) is what is exercised: with a
// one-connection pool, a query queued behind a 300 ms query reports that wait
// as its acquire wait, and a query whose signal aborts is still cancelled.
const runDbTests = process.env.CMUX_DB_TEST === "1";
(runDbTests ? describe : describe.skip)("postgres.js query timing through cloudDb()", () => {
  // postgres.js pipelines plain queries onto open connections, so a query
  // waits for a connection only while every connection is reserved: by a
  // transaction, as a continuation's would be. That wait is what is measured.
  test("a query waiting behind a transaction that holds the only connection is sent after the transaction ends", async () => {
    const savedPoolMax = process.env.CMUX_DB_POOL_MAX;
    process.env.CMUX_DB_POOL_MAX = "1";
    const { cloudDb, closeCloudDbForTests } = await import("../db/client");
    const { sql } = await import("drizzle-orm");
    const settled: Array<CloudDbQueryTiming & { order: number }> = [];
    let transactionHolds: () => void = () => {};
    const holding = new Promise<void>((resolve) => { transactionHolds = resolve; });
    setCloudDbQueryObserver(() => (timing) => { settled.push({ ...timing, order: settled.length }); });
    try {
      await cloudDb().execute(sql`select 1 as warm`);
      settled.length = 0;
      let releaseTransaction: () => void = () => {};
      const released = new Promise<void>((resolve) => { releaseTransaction = resolve; });
      const transaction = cloudDb().transaction(async (tx) => {
        await tx.execute(sql`select 1 as inside_transaction`);
        transactionHolds();
        await released;
      });
      // The transaction now holds the pool's only connection.
      await holding;
      // `.then` starts the query now, while the transaction still holds the connection.
      const queued = cloudDb().execute(sql`select 1 as queued_behind_transaction`).then((rows) => rows);
      const queuedTimingIndex = settled.length;
      releaseTransaction();
      await Promise.all([transaction, queued]);
      // BEGIN, the statement inside, COMMIT, then the queued query: it was
      // sent only after the transaction gave the connection back.
      expect(settled.slice(queuedTimingIndex)).toHaveLength(2);
      const queuedTiming = settled.at(-1)!;
      expect(queuedTiming.failed).toBe(false);
      expect(queuedTiming.order).toBe(settled.length - 1);
      expect(queuedTiming.acquireWaitMs).toBeGreaterThan(0);
    } finally {
      await closeCloudDbForTests();
      if (savedPoolMax === undefined) delete process.env.CMUX_DB_POOL_MAX;
      else process.env.CMUX_DB_POOL_MAX = savedPoolMax;
    }
  });

  test("the timing hook leaves query cancellation working", async () => {
    const { cloudDb, closeCloudDbForTests } = await import("../db/client");
    const { runWithCloudDbQuerySignal } = await import("../db/queryScope");
    const { sql } = await import("drizzle-orm");
    const timings: CloudDbQueryTiming[] = [];
    setCloudDbQueryObserver(() => (timing) => timings.push(timing));
    const controller = new AbortController();
    try {
      // Aborted at once: the wrapper cancels the query whether postgres.js has
      // queued it or already sent it.
      const running = runWithCloudDbQuerySignal(controller.signal, async () => await cloudDb().execute(sql`select pg_sleep(5) as cancellation_probe`));
      controller.abort();
      expect(await running.then(() => "resolved", () => "rejected")).toBe("rejected");
    } finally {
      await closeCloudDbForTests();
    }
    expect(timings.at(-1)?.failed).toBe(true);
  }, 15_000);
});
