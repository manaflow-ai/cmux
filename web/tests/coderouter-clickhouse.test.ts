import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";

import {
  __test as clickhouseTest,
  clickHouseConfig,
  insertRows,
  query,
  type ClickHouseConfig,
} from "../services/coderouter/clickhouse";
import * as observability from "../services/coderouter/observability";

const config: ClickHouseConfig = {
  url: "https://ledger.clickhouse.test:8443",
  user: "coderouter_app",
  password: "app-password-never-logged",
  database: "coderouter_dev",
};
const expectedAuth = `Basic ${Buffer.from("coderouter_app:app-password-never-logged").toString("base64")}`;

type Call = { readonly url: URL; readonly init: RequestInit };

function fakeFetch(
  respond: (call: Call) => Response | Promise<Response>,
  calls: Call[],
): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const call = { url: new URL(String(input)), init: init ?? {} };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
}

describe("CodeRouter ClickHouse client", () => {
  beforeEach(() => {
    clickhouseTest.resetDisabledReport();
  });

  test("inserts JSONEachRow with async_insert and basic auth", async () => {
    const calls: Call[] = [];
    const result = await insertRows(
      "usage_events",
      [{ team_id: "team-1", total_tokens: 10 }, { team_id: "team-1", total_tokens: 5 }],
      { config: () => config, fetch: fakeFetch(() => new Response("", { status: 200 }), calls) },
    );
    expect(result).toEqual({ ok: true });
    expect(calls).toHaveLength(1);
    const [call] = calls;
    expect(call!.url.origin).toBe("https://ledger.clickhouse.test:8443");
    expect(call!.url.searchParams.get("query")).toBe(
      "INSERT INTO coderouter_dev.usage_events FORMAT JSONEachRow",
    );
    expect(call!.url.searchParams.get("async_insert")).toBe("1");
    expect(call!.url.searchParams.get("wait_for_async_insert")).toBe("0");
    expect(call!.init.method).toBe("POST");
    expect(new Headers(call!.init.headers).get("authorization")).toBe(expectedAuth);
    expect(call!.init.body).toBe(
      '{"team_id":"team-1","total_tokens":10}\n{"team_id":"team-1","total_tokens":5}\n',
    );
    expect(call!.init.signal).toBeInstanceOf(AbortSignal);
  });

  test("skips the request for an empty batch", async () => {
    const calls: Call[] = [];
    const result = await insertRows("usage_events", [], {
      config: () => config,
      fetch: fakeFetch(() => new Response("", { status: 200 }), calls),
    });
    expect(result).toEqual({ ok: true });
    expect(calls).toHaveLength(0);
  });

  test("binds query parameters server-side and parses JSONEachRow", async () => {
    const calls: Call[] = [];
    const result = await query<{ day: string; total_tokens: number }>(
      "SELECT day, total_tokens FROM {db}.usage_events WHERE team_id = {team_id:String} AND toDate(event_time) >= {start_day:Date}",
      { team_id: "team'; DROP TABLE usage_events; --", start_day: "2026-08-04" },
      {
        config: () => config,
        fetch: fakeFetch(
          () => new Response('{"day":"2026-09-01","total_tokens":12}\n{"day":"2026-09-02","total_tokens":3}\n'),
          calls,
        ),
      },
    );
    expect(result).toEqual({
      ok: true,
      rows: [
        { day: "2026-09-01", total_tokens: 12 },
        { day: "2026-09-02", total_tokens: 3 },
      ],
    });
    const [call] = calls;
    expect(call!.url.searchParams.get("param_team_id")).toBe(
      "team'; DROP TABLE usage_events; --",
    );
    expect(call!.url.searchParams.get("param_start_day")).toBe("2026-08-04");
    expect(call!.url.searchParams.get("default_format")).toBe("JSONEachRow");
    expect(call!.url.searchParams.get("output_format_json_quote_64bit_integers")).toBe("0");
    const body = String(call!.init.body);
    expect(body).toContain("FROM coderouter_dev.usage_events");
    expect(body).toContain("{team_id:String}");
    expect(body).not.toContain("DROP TABLE");
    expect(body.trimEnd().endsWith("FORMAT JSONEachRow")).toBe(true);
    expect(new Headers(call!.init.headers).get("authorization")).toBe(expectedAuth);
  });

  test("reports non-2xx, malformed, and transport failures without throwing", async () => {
    const dependencies = (fetchImpl: typeof fetch) => ({ config: () => config, fetch: fetchImpl });
    expect(
      await query("SELECT 1", {}, dependencies(fakeFetch(() => new Response("denied", { status: 403 }), []))),
    ).toEqual({ ok: false, reason: "status", status: 403 });
    expect(
      await query("SELECT 1", {}, dependencies(fakeFetch(() => new Response("{not json\n"), []))),
    ).toEqual({ ok: false, reason: "malformed_response" });
    expect(
      await query("SELECT 1", {}, dependencies(fakeFetch(() => new Response("[1,2]\n"), []))),
    ).toEqual({ ok: false, reason: "malformed_response" });
    expect(
      await query("SELECT 1", {}, dependencies(mock(async () => {
        throw new Error("connect ECONNREFUSED");
      }) as typeof fetch)),
    ).toEqual({ ok: false, reason: "request_failed" });
    expect(
      await insertRows("usage_events", [{ a: 1 }], dependencies(fakeFetch(() => new Response("", { status: 500 }), []))),
    ).toEqual({ ok: false, reason: "status", status: 500 });
  });

  test("aborts on timeout and reports request_failed", async () => {
    const abortAware = ((_input: string | URL | Request, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason));
      })) as typeof fetch;
    const started = performance.now();
    const insert = await insertRows("usage_events", [{ a: 1 }], {
      config: () => config,
      fetch: abortAware,
      timeoutMs: { insert: 20, query: 20 },
    });
    const read = await query("SELECT 1", {}, {
      config: () => config,
      fetch: abortAware,
      timeoutMs: { insert: 20, query: 20 },
    });
    expect(insert).toEqual({ ok: false, reason: "request_failed" });
    expect(read).toEqual({ ok: false, reason: "request_failed" });
    expect(performance.now() - started).toBeLessThan(2_000);
  });

  test("disabled mode is a silent no-op reported once", async () => {
    const report = spyOn(observability, "reportCoderouterFailure");
    const fetchSpy = mock(async () => new Response(""));
    try {
      const dependencies = { config: () => null, fetch: fetchSpy as typeof fetch };
      expect(await insertRows("usage_events", [{ a: 1 }], dependencies)).toEqual({
        ok: false,
        reason: "disabled",
      });
      expect(await query("SELECT 1", {}, dependencies)).toEqual({ ok: false, reason: "disabled" });
      expect(await insertRows("route_events", [{ a: 1 }], dependencies)).toEqual({
        ok: false,
        reason: "disabled",
      });
      expect(fetchSpy).toHaveBeenCalledTimes(0);
      expect(report).toHaveBeenCalledTimes(1);
      expect(report.mock.calls[0]![0]).toBe("usage_ledger");
      expect(report.mock.calls[0]![2]).toEqual({ reason: "configuration_missing" });
    } finally {
      report.mockRestore();
    }
  });

  test("rejects unsafe identifiers before any request", async () => {
    const dependencies = { config: () => config, fetch: mock(async () => new Response("")) as typeof fetch };
    await expect(insertRows("usage_events; DROP", [{ a: 1 }], dependencies)).rejects.toThrow();
    await expect(query("SELECT 1", { "bad name": 1 }, dependencies)).rejects.toThrow();
  });
});

describe("CodeRouter ClickHouse configuration", () => {
  const saved = { ...process.env };
  afterEach(() => {
    for (const key of Object.keys(process.env)) {
      if (!(key in saved)) delete process.env[key];
    }
    Object.assign(process.env, saved);
  });

  test("reads the four CLICKHOUSE_* variables and normalizes the URL", () => {
    process.env.CLICKHOUSE_URL = "https://abc.us-west-2.aws.clickhouse.cloud:8443/";
    process.env.CLICKHOUSE_USER = "coderouter_app";
    process.env.CLICKHOUSE_PASSWORD = " secret ";
    process.env.CLICKHOUSE_DATABASE = "coderouter_dev";
    expect(clickHouseConfig()).toEqual({
      url: "https://abc.us-west-2.aws.clickhouse.cloud:8443",
      user: "coderouter_app",
      password: "secret",
      database: "coderouter_dev",
    });
  });

  test("is disabled when any variable is missing or the database name is unsafe", () => {
    process.env.CLICKHOUSE_URL = "https://abc.clickhouse.cloud:8443";
    process.env.CLICKHOUSE_USER = "coderouter_app";
    process.env.CLICKHOUSE_PASSWORD = "secret";
    delete process.env.CLICKHOUSE_DATABASE;
    expect(clickHouseConfig()).toBeNull();
    process.env.CLICKHOUSE_DATABASE = "coderouter; DROP";
    expect(clickHouseConfig()).toBeNull();
    process.env.CLICKHOUSE_DATABASE = "coderouter";
    process.env.CLICKHOUSE_URL = "not a url";
    expect(clickHouseConfig()).toBeNull();
  });
});
