import { describe, expect, it } from "vitest";
import { isForeignSmaller, nextFitSize } from "../src/lib/fit";

describe("isForeignSmaller", () => {
  it("detects a foreign size that is smaller on either pane axis", () => {
    expect(isForeignSmaller({ cols: 80, rows: 30 }, { cols: 100, rows: 30 })).toBe(true);
    expect(isForeignSmaller({ cols: 100, rows: 24 }, { cols: 100, rows: 30 })).toBe(true);
    expect(isForeignSmaller({ cols: 80, rows: 40 }, { cols: 100, rows: 30 })).toBe(true);
  });

  it("does not mark matching, larger, missing, or invalid sizes as foreign-smaller", () => {
    expect(isForeignSmaller({ cols: 100, rows: 30 }, { cols: 100, rows: 30 })).toBe(false);
    expect(isForeignSmaller({ cols: 120, rows: 40 }, { cols: 100, rows: 30 })).toBe(false);
    expect(isForeignSmaller({ cols: 100, rows: 30 }, undefined)).toBe(false);
    expect(isForeignSmaller({ cols: 100, rows: 30 }, { cols: Number.NaN, rows: 30 })).toBe(false);
  });
});

describe("nextFitSize", () => {
  it("refits a wide server replay to the pane size", () => {
    // Server replayed 316 cols; a ~715px pane proposes 88x24.
    expect(nextFitSize({ cols: 316, rows: 80 }, { cols: 88, rows: 24 })).toEqual({ cols: 88, rows: 24 });
  });

  it("is a no-op when the terminal already matches the proposal", () => {
    // A server `resized` echo of the size we just pushed changes nothing, so
    // no second resize-surface is sent: no echo loop.
    expect(nextFitSize({ cols: 88, rows: 24 }, { cols: 88, rows: 24 })).toBeNull();
  });

  it("is a no-op when the fit addon cannot propose dimensions yet", () => {
    expect(nextFitSize({ cols: 88, rows: 24 }, undefined)).toBeNull();
  });

  it("rejects non-finite proposals", () => {
    expect(nextFitSize({ cols: 88, rows: 24 }, { cols: Number.NaN, rows: 24 })).toBeNull();
    expect(nextFitSize({ cols: 88, rows: 24 }, { cols: 88, rows: Number.POSITIVE_INFINITY })).toBeNull();
  });

  it("rejects degenerate sizes from a collapsed pane", () => {
    expect(nextFitSize({ cols: 88, rows: 24 }, { cols: 1, rows: 24 })).toBeNull();
    expect(nextFitSize({ cols: 88, rows: 24 }, { cols: 88, rows: 0 })).toBeNull();
  });

  it("applies a pane geometry change over the current server size", () => {
    // Foreign client set 200x50; our pane later shrank: local fit wins on the
    // next local interaction.
    expect(nextFitSize({ cols: 200, rows: 50 }, { cols: 96, rows: 30 })).toEqual({ cols: 96, rows: 30 });
  });
});
