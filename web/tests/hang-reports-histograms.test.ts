import { describe, expect, test } from "bun:test";

import { EXPORT_FORMAT, exportReports, type StoredHistogramRow } from "../scripts/hang-reports-histograms";

const INSTALL_A = "6F1C2E4A-1B2C-4D5E-8F90-0123456789AB";
const INSTALL_B = "7A1C2E4A-1B2C-4D5E-8F90-0123456789AB";

function row(installId: string, payload: unknown): StoredHistogramRow {
  return { install_id: installId, app_version: "0.72.0", app_build: "104", received_day: "2026-10-26", payload };
}

describe("hang-reports-histograms export", () => {
  test("reads top-level and per-launch histograms of schema 3 only", () => {
    const reports = exportReports([
      row(INSTALL_A, {
        schema: 3,
        histograms: [{ name: "key.frame.view", unit: "microseconds", buckets: [[40, 3], [41, 1]] }],
        launches: [{ histograms: [{ name: "main.turn", unit: "microseconds", buckets: [[30, 2]] }] }],
      }),
      row(INSTALL_A, { schema: 2, intervals: [] }),
    ]);
    expect(reports).toEqual([{
      install: "install-1",
      version: "0.72.0",
      build: "104",
      day: "2026-10-26",
      histograms: [
        { name: "key.frame.view", unit: "microseconds", buckets: [[40, 3], [41, 1]] },
        { name: "main.turn", unit: "microseconds", buckets: [[30, 2]] },
      ],
    }]);
  });

  test("drops non-catalog names and bad bucket pairs", () => {
    const reports = exportReports([row(INSTALL_A, {
      schema: 3,
      histograms: [
        { name: "Key Frame", unit: "microseconds", buckets: [[40, 3]] },
        { name: "key.frame.view", unit: "microseconds", buckets: [[-1, 3], [40, 0], [41], [42, 1.5], [43, 2]] },
      ],
    })]);
    expect(reports[0]?.histograms).toEqual([{ name: "key.frame.view", unit: "microseconds", buckets: [[43, 2]] }]);
  });

  test("replaces install ids with stable per-run pseudonyms", () => {
    const payload = { schema: 3, histograms: [{ name: "main.turn", unit: "microseconds", buckets: [[30, 1]] }] };
    const reports = exportReports([row(INSTALL_A, payload), row(INSTALL_B, payload), row(INSTALL_A, payload)]);
    expect(reports.map((report) => report.install)).toEqual(["install-1", "install-2", "install-1"]);
    expect(JSON.stringify(reports)).not.toContain(INSTALL_A);
    expect(EXPORT_FORMAT).toBe("cmux-hang-report-histograms/1");
  });
});
