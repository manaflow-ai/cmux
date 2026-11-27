import { describe, expect, test } from "bun:test";
import { CAPACITY_PREFLIGHT_STEP, capacityHeadroom, capacityPreflight } from "./cloud-journey";
import { runJourney } from "./cloud-journey-fake";

// cmux-platform journey-after-deploy.sh's capacity pattern: a preflight red must read as capacity (verdict not-run).
const INFRA = /cloud\.(rate_limited|[a-z_]*quota[a-z_]*|[a-z_]*capacity[a-z_]*)\b/;
const plan = (active: number, max: number, extra: Record<string, unknown> = {}) => ({ limits: { max_active: max }, usage: { active }, ...extra });

describe("capacity preflight names what is short before any create", () => {
  test("room, no room, a cap below the need, the spend cap", () => {
    expect(capacityHeadroom(plan(3, 5), 2, "t")).toEqual({ ok: true, detail: "quota_headroom:t used 3/5, need 2: room" });
    const full = capacityHeadroom(plan(5, 5), 2, "team_x");
    expect(full).toEqual({ ok: false, final: false, reason: "cloud.quota.headroom quota_headroom:team_x used 5/5, need 2" });
    expect(capacityHeadroom(plan(0, 1), 2, "t")).toMatchObject({ ok: false, final: true, reason: expect.stringContaining("quota_cap:t max_active 1 < need 2") });
    expect(capacityHeadroom(plan(0, 5, { spend_cap: { state: "at_cap", spent_usd: 10, cap_usd: 10 } }), 1, "t")).toMatchObject({ ok: false, final: true, reason: expect.stringContaining("spend_cap:t at cap") });
    for (const h of [full, capacityHeadroom(plan(0, 1), 2, "t")]) expect(h.ok ? "" : h.reason).toMatch(INFRA);
  });

  test("an answer with no counts is not judged", () => {
    expect(capacityHeadroom({}, 2, "t").ok).toBe(true);
  });

  test("waits for room within the budget, then names the shortfall", async () => {
    let clock = 0;
    const pause = async (ms: number) => { clock += ms; };
    const now = () => clock;
    const answers = [plan(5, 5), plan(5, 5), plan(3, 5)];
    const got = await capacityPreflight(async () => answers.shift(), 2, "t", 240_000, pause, now);
    expect(got.detail).toBe("quota_headroom:t used 3/5, need 2: room (after 30 s, 3 reads)");
    clock = 0;
    await expect(capacityPreflight(async () => plan(5, 5), 2, "t", 60_000, pause, now)).rejects.toThrow(/quota_headroom:t used 5\/5, need 2 \(no room after 60 s, 5 reads\)/);
  });

  test("a final shortfall throws without waiting; a failed read never fails the run", async () => {
    let paused = 0;
    await expect(capacityPreflight(async () => plan(0, 1), 2, "t", 240_000, async () => { paused++; })).rejects.toThrow(/quota_cap/);
    expect(paused).toBe(0);
    const r = await capacityPreflight(async () => { throw new Error("HTTP 500"); }, 2, "t");
    expect(r.detail).toContain("not judged");
  });

  test("the journey runs the preflight before its create, and a full cap stops it before any create", () => {
    const ok = runJourney({ spare: "report", exec: "ok" });
    const names = ok.steps.map((s) => s.step);
    expect(names.indexOf(CAPACITY_PREFLIGHT_STEP)).toBeGreaterThan(-1);
    expect(names.indexOf(CAPACITY_PREFLIGHT_STEP)).toBeLessThan(names.indexOf("create machine"));
    expect(ok.steps.find((s) => s.step === CAPACITY_PREFLIGHT_STEP)?.status).toBe("pass");

    const full = runJourney({ spare: "report", exec: "ok", plan: { limits: { max_active: 0 }, usage: { active: 0 } } });
    const pre = full.steps.find((s) => s.step === CAPACITY_PREFLIGHT_STEP);
    expect(pre?.status).toBe("fail");
    expect(pre?.detail).toContain("quota_cap:");
    expect(full.log).not.toContain("create");
    expect(full.steps.some((s) => s.step === "create machine")).toBe(false);
  });
});
