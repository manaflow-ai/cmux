import { describe, expect, test } from "bun:test";
import { GUEST_CMUX, aggregate, gapLine, gapSchedule, guestLine, integrate, markdownTable, parseGuestUpdate, stalePauseAbMachines, type MachineResult } from "./pause-ab.ts";

describe("gapSchedule", () => {
  test("same seed, same gaps, only from the choices", () => {
    const a = gapSchedule(7, 8, [20, 45, 90, 180]);
    expect(a).toEqual(gapSchedule(7, 8, [20, 45, 90, 180]));
    expect(a).toHaveLength(8);
    for (const g of a) expect([20, 45, 90, 180]).toContain(g);
    expect(gapSchedule(8, 8, [20, 45, 90, 180])).not.toEqual(a);
  });
});

describe("integrate", () => {
  test("each sample holds until the next; paused is only `paused`", () => {
    const s = [{ at: 0, status: "running" }, { at: 10_000, status: "pausing" }, { at: 15_000, status: "paused" }, { at: 45_000, status: "starting" }, { at: 50_000, status: "running" }];
    expect(integrate(s, 0, 60_000)).toEqual({ awake_s: 30, paused_s: 30, pauses: 1 });
  });
  test("a sample before the window carries in", () => {
    expect(integrate([{ at: 0, status: "paused" }, { at: 20_000, status: "running" }], 10_000, 30_000)).toEqual({ awake_s: 10, paused_s: 10, pauses: 0 });
  });
});

const machine = (arm: string, awake: number, paused: number, resumes: (number | null)[], adv: boolean): MachineResult => ({
  arm, name: `pause-ab-x-${arm}-1`, id: "vm", effective_policy: arm, policy_refused: null, capabilities: adv ? ["activity-turn-end"] : [],
  turn_end_advertised: adv, daemon_version: null, guest_update_start: null, guest_update_end: null, turns_ok: resumes.length,
  turns: resumes.map((ms, i) => ({ turn: i + 1, gap_s: 20, resumed: ms !== null, resume_ms: ms, reply_ms: 1000 })),
  tail_kept: null, samples: [], awake_s: awake, paused_s: paused, pauses: 0, error: null,
});

describe("aggregate", () => {
  test("sums per arm and averages resume latency", () => {
    const rows = aggregate([machine("turn_end", 100, 300, [null, 2000, 4000], true), machine("turn_end", 50, 350, [null, 3000], true), machine("aggressive", 200, 200, [null, 1000], false)], ["turn_end", "aggressive"]);
    expect(rows[0]).toMatchObject({ arm: "turn_end", machines: 2, awake_s: 150, paused_s: 650, resumes: 3, mean_resume_ms: 3000, turn_end_advertised: "2/2", turns_ok: "5/5" });
    expect(rows[1]).toMatchObject({ arm: "aggressive", awake_pct: 50, resumes: 1, mean_resume_ms: 1000, turn_end_advertised: "0/1" });
    expect(markdownTable(rows).split("\n")).toHaveLength(4);
  });
});

describe("stalePauseAbMachines", () => {
  test("only our name shape, old tag, idle", () => {
    const now = Date.UTC(2026, 10, 24, 20);
    const old = (now - 4 * 3_600_000).toString(36);
    const fresh = (now - 60_000).toString(36);
    const rows = [
      { id: "a", name: `pause-ab-${old}-turn_end-1`, status: "paused" },
      { id: "b", name: `pause-ab-${fresh}-aggressive-1`, status: "running" },
      { id: "c", name: `my-machine`, status: "paused" },
      { id: "d", name: `pause-ab-${old}-aggressive-2`, status: "running", last_active_at: now - 60_000 },
    ];
    expect(stalePauseAbMachines(rows, now).map((r) => r.id)).toEqual(["a"]);
  });
});

describe("parseGuestUpdate", () => {
  test("keeps binary, applied commit, outcome and channel apart", () => {
    const status = { channel: "https://example.test/ch.json", off: null, current: 3, cmux_tui: "/opt/cmux/store/abc/cmux-tui",
      pending: null, state: { applied_commit: "cf0a8e7", last: "up to date", last_at: 1795550000 } };
    const g = parseGuestUpdate(`@@exit 0\n${JSON.stringify(status)}\n`);
    expect(g).toMatchObject({ exit: 0, error: null, cmux_tui: "/opt/cmux/store/abc/cmux-tui", applied_commit: "cf0a8e7",
      last_outcome: "up to date", channel_url: "https://example.test/ch.json", current_generation: 3 });
    expect(guestLine("m", g)).toContain("applied cf0a8e7");
  });
  test("a refused sudo is an error, not unknown", () => {
    const g = parseGuestUpdate("@@exit 1\nsudo: a password is required\n");
    expect(g.exit).toBe(1);
    expect(g.error).toContain("password is required");
    expect(guestLine("m", g)).toContain("ERROR");
  });
  test("no output at all says so", () => {
    expect(parseGuestUpdate("").error).toContain("no output");
  });
});

describe("idle decision per gap", () => {
  test("the guest cmux is the supervisor's own path, never a bare name sudo cannot find", () => {
    expect(GUEST_CMUX).toContain("/opt/cmux/current/bin/cmux");
  });
  test("a gap row names the keep reason and listeners; pipes are escaped", () => {
    const t = { turn: 2, gap_s: 180, resumed: false, resume_ms: null, reply_ms: 10, kept: 'status running; kept by {"why":"workload","ports":[39735]}', listeners: '127.0.0.1:39735 users:(("python3",pid=9,fd=3))|x' };
    const line = gapLine("pause-ab-x-turn_end-1", t);
    expect(line).toContain('"why":"workload"');
    expect(line).toContain("39735");
    expect(line).toContain("\\|x");
    expect(gapLine("m", { turn: 1, gap_s: 20, resumed: false, resume_ms: null, reply_ms: null })).toBe("| m | 1 | 20 | n/a | n/a |");
  });
});
