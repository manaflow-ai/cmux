// Regression coverage for the 2026-09-24 incident: a `uuid = text` Postgres
// error in signed VM auth crashed every new Cloud VM's model requests for
// ten hours. The crash reached PostHog only as a redacted `handler:unknown`
// issue with no team, and wrote no ClickHouse `route_events` row, so the
// ledger-driven alert cron never saw it.
import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

import { vmToken } from "./vm-authorization-fixture";
import * as analytics from "../services/coderouter/analytics";
import * as usageLedger from "../services/coderouter/usageLedger";
import type { RouteEventInput } from "../services/coderouter/usageLedger";
import { safeErrorCause } from "../services/coderouter/errorCause";
import {
  CODEROUTER_REQUEST_ID_HEADER,
  markCoderouterRouteEventRecorded,
  recordCoderouterIdentity,
  withCoderouterRoute,
} from "../services/coderouter/requestTelemetry";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";

type Captured = { event: string; teamId?: string; userId?: string; properties: Record<string, unknown> };

let rawBatch: ReturnType<typeof spyOn<typeof analytics, "captureCoderouterRawBatch">>;
let routeEvents: ReturnType<typeof spyOn<typeof usageLedger, "recordRouteEvent">>;
let rows: RouteEventInput[];

function captured(): Captured[] {
  return rawBatch.mock.calls.flatMap(([events]) =>
    events.map((entry) => ({
      event: entry.event,
      ...(entry.teamId ? { teamId: entry.teamId } : {}),
      ...(entry.userId ? { userId: entry.userId } : {}),
      properties: { ...entry.properties },
    })));
}

beforeEach(() => {
  rows = [];
  rawBatch = spyOn(analytics, "captureCoderouterRawBatch");
  routeEvents = spyOn(usageLedger, "recordRouteEvent").mockImplementation((input) => {
    rows.push(input);
  });
});

afterEach(() => {
  rawBatch.mockRestore();
  routeEvents.mockRestore();
});

/**
 * Drizzle's wrapper for a failed query. Its message embeds the SQL and the
 * bound parameters, which is why the whole message must stay out of
 * telemetry.
 */
class DrizzleQueryError extends Error {
  constructor(
    readonly query: string,
    readonly params: unknown[],
    cause: unknown,
  ) {
    super(`Failed query: ${query}\nparams: ${params.join(",")}`);
    this.cause = cause;
  }
}

class PostgresError extends Error {
  constructor(message: string, readonly code: string) {
    super(message);
    this.name = "PostgresError";
  }
}

const SECRET_PARAM = "crt_secretparametervalue0123456789";

function incidentError(): DrizzleQueryError {
  return new DrizzleQueryError(
    'select "id", "team_id" from "coderouter_route_tokens" where "vm_id" = $1 and "token_hash" = $2',
    ["vm-incident", SECRET_PARAM],
    new PostgresError("operator does not exist: uuid = text", "42883"),
  );
}

const anthropicUnavailable = () =>
  Response.json({ type: "error", error: { type: "overloaded_error", message: "retry" } }, { status: 503 });

describe("safeErrorCause", () => {
  test("keeps the class, SQLSTATE and statement kind, never the message or parameters", () => {
    const cause = safeErrorCause(incidentError());
    expect(cause).toEqual({
      errorClass: "DrizzleQueryError",
      causeClass: "PostgresError",
      dbSqlstate: "42883",
      dbOperation: "select",
    });
    expect(JSON.stringify(cause)).not.toContain("uuid");
    expect(JSON.stringify(cause)).not.toContain(SECRET_PARAM);
  });

  test("reads node-postgres DatabaseError codes and transport errno codes", () => {
    const pg = Object.assign(new Error("relation \"secret_table\" does not exist"), {
      name: "error",
      code: "42P01",
      severity: "ERROR",
      routine: "parserOpenTable",
    });
    expect(safeErrorCause(pg)).toMatchObject({ dbSqlstate: "42P01" });
    const transport = Object.assign(new Error("connect ECONNREFUSED 10.0.0.1:5432"), { code: "ECONNREFUSED" });
    expect(safeErrorCause(new Error("wrapped", { cause: transport }))).toEqual({
      errorClass: "Error",
      errorCode: "ECONNREFUSED",
    });
  });

  test("drops class names and codes that are not plain identifiers", () => {
    const hostile = Object.assign(new Error("x"), { name: "Error: token=abc", code: "not a code; drop table" });
    const cause = safeErrorCause(hostile);
    expect(cause.errorClass).toBe("Error");
    expect(cause.dbSqlstate).toBeUndefined();
    expect(cause.errorCode).toBeUndefined();
    expect(safeErrorCause("a string")).toEqual({ errorClass: "NonError" });
  });
});

describe("route_crash ledger row", () => {
  test("a crash writes one route_events row with the 503 that was returned", async () => {
    const route = withCoderouterRoute(
      { surface: "messages", route: "/v1/messages", unavailable: anthropicUnavailable },
      async () => {
        throw new RangeError("exploded");
      },
    );
    const response = await route(new Request("https://coderouter.test/v1/messages", { method: "POST" }), undefined);
    expect(response.status).toBe(503);
    expect(rows).toHaveLength(1);
    const row = rows[0]!;
    expect(row).toMatchObject({
      requestId: response.headers.get(CODEROUTER_REQUEST_ID_HEADER)!,
      provider: "claude",
      outcome: "route_crash",
      failureStage: "handler",
      status: 503,
      attemptCount: 0,
      refreshRetryCount: 0,
      responseStreamed: false,
    });
    expect(row.durationMs).toBeGreaterThanOrEqual(0);
    expect(row.teamId).toBeUndefined();
    expect(row.vmId ?? null).toBeNull();
  });

  test("a crash after authentication carries the team, user and VM", async () => {
    const route = withCoderouterRoute(
      { surface: "responses", route: "/v1/responses", unavailable: () => new Response(null, { status: 503 }) },
      async () => {
        recordCoderouterIdentity({ teamId: "team-9", stackUserId: "user-9", vmId: "vm-9", apiKeyId: null });
        throw new TypeError("late crash");
      },
    );
    await route(new Request("https://coderouter.test/v1/responses", { method: "POST" }), undefined);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      provider: "codex",
      outcome: "route_crash",
      failureStage: "handler",
      teamId: "team-9",
      stackUserId: "user-9",
      vmId: "vm-9",
    });
  });

  test("a crash inside signed VM auth is attributed to the verified claims at stage auth", async () => {
    const token = await vmToken("vm-incident", "team-incident", "user-incident");
    const route = withCoderouterRoute(
      { surface: "messages", route: "/v1/messages", unavailable: anthropicUnavailable },
      async (request) => {
        await authenticateRequestRouteToken(request, async () => {
          throw incidentError();
        });
        return new Response("unreachable");
      },
    );
    const response = await route(new Request("https://coderouter.test/v1/messages", {
      method: "POST",
      headers: { "x-cmux-authorization": `Bearer ${token}` },
    }), undefined);
    expect(response.status).toBe(503);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      outcome: "route_crash",
      failureStage: "auth",
      provider: "claude",
      status: 503,
      teamId: "team-incident",
      stackUserId: "user-incident",
      vmId: "vm-incident",
    });

    const exceptions = captured().filter((entry) => entry.event === "$exception");
    expect(exceptions).toHaveLength(1);
    const exception = exceptions[0]!;
    expect(exception.teamId).toBe("team-incident");
    expect(exception.properties).toMatchObject({
      $exception_level: "error",
      $exception_fingerprint: "coderouter:route_crash:/v1/messages:claude:pg_42883",
      coderouter_outcome: "route_crash",
      coderouter_failure_stage: "auth",
      coderouter_provider: "claude",
      coderouter_route: "/v1/messages",
      coderouter_vm_id: "vm-incident",
      coderouter_identity_source: "signed_vm_claims",
      coderouter_error_class: "DrizzleQueryError",
      coderouter_error_cause_class: "PostgresError",
      coderouter_db_sqlstate: "42883",
      coderouter_db_operation: "select",
    });
    const list = exception.properties.$exception_list as Array<{ type: string; value: string }>;
    expect(list[0]!.type).toBe("DrizzleQueryError");
    expect(list[0]!.value).toBe("DrizzleQueryError: message redacted (PostgresError, sqlstate 42883, select)");
    const serialized = JSON.stringify(captured()) + JSON.stringify(rows);
    expect(serialized).not.toContain("uuid = text");
    expect(serialized).not.toContain("operator does not exist");
    expect(serialized).not.toContain(SECRET_PARAM);
    expect(serialized).not.toContain(token);
    expect(serialized).not.toContain("coderouter_route_tokens");
  });

  test("a ledger failure never changes the crash response", async () => {
    routeEvents.mockImplementation(() => {
      throw new Error("clickhouse exploded");
    });
    const route = withCoderouterRoute(
      { surface: "messages", route: "/v1/messages", unavailable: anthropicUnavailable },
      async () => {
        throw new Error("crash");
      },
    );
    const response = await route(new Request("https://coderouter.test/v1/messages", { method: "POST" }), undefined);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ type: "error", error: { type: "overloaded_error", message: "retry" } });
    expect(response.headers.get(CODEROUTER_REQUEST_ID_HEADER)).toBeTruthy();
  });

  test("no crash row for a success, a caller cancellation, or a request whose proxy already wrote its row", async () => {
    const ok = withCoderouterRoute(
      { surface: "responses", route: "/v1/responses", unavailable: () => new Response(null, { status: 503 }) },
      async () => new Response("ok"),
    );
    await ok(new Request("https://coderouter.test/v1/responses", { method: "POST" }), undefined);

    const controller = new AbortController();
    controller.abort();
    const cancelled = withCoderouterRoute(
      { surface: "responses", route: "/v1/responses", unavailable: () => new Response(null, { status: 503 }) },
      async (request) => {
        throw request.signal.reason;
      },
    );
    await cancelled(new Request("https://coderouter.test/v1/responses", { method: "POST", signal: controller.signal }), undefined);

    const lateCrash = withCoderouterRoute(
      { surface: "responses", route: "/v1/responses", unavailable: () => new Response(null, { status: 503 }) },
      async () => {
        markCoderouterRouteEventRecorded();
        throw new Error("after the proxy wrote its row");
      },
    );
    await lateCrash(new Request("https://coderouter.test/v1/responses", { method: "POST" }), undefined);
    expect(rows).toEqual([]);
  });

  test("the real ledger writer marks the request so a later crash cannot duplicate it", async () => {
    routeEvents.mockRestore();
    const inserted: string[] = [];
    const route = withCoderouterRoute(
      { surface: "responses", route: "/v1/responses", unavailable: () => new Response(null, { status: 503 }) },
      async () => {
        usageLedger.recordRouteEvent({
          requestId: "req-proxy",
          provider: "codex",
          agent: "codex",
          outcome: "success",
          failureStage: "none",
          status: 200,
          attemptCount: 1,
          refreshRetryCount: 0,
          durationMs: 1,
          responseStreamed: false,
        }, {
          insert: async (table) => {
            inserted.push(table);
            return { ok: true };
          },
          defer: (task) => void task,
          now: () => new Date("2026-09-25T00:00:00Z"),
        });
        throw new Error("crash after the row");
      },
    );
    const spy = spyOn(usageLedger, "recordRouteEvent");
    try {
      await route(new Request("https://coderouter.test/v1/responses", { method: "POST" }), undefined);
      // One call: the proxy's own row. The crash finalizer saw the marker.
      expect(spy).toHaveBeenCalledTimes(1);
    } finally {
      spy.mockRestore();
    }
    // Re-arm the default spy for afterEach.
    routeEvents = spyOn(usageLedger, "recordRouteEvent");
  });
});
