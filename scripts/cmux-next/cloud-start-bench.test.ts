import { describe, expect, test } from "bun:test";
import { staleJourneyMachines } from "./cloud-journey";
import { answeredPath, MachineFailed, quantile, type StartTarget, startBenchMarkdown, summarize, timeStart } from "./cloud-start-bench";

/** A clock the target's calls move: each call costs what the script says, sleeps cost their ms. */
function fakeClock() {
  let t = 0;
  return { clock: { now: () => t, sleep: async (ms: number) => { t += ms; } }, advance: (ms: number) => { t += ms; } };
}

describe("the start bench times each phase from the create call", () => {
  test("answer, running, first exec and daemon are cumulative, and the machine is removed", async () => {
    const { clock, advance } = fakeClock();
    let reads = 0;
    let execs = 0;
    const removed: string[] = [];
    const target: StartTarget = {
      path: "cold",
      create: async () => { advance(2_000); return { machine: "m1", path: "cold", facts: { spare_fallback: "no_spare" } }; },
      running: async () => { advance(100); return ++reads >= 3; },
      exec: () => async (command) => {
        advance(300);
        execs++;
        if (command === "echo ok") return execs >= 2 ? { code: 0, stdout: "ok\n", stderr: "" } : { code: -1, stdout: "", stderr: "502" };
        return { code: 0, stdout: "daemon-ok\n", stderr: "" };
      },
      daemon: true,
      remove: async (m) => { removed.push(m); },
    };
    const s = await timeStart(target, 0, clock);
    expect(s.ok).toBe(true);
    // create 2000; three reads of 100 with two 500 ms polls between: 2000+300+1000 = 3300
    expect(s.ms.answer).toBe(2_000);
    expect(s.ms.running).toBe(3_300);
    // a failed exec (300) + poll (500) + an answered one (300)
    expect(s.ms.exec).toBe(4_400);
    expect(s.ms.daemon).toBe(4_700);
    expect(s.exec_attempts).toBe(2);
    expect(removed).toEqual(["m1"]);
  });

  test("a create that took a spare is a spare sample, whatever was asked", async () => {
    const { clock } = fakeClock();
    const target: StartTarget = {
      path: "cold",
      create: async () => ({ machine: "m2", path: "spare" }),
      running: async () => true,
      exec: () => async () => ({ code: 0, stdout: "ok", stderr: "" }),
      remove: async () => {},
    };
    const s = await timeStart(target, 1, clock);
    expect(s.path).toBe("spare");
    expect(s.asked).toBe("cold");
    expect(s.ms.daemon).toBeNull();
  });

  test("a phase past the budget fails the sample, keeps the earlier phases and still removes the machine", async () => {
    const { clock } = fakeClock();
    const removed: string[] = [];
    const target: StartTarget = {
      path: "snapshot",
      create: async () => ({ machine: "m3" }),
      running: async () => false,
      exec: () => async () => ({ code: 0, stdout: "ok", stderr: "" }),
      remove: async (m) => { removed.push(m); },
    };
    const s = await timeStart(target, 0, clock, 5_000);
    expect(s.ok).toBe(false);
    expect(s.ms.answer).toBe(0);
    expect(s.ms.running).toBeNull();
    expect(s.error).toContain("not running");
    expect(removed).toEqual(["m3"]);
  });
});

describe("the start bench summary", () => {
  test("p50 and p90 by nearest rank, per path, over the samples that reached the phase", () => {
    expect(quantile([5, 1, 4, 2, 3], 0.5)).toBe(3);
    expect(quantile([5, 1, 4, 2, 3], 0.9)).toBe(5);
    expect(quantile([], 0.5)).toBeNull();
    const base = { asked: "spare" as const, ok: true, error: null, exec_attempts: 1, daemon_attempts: 1, facts: {} };
    const samples = [1, 2, 3].map((i) => ({ ...base, path: "spare" as const, run: i, ms: { answer: i * 100, running: i * 200, exec: i * 1000, daemon: i === 3 ? null : i * 2000 } }));
    const [spare] = summarize(samples);
    expect(spare!.samples).toBe(3);
    expect(spare!.phases.exec).toEqual({ p50: 2000, p90: 3000 });
    expect(spare!.phases.daemon).toEqual({ p50: 2000, p90: 4000 });
    const md = startBenchMarkdown(samples);
    expect(md).toContain("| spare | 3 | 0 | 0.2 s / 0.3 s | 0.4 s / 0.6 s | 2.0 s / 3.0 s | 2.0 s / 4.0 s |");
  });

  test("a platform create's answer names its path", () => {
    expect(answeredPath({ machine: "m", claim: { behind: false } })).toBe("spare");
    expect(answeredPath({ machine: "m", spare_fallback: "no_spare" })).toBe("cold");
    expect(answeredPath({ machine: "m" })).toBeNull();
  });
});

describe("the start bench leaves nothing behind", () => {
  test("a machine that failed ends its sample at once, and is still removed", async () => {
    const { clock } = fakeClock();
    const removed: string[] = [];
    const target: StartTarget = {
      path: "cold",
      create: async () => ({ machine: "m4" }),
      running: async () => { throw new MachineFailed("machine failed"); },
      exec: () => async () => ({ code: 0, stdout: "ok", stderr: "" }),
      remove: async (m) => { removed.push(m); },
    };
    const s = await timeStart(target, 0, clock, 300_000);
    expect(s.ok).toBe(false);
    expect(s.error).toBe("machine failed");
    // No poll ran: the failure ended the sample before the budget.
    expect(clock.now()).toBe(0);
    expect(removed).toEqual(["m4"]);
  });

  test("the leaked-machine sweep takes a killed bench's machines, by their exact names only", () => {
    const old = Date.UTC(2026, 10, 1);
    const tag = `jr-${old.toString(36)}`;
    const rows = [
      { id: "a", name: `cloud start bench ${tag} spare 0`, status: "running" },
      { id: "b", name: `cloud start bench ${tag} source`, status: "running" },
      { id: "c", name: `cloud start bench ${tag} snapshot 4`, status: "paused" },
      { id: "d", name: `cloud start bench ${tag} mine`, status: "running" },
      { id: "e", name: `my cloud start bench ${tag} cold 1`, status: "running" },
    ];
    expect(staleJourneyMachines(rows, Date.UTC(2026, 10, 17)).map((m) => m.id)).toEqual(["a", "b", "c"]);
  });
});
