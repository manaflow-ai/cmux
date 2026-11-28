import { describe, expect, test } from "bun:test";
import { CAPACITY_PREFLIGHT_STEP, capacityHeadroom, capacityPreflight, createWithRoom, machineSlots, quotaHolders, totalCapStop } from "./cloud-journey";
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

describe("a full cap names the machines that hold it", () => {
  test("live machines newest first, with name, state, age and idle time; deleted ones left out", () => {
    const now = Date.UTC(2026, 10, 27, 10, 0);
    const rows = [
      { id: "vm_old", name: "probe keep", status: "paused", created_at: now - 26 * 3_600_000, last_active_at: now - 25 * 3_600_000 },
      { id: "vm_new", name: "cloud journey auto jr-x", status: "running", created_at: now - 5 * 60_000 },
      { id: "vm_gone", name: "x", status: "deleted", created_at: now },
    ];
    expect(quotaHolders(rows, now)).toBe('2 live: vm_new "cloud journey auto jr-x" running, age 5 min, no activity time; vm_old "probe keep" paused, age 26 h, idle 25 h');
    expect(quotaHolders(rows, now, 1)).toContain("; +1 more");
  });

  // Run 46102010769: "used 6/20 ... room", then create refused 16 times over 241 s: 20 machines in all, paused included.
  const row = (name: string, status: string) => ({ id: `m_${name.replace(/\W/g, "")}_${status}`, name, status, created_at: 0 });
  const paused14 = Array.from({ length: 14 }, (_, i) => row(`chat ${i}`, "paused"));
  const capRefusal = 'cloud.machine.create: HTTP 200 {"code":"cloud.quota.exceeded","message":"this plan allows 20 machines in all, paused ones included; delete one first","details":{"limit":20,"used":20,"resource":"machines","plan":"max"}}';

  test("the machine slot counts paused machines as create does; with none leaving it is final", () => {
    const rows = [...paused14, ...Array.from({ length: 6 }, (_, i) => row(`desk ${i}`, "running")), row("x", "deleted"), { ...row("y", "failed"), no_vm: true }];
    expect(machineSlots(rows)).toEqual({ held: 20, leaving: 0 });
    const p = { limits: { max_active: 20 }, usage: { active: 6 }, max_machines: 20 };
    expect(capacityHeadroom(p, 1, "t", machineSlots(rows))).toMatchObject({ ok: false, final: true, reason: expect.stringContaining("quota_machines:t held 20/20 (paused included), need 1, 0 leaving soon") });
    const journeys = [...paused14, ...Array.from({ length: 6 }, (_, i) => row(`cloud journey auto jr-${(Date.UTC(2026, 10, 28) + i).toString(36)}`, "running"))];
    expect(machineSlots(journeys)).toEqual({ held: 20, leaving: 6 });
    expect(capacityHeadroom(p, 1, "t", machineSlots(journeys))).toMatchObject({ ok: false, final: false });
    expect(capacityHeadroom(p, 1, "t", { held: 19, leaving: 0 })).toMatchObject({ ok: true, detail: expect.stringContaining("machines 19/20") });
    // A plan answer with no max_machines (production before cmux-platform names it) leaves the slot to create.
    expect(capacityHeadroom(plan(6, 20), 1, "t", { held: 20, leaving: 0 })).toEqual({ ok: true, detail: "quota_headroom:t used 6/20, need 1: room" });
  });

  test("a total-cap refusal with nothing leaving ends the create at once, naming the holders; an active-cap one still waits", async () => {
    let clock = 0;
    const pause = async (ms: number) => { clock += ms; };
    const stuck = totalCapStop(async () => [...paused14, ...Array.from({ length: 6 }, (_, i) => row(`desk ${i}`, "running"))], undefined, () => 0);
    let calls = 0;
    await expect(createWithRoom(async () => { calls++; throw new Error(capRefusal); }, 240_000, pause, () => clock, stuck)).rejects.toThrow(/no room coming: .*held 20, leaving 0.*held by 20 live/);
    expect(calls).toBe(1);
    expect(clock).toBe(0);
    // The run's own chat machine never counts as leaving during its cold create.
    const own = "cloud journey jr-abc";
    expect(machineSlots([...paused14, row(own, "running")], own)).toEqual({ held: 15, leaving: 0 });
    const active = 'cloud.machine.create: HTTP 200 {"code":"cloud.quota.exceeded","message":"this plan allows 5 active machines","details":{"resource":"active"}}';
    expect(await stuck(active)).toBeNull();
  });
});
