import { describe, expect, test } from "bun:test";

import {
  formatSummary,
  ownerNetworkSlug,
  parseServerTiming,
  percentile,
  pollBoundedFetch,
  providerCredentialsFromEnv,
  summarize,
  summarizeFields,
  summarizeStages,
} from "../scripts/cloud-vm/benchStats.mjs";
import { networkSlugForUser } from "../services/vms/privateNetwork";

describe("percentile", () => {
  test("uses nearest rank on a sorted copy", () => {
    const values = [30, 10, 20, 40, 50];
    expect(percentile(values, 0.5)).toBe(30);
    expect(percentile(values, 0.9)).toBe(50);
    expect(percentile(values, 0.95)).toBe(50);
    expect(percentile(values, 0)).toBe(10);
    expect(values).toEqual([30, 10, 20, 40, 50]);
  });

  test("ignores non-finite samples and answers null when nothing is left", () => {
    expect(percentile([Number.NaN, Number.POSITIVE_INFINITY], 0.5)).toBeNull();
    expect(percentile([Number.NaN, 7], 0.5)).toBe(7);
    expect(percentile([], 0.5)).toBeNull();
  });
});

describe("summarize", () => {
  test("reports count and rounded distribution", () => {
    expect(summarize([100.26, 200, 300, 400.04])).toEqual({
      n: 4,
      min: 100.3,
      p50: 200,
      p90: 400,
      p95: 400,
      max: 400,
      mean: 250.1,
    });
  });

  test("an empty sample has only a count", () => {
    expect(summarize([])).toEqual({ n: 0 });
    expect(summarize([undefined, null, "12"])).toEqual({ n: 0 });
  });
});

describe("parseServerTiming", () => {
  test("reads the create route's per-stage header", () => {
    const header = "auth;dur=0.23, billing;dur=0.93, resolve_network;dur=103.61, provider_create;dur=1205.91, total;dur=2280";
    expect(parseServerTiming(header)).toEqual({
      auth: 0.23,
      billing: 0.93,
      resolve_network: 103.61,
      provider_create: 1205.91,
      total: 2280,
    });
  });

  test("skips metrics without a numeric dur and tolerates quoting and case", () => {
    expect(parseServerTiming('cache;desc="hit", db;DUR="12.5", broken;dur=abc, ;dur=3')).toEqual({ db: 12.5 });
    expect(parseServerTiming(undefined)).toEqual({});
    expect(parseServerTiming("")).toEqual({});
  });
});

describe("summarizeStages and summarizeFields", () => {
  test("merges stage maps across trials", () => {
    const stages = summarizeStages([
      { auth: 1, provider_create: 1000 },
      { auth: 3, provider_create: 2000, mark_running: 20 },
      undefined,
    ]);
    expect(stages.auth).toMatchObject({ n: 2, p50: 1, max: 3 });
    expect(stages.provider_create).toMatchObject({ n: 2, p50: 1000, max: 2000 });
    expect(stages.mark_running).toMatchObject({ n: 1, p50: 20 });
  });

  test("summarizes numeric trial fields and skips missing ones", () => {
    const summary = summarizeFields(
      [{ createMs: 900, attachMs: 700 }, { createMs: 1100 }, { createMs: "x" }],
      ["createMs", "attachMs", "destroyMs"],
    );
    expect(summary.createMs).toMatchObject({ n: 2, p50: 900, max: 1100 });
    expect(summary.attachMs).toMatchObject({ n: 1, p50: 700 });
    expect(summary.destroyMs).toEqual({ n: 0 });
  });
});

describe("ownerNetworkSlug", () => {
  test("derives the same provider slug as the application", () => {
    for (const userId of ["user-1", "a6f2c1d0-3b4e-4f5a-9c8d-1e2f3a4b5c6d", ""]) {
      expect(ownerNetworkSlug(userId)).toBe(networkSlugForUser(userId));
    }
    expect(ownerNetworkSlug("user-1")).toMatch(/^cmux-net-[0-9a-f]{32}$/);
  });
});

describe("formatSummary", () => {
  test("renders one aligned row per stage", () => {
    const text = formatSummary({
      create: { n: 3, p50: 950, p90: 1200, p95: 1200, max: 1200 },
      empty: { n: 0 },
    });
    const lines = text.split("\n");
    expect(lines[0]).toMatch(/^stage\s+n\s+p50\s+p90\s+p95\s+max$/);
    expect(lines[1]).toMatch(/^create\s+3\s+950\s+1200\s+1200\s+1200$/);
    expect(lines[2]).toMatch(/^empty\s+0\s+-\s+-\s+-\s+-$/);
  });
});

describe("providerCredentialsFromEnv", () => {
  test("prefers the API key, then the Stack token pair, and carries the base URL", () => {
    expect(providerCredentialsFromEnv({ FREESTYLE_API_KEY: " key ", FREESTYLE_API_URL: "https://api.example" })).toEqual({ apiKey: "key", baseUrl: "https://api.example" });
    expect(providerCredentialsFromEnv({ FREESTYLE_STACK_ACCESS_TOKEN: "tok", FREESTYLE_TEAM_ID: "team" })).toEqual({ stackAccessToken: "tok", teamId: "team", baseUrl: undefined });
  });

  test("answers null for an incomplete pair, an empty (sensitive) value, or nothing", () => {
    expect(providerCredentialsFromEnv({ FREESTYLE_STACK_ACCESS_TOKEN: "tok" })).toBeNull();
    expect(providerCredentialsFromEnv({ FREESTYLE_API_KEY: "" })).toBeNull();
    expect(providerCredentialsFromEnv({})).toBeNull();
  });
});

describe("pollBoundedFetch", () => {
  test("passes ordinary requests through with a timeout signal", async () => {
    const calls: Array<{ url: string; signal: AbortSignal | undefined }> = [];
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), signal: init?.signal ?? undefined });
      return new Response("ok");
    }) as typeof fetch;
    const { fetch: boundedFetch, abandoned } = pollBoundedFetch({ fetchTimeoutMs: 1_000, pollDeadlineMs: 5_000, fetchImpl });
    await boundedFetch("https://api.example/v5/vms", { method: "POST" });
    expect(calls).toHaveLength(1);
    expect(calls[0].signal).toBeInstanceOf(AbortSignal);
    expect(abandoned.size).toBe(0);
  });

  test("keeps a background request outstanding until a terminal answer, and refuses to poll past the deadline", async () => {
    let clock = 0;
    const seen: string[] = [];
    const fetchImpl = (async (input: string | URL | Request) => {
      const url = String(input);
      seen.push(url);
      if (url.endsWith("/fails")) throw new Error("connection reset");
      return new Response("", { status: url.endsWith("/done") ? 200 : 202 });
    }) as typeof fetch;
    const shared = new Set<string>();
    const { fetch: boundedFetch, abandoned } = pollBoundedFetch({ fetchTimeoutMs: 1_000, pollDeadlineMs: 5_000, abandoned: shared, now: () => clock, fetchImpl });
    const poll = "https://api.example/v5/background-requests/abc";
    await boundedFetch(poll);
    expect([...abandoned]).toEqual([poll]);
    clock = 4_999;
    await boundedFetch(poll);
    clock = 5_001;
    await expect(boundedFetch(poll)).rejects.toThrow("exceeded 5000 ms");
    // Still outstanding: its polling ended without a terminal answer, and the
    // platform may complete it. The set is the caller's shared one.
    expect(abandoned).toBe(shared);
    expect([...abandoned]).toEqual([poll]);
    // A request whose poll fails at the transport stays outstanding too (the
    // SDK gives up after repeated failures while the platform works on).
    const failing = "https://api.example/v5/background-requests/fails";
    await expect(boundedFetch(failing)).rejects.toThrow("connection reset");
    expect(abandoned.has(failing)).toBe(true);
    // A terminal answer resolves a request; plain requests never enter the set.
    const done = "https://api.example/v5/background-requests/done";
    await boundedFetch(done);
    expect(abandoned.has(done)).toBe(false);
    await boundedFetch("https://api.example/v5/vms/x");
    expect(seen).toHaveLength(5);
    expect([...abandoned].sort()).toEqual([poll, failing].sort());
  });
});
