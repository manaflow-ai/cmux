import { describe, expect, test } from "bun:test";
import { deleteMachine, readWithRetry, stalePicks, statusCounts, summaryMarkdown, sweepPicks } from "./cloud-test-sweep.ts";
import { FAILED_JOURNEY_MS, SHORT_JOURNEY_MS } from "./cloud-journey.ts";

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

describe("sweepPicks", () => {
  const tag = (agoMs: number) => `jr-${(NOW - agoMs).toString(36)}`;
  const j = (id: string, name: string, status: string, ageH: number, creator = "u1") => ({ id, name, status, creator, created_at: NOW - ageH * H, last_active_at: null });
  test("adds journey-owned leftovers younger than the window, in any state, under the creator filter (run 46115218791)", () => {
    const rows = [
      row("old", "paused", 30),
      j("jr_paused", `cloud journey auto ${tag(SHORT_JOURNEY_MS + 60_000)}`, "paused", 2),
      j("jr_failed", `cloud journey auto ${tag(FAILED_JOURNEY_MS + 60_000)} cold`, "failed", 1),
      j("jr_young", `cloud journey auto ${tag(SHORT_JOURNEY_MS - 60_000)}`, "paused", 1),
      j("jr_long", `cloud journey auto ${tag(SHORT_JOURNEY_MS + 60_000)} long`, "paused", 2),
      j("jr_theirs", `cloud journey auto ${tag(SHORT_JOURNEY_MS + 60_000)}`, "paused", 2, "u2"),
      j("person", "my dev box", "paused", 2),
    ];
    expect(sweepPicks(rows, NOW, DAY, "u1").map((p) => p.id)).toEqual(["old", "jr_paused", "jr_failed"]);
    expect(sweepPicks(rows, NOW, DAY).map((p) => p.id)).toEqual(["old", "jr_paused", "jr_failed", "jr_theirs"]);
  });
  test("a row both rules take is picked once", () => {
    const rows = [j("both", `cloud journey auto ${tag(30 * H)}`, "paused", 30)];
    expect(sweepPicks(rows, NOW, DAY).map((p) => p.id)).toEqual(["both"]);
  });
});

test("statusCounts and the summary table list every pick", () => {
  const rows = [row("a", "paused", 30), row("b", "running", 1)];
  expect(statusCounts(rows)).toEqual({ paused: 1, running: 1 });
  const md = summaryMarkdown({ backend: "staging", dry_run: false, min_age_hours: 24, scopes: [{ scope: "personal", before: statusCounts(rows), picks: [{ ...stalePicks(rows, NOW, DAY)[0], ok: true, error: null }] }] });
  expect(md).toContain("| personal | a | cloud preclaim a | paused |");
  expect(md).toContain("deleted");
});

describe("readWithRetry", () => {
  const timedOut = { status: 0, body: { ok: false, error: { code: "transport", message: "The operation timed out.", retryable: true } } };
  const answers = (...list: Array<{ status: number; body: any }>) => {
    let i = 0;
    const send = async () => list[Math.min(i++, list.length - 1)];
    return { send, sent: () => i };
  };
  const noWait = async () => {};

  test("a read that timed out once is sent again and its value returned (run 46130928568)", async () => {
    const a = answers(timedOut, { status: 200, body: { ok: true, value: { machines: [] } } });
    expect(await readWithRetry(a.send, "cloud.machine.list", 3, 0, noWait)).toEqual({ machines: [] });
    expect(a.sent()).toBe(2);
  });

  test("a 503 is retried; a non-retryable refusal throws at once", async () => {
    const busy = answers({ status: 503, body: { ok: false, error: { code: "overloaded" } } }, { status: 200, body: { ok: true, value: 1 } });
    expect(await readWithRetry(busy.send, "x", 3, 0, noWait)).toBe(1);
    const denied = answers({ status: 403, body: { ok: false, error: { code: "forbidden" } } });
    await expect(readWithRetry(denied.send, "x", 3, 0, noWait)).rejects.toThrow("x: HTTP 403");
    expect(denied.sent()).toBe(1);
  });

  test("still failing after every try throws, naming the tries", async () => {
    const a = answers(timedOut);
    await expect(readWithRetry(a.send, "cloud.machine.list", 3, 0, noWait)).rejects.toThrow(/HTTP 0 .*transport.*after 3 tries/);
    expect(a.sent()).toBe(3);
  });
});

describe("deleteMachine", () => {
  const indeterminate = { status: 502, body: { ok: false, error: { code: "mutation.indeterminate" } } };
  const ok = { status: 200, body: { ok: true, value: { deleted: true } } };
  const answers = (...list: Array<{ status: number; body: any }>) => {
    let i = 0;
    return { send: async () => list[Math.min(i++, list.length - 1)], sent: () => i };
  };
  const noWait = async () => {};

  test("an indeterminate delete whose machine now reads as deleting or gone counts as deleted (run 46140030779)", async () => {
    for (const after of ["deleting", "deleted", null]) {
      const a = answers(indeterminate);
      const r = await deleteMachine(a.send, async () => after, 3, noWait);
      expect(r).toEqual({ ok: true, error: null });
      expect(a.sent()).toBe(3);
    }
  });

  test("an indeterminate delete whose machine still reads as failed is refused, naming what it read", async () => {
    const a = answers(indeterminate);
    expect(await deleteMachine(a.send, async () => "failed", 3, noWait)).toEqual({ ok: false, error: "mutation.indeterminate (still failed)" });
  });

  test("a delete that lands on a retry, a 404, or a final 4xx is settled without a re-read", async () => {
    let reads = 0;
    const recheck = async () => { reads++; return "failed"; };
    expect(await deleteMachine(answers(indeterminate, ok).send, recheck, 3, noWait)).toEqual({ ok: true, error: null });
    expect(await deleteMachine(answers({ status: 404, body: { ok: false } }).send, recheck, 3, noWait)).toEqual({ ok: true, error: null });
    const denied = answers({ status: 403, body: { ok: false, error: { code: "auth.forbidden" } } });
    expect(await deleteMachine(denied.send, recheck, 3, noWait)).toEqual({ ok: false, error: "auth.forbidden" });
    expect(denied.sent()).toBe(1);
    expect(reads).toBe(0);
  });
});
