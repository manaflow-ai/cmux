import { describe, expect, test } from "bun:test";

import {
  formatSummary,
  parseServerTiming,
  percentile,
  summarize,
  summarizeFields,
  summarizeStages,
} from "../scripts/cloud-vm/benchStats.mjs";

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
