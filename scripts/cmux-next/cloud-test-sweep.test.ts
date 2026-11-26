import { describe, expect, test } from "bun:test";
import { stalePicks, statusCounts, summaryMarkdown } from "./cloud-test-sweep.ts";

const H = 3_600_000;
const NOW = 1_800_000_000_000;
const DAY = 24 * H;
const row = (id: string, status: string, ageH: number, lastActiveAgoH: number | null = null, creator = "u1") => ({
  id,
  name: `cloud preclaim ${id}`,
  status,
  creator,
  created_at: NOW - ageH * H,
  last_active_at: lastActiveAgoH === null ? null : NOW - lastActiveAgoH * H,
});

describe("stalePicks", () => {
  test("picks paused or failed machines older than the window, keeps younger ones", () => {
    const ids = stalePicks([row("a", "paused", 30), row("b", "paused", 23), row("c", "failed", 48), row("d", "stopped", 25)], NOW, DAY).map((p) => p.id);
    expect(ids).toEqual(["a", "c", "d"]);
  });

  test("a running machine goes only when its last activity is past the window", () => {
    const ids = stalePicks([row("idle", "running", 72, 30), row("busy", "running", 72, 2), row("unknown", "running", 72, null), row("young", "starting", 5, null)], NOW, DAY).map((p) => p.id);
    expect(ids).toEqual(["idle"]);
  });

  test("deleted, deleting, unknown statuses and rows without created_at are kept", () => {
    const rows = [row("x", "deleted", 99), row("y", "deleting", 99), row("z", "migrating", 99), { id: "w", status: "paused" }, { status: "paused", created_at: NOW - 99 * H }];
    expect(stalePicks(rows, NOW, DAY)).toEqual([]);
  });

  test("on a shared team only the given creator's machines are picked", () => {
    const ids = stalePicks([row("mine", "paused", 30, null, "u1"), row("theirs", "paused", 30, null, "u2"), { ...row("none", "paused", 30), creator: undefined }], NOW, DAY, "u1").map((p) => p.id);
    expect(ids).toEqual(["mine"]);
  });

  test("a pick records why and when, in ISO time", () => {
    const [p] = stalePicks([row("a", "paused", 30)], NOW, DAY);
    expect(p.created).toBe(new Date(NOW - 30 * H).toISOString());
    expect(p.why).toContain("paused");
  });
});

test("statusCounts and the summary table list every pick", () => {
  const rows = [row("a", "paused", 30), row("b", "running", 1)];
  expect(statusCounts(rows)).toEqual({ paused: 1, running: 1 });
  const md = summaryMarkdown({ backend: "staging", dry_run: false, min_age_hours: 24, scopes: [{ scope: "personal", before: statusCounts(rows), picks: [{ ...stalePicks(rows, NOW, DAY)[0], ok: true, error: null }] }] });
  expect(md).toContain("| personal | a | cloud preclaim a | paused |");
  expect(md).toContain("deleted");
});
