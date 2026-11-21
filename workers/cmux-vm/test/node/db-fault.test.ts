/**
 * The database fault switch (src/db/fault.ts): off by default, read only on staging, and when on it holds the picked
 * queries for its `ms` inside its window, then runs them (latency) or fails them (stall).
 */
import { Effect, Either, Layer } from "effect";
import { describe, expect, it } from "vitest";
import { faultedSqlClient, MAX_FAULT_WINDOW_MS, parseDbFault, withDbFault } from "../../src/db/fault.ts";
import { SqlClient, type SqlClientService, StoreError } from "../../src/db/sql.ts";
import { parseEnvironment } from "../../src/policy.ts";

const now = Date.now();
const fault = (over: Record<string, unknown> = {}) =>
  JSON.stringify({ mode: "stall", ms: 40, share: 1, from: now - 60_000, until: now + 60_000, ...over });

/** A database that answers one row at once and counts its queries. */
const counting = () => {
  const seen: string[] = [];
  const client: SqlClientService = {
    query: (operation) => Effect.sync(() => {
      seen.push(operation);
      return [{ ok: 1 }];
    }),
  };
  return { seen, client };
};

const timed = <A, E>(effect: Effect.Effect<A, E>) =>
  Effect.runPromise(
    Effect.gen(function* () {
      const started = performance.now();
      const result = yield* Effect.either(effect);
      return { result, ms: performance.now() - started };
    }),
  );

describe("parseDbFault", () => {
  it("is off by default: unset, empty, off and anything that does not parse", () => {
    for (const value of [undefined, "", "  ", "off", "on", "{", "[]", "null", "1"]) expect(parseDbFault(value, "staging")).toBeNull();
  });

  it("is ignored everywhere but staging, whatever ENVIRONMENT says", () => {
    expect(parseDbFault(fault(), "staging")).not.toBeNull();
    for (const environment of ["production", "preview", "local", undefined, "", "Staging", "prod", "staging "]) {
      expect(parseDbFault(fault(), parseEnvironment(environment))).toBeNull();
    }
  });

  it("reads a latency or a stall with its share and window", () => {
    expect(parseDbFault(fault({ mode: "latency", ms: 1500, share: 0.25 }), "staging")).toEqual({
      mode: "latency", ms: 1500, share: 0.25, fromMs: now - 60_000, untilMs: now + 60_000,
    });
  });

  it("refuses a value that could hold staging past what was asked", () => {
    for (const over of [
      { mode: "slow" }, { ms: 0 }, { ms: 60_001 }, { ms: 1.5 }, { ms: "40" }, { share: 0 }, { share: 1.01 }, { share: "1" },
      { from: undefined }, { until: undefined }, { until: now - 60_000 },
      { from: now, until: now + MAX_FAULT_WINDOW_MS + 1 },
    ]) {
      expect(parseDbFault(fault(over), "staging")).toBeNull();
    }
    expect(parseDbFault(fault({ from: now, until: now + MAX_FAULT_WINDOW_MS }), "staging")).not.toBeNull();
  });
});

describe("faultedSqlClient", () => {
  it("stall: holds the query for ms, then fails it as a stopped database, without running it", async () => {
    const db = counting();
    const parsed = parseDbFault(fault({ mode: "stall", ms: 40 }), "staging");
    if (parsed === null) throw new Error("fault did not parse");
    const { result, ms } = await timed(faultedSqlClient(db.client, parsed).query("countLive", "select 1", []));
    expect(ms).toBeGreaterThanOrEqual(35);
    expect(Either.isLeft(result) && result.left instanceof StoreError && result.left.operation).toBe("countLive");
    expect(Either.isLeft(result) && Reflect.get(Object(result.left.cause), "code")).toBe("FAULT_STALL");
    expect(db.seen).toEqual([]);
  });

  it("latency: holds the query for ms, then runs it", async () => {
    const db = counting();
    const parsed = parseDbFault(fault({ mode: "latency", ms: 40 }), "staging");
    if (parsed === null) throw new Error("fault did not parse");
    const { result, ms } = await timed(faultedSqlClient(db.client, parsed).query("record", "select 1", []));
    expect(ms).toBeGreaterThanOrEqual(35);
    expect(result).toEqual(Either.right([{ ok: 1 }]));
    expect(db.seen).toEqual(["record"]);
  });

  it("outside its window, and for queries its share does not pick, runs the query at once", async () => {
    const db = counting();
    for (const over of [{ from: now + 60_000, until: now + 120_000 }, { from: now - 120_000, until: now - 60_000 }, { share: 1e-12 }]) {
      const parsed = parseDbFault(fault({ ms: 5_000, ...over }), "staging");
      if (parsed === null) throw new Error("fault did not parse");
      const { result, ms } = await timed(faultedSqlClient(db.client, parsed).query("lookup", "select 1", []));
      expect(result).toEqual(Either.right([{ ok: 1 }]));
      expect(ms).toBeLessThan(1_000);
    }
    expect(db.seen).toEqual(["lookup", "lookup", "lookup"]);
  });
});

describe("withDbFault", () => {
  it("is the very same layer when the switch is off, so production queries never pass through it", async () => {
    const db = counting();
    const layer = Layer.succeed(SqlClient, db.client);
    expect(withDbFault(layer, parseDbFault(fault(), "production"))).toBe(layer);
    expect(withDbFault(layer, null)).toBe(layer);
  });

  it("applies an on switch to every query of the layer it wraps", async () => {
    const db = counting();
    const wrapped = withDbFault(Layer.succeed(SqlClient, db.client), parseDbFault(fault({ ms: 20 }), "staging"));
    const result = await Effect.runPromise(
      Effect.either(Effect.flatMap(SqlClient, (sql) => sql.query("countLive", "select 1", []))).pipe(Effect.provide(wrapped)),
    );
    expect(Either.isLeft(result)).toBe(true);
    expect(db.seen).toEqual([]);
  });
});
