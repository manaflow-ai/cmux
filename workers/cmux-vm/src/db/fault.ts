/**
 * A staging-only fault switch for the database: the Cloud chaos suite's database-stall scenario (cmuxterm-hq
 * tools/cloud-chaos, scenario 5 of goals/cloud-chat-reply-rate-staging.md) turns it on to see what a slow or stalled
 * Postgres does to machine starts and chats.
 *
 * The Worker variable or secret CMUX_VM_DB_FAULT holds one JSON object:
 *
 *   {"mode": "latency" | "stall", "ms": 1..60000, "share": (0, 1], "from": epoch ms, "until": epoch ms}
 *
 * Between `from` and `until` (a window of at most one hour), each query is picked with probability `share`. A picked
 * query in `latency` mode waits `ms` and then runs; in `stall` mode it waits `ms` and then fails as a database that
 * stopped answering does (StoreError, code FAULT_STALL: the caller answers 503 `database.<operation>`). Each picked
 * query logs one `cmux-vm database fault` warning with its operation, never its text or parameters.
 *
 * Off by default: unset, empty, `off`, anything that does not parse, and an expired window all leave every query
 * untouched. Only ENVIRONMENT=staging reads it; production, preview and local ignore the value entirely.
 * Turn it on with `cmux-vm.yml` action `db-fault-staging`; it turns itself off at `until`.
 */
import { Clock, Duration, Effect, Layer, Random } from "effect";
import type { Environment } from "../policy.ts";
import { SqlClient, type SqlClientService, StoreError } from "./sql.ts";

export interface DbFault {
  readonly mode: "latency" | "stall";
  readonly ms: number;
  readonly share: number;
  readonly fromMs: number;
  readonly untilMs: number;
}

/** The longest a picked query is held. */
export const MAX_FAULT_MS = 60_000;
/** The longest window: a switch left on turns itself off within an hour of its start. */
export const MAX_FAULT_WINDOW_MS = 60 * 60_000;

const isEpochMs = (value: unknown): value is number => typeof value === "number" && Number.isInteger(value) && value > 0;

/** CMUX_VM_DB_FAULT for ENVIRONMENT, or null (off) for every other environment and every value that is not a fault. */
export const parseDbFault = (value: string | undefined, environment: Environment): DbFault | null => {
  if (environment !== "staging" || value === undefined) return null;
  const text = value.trim();
  if (text === "" || text === "off") return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const mode: unknown = Reflect.get(parsed, "mode");
  const ms: unknown = Reflect.get(parsed, "ms");
  const share: unknown = Reflect.get(parsed, "share");
  const from: unknown = Reflect.get(parsed, "from");
  const until: unknown = Reflect.get(parsed, "until");
  if (mode !== "latency" && mode !== "stall") return null;
  if (typeof ms !== "number" || !Number.isInteger(ms) || ms < 1 || ms > MAX_FAULT_MS) return null;
  if (typeof share !== "number" || !(share > 0 && share <= 1)) return null;
  if (!isEpochMs(from) || !isEpochMs(until) || until <= from || until - from > MAX_FAULT_WINDOW_MS) return null;
  return { mode, ms, share, fromMs: from, untilMs: until };
};

/** The query with the fault applied: picked or not at the moment it runs, on the Effect clock and random service. */
export const faultedSqlClient = (inner: SqlClientService, fault: DbFault): SqlClientService => ({
  query: (operation, text, params) =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis;
      if (now < fault.fromMs || now >= fault.untilMs) return yield* inner.query(operation, text, params);
      if ((yield* Random.next) >= fault.share) return yield* inner.query(operation, text, params);
      yield* Effect.logWarning("cmux-vm database fault").pipe(
        Effect.annotateLogs({ operation, mode: fault.mode, ms: fault.ms }),
      );
      yield* Effect.sleep(Duration.millis(fault.ms));
      if (fault.mode === "stall") return yield* Effect.fail(new StoreError({ operation, cause: { code: "FAULT_STALL" } }));
      return yield* inner.query(operation, text, params);
    }),
});

/** LAYER with FAULT applied to every query; LAYER itself when FAULT is null (off). */
export const withDbFault = (layer: Layer.Layer<SqlClient>, fault: DbFault | null): Layer.Layer<SqlClient> =>
  fault === null
    ? layer
    : Layer.effect(SqlClient, Effect.map(SqlClient, (inner) => faultedSqlClient(inner, fault))).pipe(Layer.provide(layer));
