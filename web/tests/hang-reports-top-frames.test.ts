import { describe, expect, test } from "bun:test";

import {
  atosArguments,
  compareVersions,
  groupHangs,
  isOurImage,
  mergeIntervals,
  mergeStallHistograms,
  parseDwarfdumpUuids,
  percentile,
  signatureFrames,
  symbolicationRequests,
  type StoredFrame,
  type StoredReport,
} from "../scripts/hang-reports/topFrames";

const OURS_UUID = "C1B2C3D4-0000-1111-2222-333344445555";

const appKit: StoredFrame = { image: "AppKit", uuid: "8B1E0C5A-1111-2222-3333-444455556666", offset: 0x10 };
const kernel: StoredFrame = { image: "libsystem_kernel.dylib", uuid: "A1B2C3D4-0000-1111-2222-333344445555", offset: 0x20 };
const ours = (offset: number): StoredFrame => ({ image: "cmux NEXT", uuid: OURS_UUID.toLowerCase(), offset });

function report(installId: string, build: string, hangs: StoredReport["payload"]["hangs"], extra: Partial<StoredReport["payload"]> = {}): StoredReport {
  return { installId, appVersion: "0.70.0", appBuild: build, channel: "nightly", payload: { hangs, ...extra } };
}

describe("hang report top frames", () => {
  test("classifies Apple, other and our images", () => {
    expect(isOurImage("cmux NEXT")).toBe(true);
    expect(isOurImage("CmuxNextControl")).toBe(true);
    expect(isOurImage("GhosttyKit")).toBe(true);
    expect(isOurImage("Chromium Embedded Framework")).toBe(true);
    expect(isOurImage("AppKit")).toBe(false);
    expect(isOurImage("libswift_Concurrency.dylib")).toBe(false);
    expect(isOurImage("AGXMetalG16X")).toBe(false);
    expect(isOurImage("other")).toBe(false);
  });

  test("signs a hang with its first five frames of ours, else its top five", () => {
    const mixed = [kernel, appKit, ours(1), { image: "other" }, ours(2), ours(3), ours(4), ours(5), ours(6)];
    expect(signatureFrames(mixed).map((frame) => frame.offset)).toEqual([1, 2, 3, 4, 5]);
    const apple = [kernel, appKit, { image: "other" }, appKit, kernel, appKit];
    expect(signatureFrames(apple)).toEqual(apple.slice(0, 5));
  });

  test("groups hangs from both sources; percentiles use MetricKit durations only", () => {
    const reports = [
      report("install-a", "100", [
        { source: "metrickit", kind: "hang", durationMs: 2500, frames: [kernel, ours(0x40)] },
        { source: "metrickit", kind: "hang", durationMs: 9000, frames: [ours(0x40)] },
        { source: "watchdog", kind: "stall", durationMs: 300, frames: [appKit, ours(0x40)] },
      ]),
      report("install-b", "101", [
        // A watchdog hang's duration is a ~2 s lower bound: counted, never a percentile input.
        { source: "watchdog", kind: "hang", durationMs: 60_000, frames: [ours(0x40)] },
        { source: "watchdog", kind: "hang", durationMs: 2000, frames: [appKit] },
      ]),
    ];
    const groups = groupHangs(reports);
    expect(groups).toHaveLength(2);
    expect(groups[0]).toMatchObject({
      signature: "cmux NEXT+0x40",
      count: 4,
      installs: 2,
      p50DurationMs: 2500,
      p95DurationMs: 9000,
      metrickitHangs: 2,
      watchdogHangs: 1,
      kinds: { hang: 3, stall: 1 },
      sources: { metrickit: 2, watchdog: 2 },
      appBuilds: { "100": 3, "101": 1 },
    });
    expect(groups[1]).toMatchObject({
      signature: "AppKit+0x10",
      count: 1,
      installs: 1,
      p50DurationMs: null,
      p95DurationMs: null,
      metrickitHangs: 0,
      watchdogHangs: 1,
    });
  });

  test("ranks groups by distinct installs, then by hang count", () => {
    const hang = (frames: readonly StoredFrame[]) => ({ source: "metrickit", kind: "hang", durationMs: 2100, frames });
    const reports = [
      // One Mac hits signature A ten times.
      report("solo", "1", Array.from({ length: 10 }, () => hang([ours(0xa)]))),
      // Three Macs hit signature B once each; two of them also hit C once.
      report("m1", "1", [hang([ours(0xb)]), hang([ours(0xc)])]),
      report("m2", "1", [hang([ours(0xb)]), hang([ours(0xc)]), hang([ours(0xc)])]),
      report("m3", "1", [hang([ours(0xb)])]),
    ];
    expect(groupHangs(reports).map((group) => [group.signature, group.installs, group.count])).toEqual([
      ["cmux NEXT+0xb", 3, 3],
      ["cmux NEXT+0xc", 2, 3],
      ["cmux NEXT+0xa", 1, 10],
    ]);
  });

  test("merges stall histograms and interval histograms across reports", () => {
    const reports = [
      report("a", "1", [], {
        stallHistogram: [{ lowMs: 50, highMs: 100, count: 3 }, { lowMs: 100, highMs: 250, count: 1 }],
        intervals: [{ category: "motion", name: "motion.frame", count: 100, buckets: [{ lowMs: 0, highMs: 10, count: 90 }], hitchMsPerS: 1 }],
      }),
      report("b", "1", [], {
        stallHistogram: [{ lowMs: 50, highMs: 100, count: 2 }],
        intervals: [
          { category: "motion", name: "motion.frame", count: 300, buckets: [{ lowMs: 0, highMs: 10, count: 280 }, { lowMs: 10, highMs: 20, count: 20 }], hitchMsPerS: 3 },
          { category: "key", name: "key.turn", count: 5, hitchMsPerS: null },
        ],
      }),
    ];
    expect(mergeStallHistograms(reports)).toEqual([
      { lowMs: 50, highMs: 100, count: 5 },
      { lowMs: 100, highMs: 250, count: 1 },
    ]);
    expect(mergeIntervals(reports)).toEqual([
      { category: "key", name: "key.turn", count: 5, buckets: [], hitchMsPerS: null },
      {
        category: "motion",
        name: "motion.frame",
        count: 400,
        buckets: [{ lowMs: 0, highMs: 10, count: 370 }, { lowMs: 10, highMs: 20, count: 20 }],
        hitchMsPerS: 2.5,
      },
    ]);
  });

  test("percentile uses nearest rank", () => {
    expect(percentile([], 0.5)).toBe(0);
    expect(percentile([5, 1, 3], 0.5)).toBe(3);
    expect(percentile(Array.from({ length: 20 }, (_, index) => index + 1), 0.95)).toBe(19);
  });

  test("compares nightly versions by their numeric part", () => {
    expect(compareVersions("0.70.0-nightly.123", "0.70.0")).toBe(0);
    expect(compareVersions("0.70.1", "0.70.0")).toBeGreaterThan(0);
    expect(compareVersions("0.9", "0.10.0")).toBeLessThan(0);
  });

  test("builds atos requests for our frames, keyed by uppercase UUID", () => {
    const groups = groupHangs([report("a", "1", [
      { source: "metrickit", kind: "hang", durationMs: 2000, frames: [appKit, ours(0x40), ours(0x10)] },
      { source: "metrickit", kind: "hang", durationMs: 2000, frames: [ours(0x40)] },
    ])]);
    expect([...symbolicationRequests(groups)]).toEqual([[OURS_UUID, [0x10, 0x40]]]);
    expect(atosArguments("/d/cmux.dSYM/Contents/Resources/DWARF/cmux", "arm64", [0x10])).toEqual([
      "-o", "/d/cmux.dSYM/Contents/Resources/DWARF/cmux", "-arch", "arm64", "-l", "0x100000000", "0x100000010",
    ]);
  });

  test("parses dwarfdump UUID lines", () => {
    const output = [
      `UUID: ${OURS_UUID} (arm64) /d/cmux.dSYM/Contents/Resources/DWARF/cmux NEXT`,
      "UUID: 11111111-2222-3333-4444-555555555555 (x86_64) /d/cmux.dSYM/Contents/Resources/DWARF/cmux NEXT",
    ].join("\n");
    const parsed = parseDwarfdumpUuids(output);
    expect(parsed.get(OURS_UUID)).toEqual({ arch: "arm64", path: "/d/cmux.dSYM/Contents/Resources/DWARF/cmux NEXT" });
    expect(parsed.size).toBe(2);
  });
});
