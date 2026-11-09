import { expect, test } from "bun:test";
import {
  afterClean,
  groupedRows,
  keptSelection,
  parseStorageReport,
  previewLabel,
  storageBytes,
  storageFailure,
  storagePreview,
  storageRows,
  toggled,
  toggledAll,
  usedShare,
  withRefused,
} from "./storageSectionModel";

const GB = 1024 ** 3;

const item = (path: string, extra: Record<string, unknown> = {}) => ({
  path,
  repository: "/Users/me/src/atlas",
  branch: "lane/x",
  verdict: { action: "reclaim", reason: "merged into main" },
  stale: true,
  ...extra,
});

const reply = {
  report: {
    disk: { total: 1000 * GB, available: 212 * GB, mount: "/" },
    pressure: "high",
    applied: false,
    items: [
      item("/w/small", { bytes: 1 * GB }),
      item("/w/unmeasured"),
      item("/w/big", { bytes: 3 * GB, repository: "/Users/me/src/zeta" }),
      item("/w/live", { stale: false, verdict: { action: "keep", reason: "a live session uses it" } }),
      item("/w/dirty", { stale: false, verdict: { action: "keep", reason: "uncommitted work" } }),
      { nope: true },
    ],
    freed: 0,
    reclaimable: 4 * GB,
    errors: ["git failed in /w/odd"],
    expired: [],
    autoCleanup: false,
    at: 1,
  },
  last: null,
};

test("a report reply parses; a malformed item or reply is dropped", () => {
  const report = parseStorageReport(reply)!;
  expect(report.items).toHaveLength(5);
  expect(report.pressure).toBe("high");
  expect(report.disk).toEqual({ total: 1000 * GB, available: 212 * GB });
  expect(report.errors).toEqual(["git failed in /w/odd"]);
  // A clean answers the report itself, not `{report, last}`.
  expect(parseStorageReport(reply.report)?.items).toHaveLength(5);
  expect(parseStorageReport(undefined)).toBeUndefined();
  expect(parseStorageReport({ report: { items: "x" } })).toBeUndefined();
});

test("only stale worktrees are rows, the largest first and unmeasured last; the rest are kept with why", () => {
  const { stale, kept } = storageRows(parseStorageReport(reply)!);
  expect(stale.map((row) => row.name)).toEqual(["big", "small", "unmeasured"]);
  expect(stale[0]).toMatchObject({ repository: "zeta", reason: "merged into main", bytes: 3 * GB });
  // A missing size is not measured, never zero.
  expect(stale[2]!.bytes).toBeUndefined();
  expect(kept).toEqual([
    { path: "/w/dirty", name: "dirty", reason: "uncommitted work" },
    { path: "/w/live", name: "live", reason: "a live session uses it" },
  ]);
});

test("grouped rows put each repository's caption over its rows", () => {
  const { stale } = storageRows(parseStorageReport(reply)!);
  const items = groupedRows(stale);
  expect(items.map((entry) => ("caption" in entry ? `# ${entry.caption}` : entry.row.name))).toEqual([
    "# zeta",
    "big",
    "# atlas",
    "small",
    "unmeasured",
  ]);
});

test("the preview counts the checked rows and sums only measured sizes", () => {
  const { stale } = storageRows(parseStorageReport(reply)!);
  const all = new Set(stale.map((row) => row.path));
  expect(storagePreview(stale, all)).toEqual({ count: 3, bytes: 4 * GB, unmeasured: 1 });
  expect(storagePreview(stale, new Set())).toEqual({ count: 0, bytes: 0, unmeasured: 0 });
  const label = previewLabel(storagePreview(stale, all), "en");
  expect(label.values).toEqual({ n: 3 });
  expect(label.size).toEqual({ unmeasured: true, text: storageBytes(4 * GB, "en") });
  // Only unmeasured rows checked: no size at all.
  expect(previewLabel(storagePreview(stale, new Set(["/w/unmeasured"])), "en").size).toBeUndefined();
});

test("sizes read as the pane's file sizes, and a missing one as a dash", () => {
  expect(storageBytes(Math.round(2.1 * GB), "en")).toBe("2.1 GB");
  expect(storageBytes(undefined, "en")).toBe("—");
});

test("selection flips one row or all, and forgets rows that left", () => {
  const { stale } = storageRows(parseStorageReport(reply)!);
  const one = toggled(new Set(), "/w/big");
  expect([...one]).toEqual(["/w/big"]);
  expect(toggled(one, "/w/big").size).toBe(0);
  const all = toggledAll(stale, one);
  expect(all.size).toBe(3);
  expect(toggledAll(stale, all).size).toBe(0);
  const same = new Set(["/w/big"]);
  expect(keptSelection(stale, same)).toBe(same);
  expect([...keptSelection(stale, new Set(["/w/big", "/w/gone"]))]).toEqual(["/w/big"]);
});

test("after a clean, freed rows leave and refused rows keep their place with acpmux's words", () => {
  const { stale } = storageRows(parseStorageReport(reply)!);
  const clean = parseStorageReport({
    ...reply.report,
    applied: true,
    freed: 3 * GB,
    items: [
      item("/w/big", { bytes: 3 * GB, outcome: { ok: true, freed: 3 * GB } }),
      item("/w/small", { bytes: GB, outcome: { ok: false, freed: 0, error: "it changed since the scan; it stays" } }),
    ],
  })!;
  const done = afterClean(stale, clean);
  expect(done.freed).toBe(3 * GB);
  expect(done.stale.map((row) => row.name)).toEqual(["small", "unmeasured"]);
  expect([...done.failed]).toEqual([["/w/small", "it changed since the scan; it stays"]]);
});

test("a worktree asked for and passed over stays, with why, through the read after", () => {
  const before = storageRows(parseStorageReport({ report: { items: [item("/w/a"), item("/w/b")] } })!);
  const clean = parseStorageReport({
    applied: true,
    freed: GB,
    items: [
      item("/w/a", { outcome: { ok: true, freed: GB } }),
      item("/w/b", { stale: false, verdict: { action: "keep", reason: "session lane is open in it" } }),
    ],
  })!;
  const done = afterClean(before.stale, clean, ["/w/a", "/w/b"]);
  expect(done.stale.map((row) => row.path)).toEqual(["/w/b"]);
  expect([...done.failed]).toEqual([["/w/b", "session lane is open in it"]]);
  // The read after counts it as kept; its row stays where the person looks.
  const after = storageRows(
    parseStorageReport({
      report: { items: [item("/w/b", { stale: false, verdict: { action: "keep", reason: "session lane is open in it" } })] },
    })!,
  );
  const shown = withRefused(after, done.stale, done.failed);
  expect(shown.stale.map((row) => row.path)).toEqual(["/w/b"]);
  expect(shown.kept).toEqual([]);
  expect(withRefused(after, done.stale, new Map())).toBe(after);
});

test("the disk's used share stays within 0 and 1", () => {
  expect(usedShare({ total: 100, available: 25 })).toBe(0.75);
  expect(usedShare({ total: 0, available: 0 })).toBe(0);
  expect(usedShare({ total: 100, available: 200 })).toBe(0);
});

test("method not found or a host refusal hides the section; a running pass is busy", () => {
  expect(storageFailure({ code: -32601, message: "Method not found" })).toBe("unsupported");
  expect(storageFailure({ code: "transport.method_refused" })).toBe("unsupported");
  expect(storageFailure({ code: -32603, message: "a worktree cleanup pass or report is already running" })).toBe(
    "busy",
  );
  expect(storageFailure(new Error("socket closed"))).toBe("failed");
  expect(storageFailure(undefined)).toBe("failed");
});
