import { describe, expect, it } from "vitest";
import { nextFitSize } from "../src/lib/fit";

describe("nextFitSize", () => {
  it("refits a wide server replay to the pane size", () => {
    // Server replayed 316 cols; a ~715px pane proposes 88x24.
    expect(nextFitSize({ cols: 316, rows: 80 }, { cols: 88, rows: 24 })).toEqual({ cols: 88, rows: 24 });
  });

  it("is a no-op when this client already reported the proposal", () => {
    expect(nextFitSize({ cols: 88, rows: 24 }, { cols: 88, rows: 24 })).toBeNull();
  });

  it("reports the initial fit even when the shared surface already matches", () => {
    expect(nextFitSize(null, { cols: 88, rows: 24 })).toEqual({ cols: 88, rows: 24 });
  });

  it("is a no-op when the fit addon cannot propose dimensions yet", () => {
    expect(nextFitSize(null, undefined)).toBeNull();
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
    // The shared grid became 200x50; our pane later shrank, so its next local
    // geometry measurement publishes 96x30.
    expect(nextFitSize({ cols: 200, rows: 50 }, { cols: 96, rows: 30 })).toEqual({ cols: 96, rows: 30 });
  });
});
