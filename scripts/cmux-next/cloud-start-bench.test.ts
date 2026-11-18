import { describe, expect, test } from "bun:test";
import { staleJourneyMachines } from "./cloud-journey";
import { answeredPath, answerTimings, MachineFailed, pickVmApiTenant, quantile, type StartSample, type StartTarget, startBenchMarkdown, summarize, timeStart, traceFacts, traceStepSummary } from "./cloud-start-bench";

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

describe("the VM API tenant for a Stack session", () => {
  const team = (id: string, personal = false) => ({ id, display_name: "x", ...(personal ? { client_read_only_metadata: { cmuxVmPersonalTenant: true } } : {}) });
  test("the user's cmux VM personal tenant first, then the selected team, then the first", () => {
    expect(pickVmApiTenant({ items: [team("a"), team("p", true), team("s")] }, "s")).toEqual({ team: "p", via: "the user's cmux VM personal tenant" });
    expect(pickVmApiTenant({ items: [team("a"), team("s")] }, "s")).toEqual({ team: "s", via: "the user's selected Stack team" });
    expect(pickVmApiTenant({ items: [team("a"), team("b")] }, "gone")).toEqual({ team: "a", via: "the user's first Stack team" });
  });
  test("no Stack team, or no list, names why instead of a team the VM API refuses", () => {
    const none = pickVmApiTenant({ items: [] }, null);
    expect(none.team).toBeNull();
    expect("why" in none && none.why).toContain("no Stack team");
    expect(pickVmApiTenant({ error: "x" }, null).team).toBeNull();
    // A malformed id is never sent as X-Cmux-Team-Id.
    expect(pickVmApiTenant({ items: [{ id: "a b" }, { id: 7 }] }, null).team).toBeNull();
  });
});

describe("the platform's create trace", () => {
  const sample = (path: StartSample["path"], trace: unknown): StartSample => ({
    path, asked: path, run: 0, ok: true, error: null, ms: { answer: 1, running: 2, exec: 3, daemon: 4 }, exec_attempts: 1, daemon_attempts: 1,
    facts: trace === undefined ? {} : { trace },
  });
  test("traceFacts keeps the createTrace's numeric steps and reads null without one", () => {
    const view = { id: "vm_1", createTrace: { attempt: 1, outcome: "spare_claim", steps: { capability: 1, budget: 120, adopt: 700, bad: "x" }, totalMs: 702 } };
    expect(traceFacts(view)).toEqual({ outcome: "spare_claim", attempt: 1, totalMs: 702, steps: { capability: 1, budget: 120, adopt: 700 } });
    expect(traceFacts({ id: "vm_1" })).toBeNull();
    expect(traceFacts(null)).toBeNull();
    expect(traceFacts({ createTrace: { steps: {} } })).toBeNull();
  });
  test("p50 per step per path, and a table under the bench only when a sample has a trace", () => {
    const t = (adopt: number, total: number) => ({ outcome: "spare_claim", attempt: 1, totalMs: total, steps: { capability: 1, adopt } });
    const samples = [sample("spare", t(100, 110)), sample("spare", t(300, 310)), sample("spare", t(200, 210)), sample("cold", undefined), sample("vm-api-cold", undefined)];
    expect(traceStepSummary(samples)).toEqual([{ path: "spare", traced: 3, steps: [{ step: "capability", p50: 1 }, { step: "adopt", p50: 200 }, { step: "totalMs", p50: 210 }] }]);
    const md = startBenchMarkdown(samples);
    expect(md).toContain("| spare | 3 | adopt | 200 ms |");
    expect(startBenchMarkdown([sample("cold", undefined)])).not.toContain("create trace");
  });
  test("the trace is read untimed before the remove, and a failed read never fails the sample", async () => {
    const { clock, advance } = fakeClock();
    const order: string[] = [];
    const base: StartTarget = {
      path: "spare",
      create: async () => { advance(1_000); return { machine: "m1" }; },
      running: async () => true,
      exec: () => async () => ({ code: 0, stdout: "ok daemon-ok", stderr: "" }),
      daemon: true,
      trace: async () => { order.push("trace"); advance(5_000); return { outcome: "spare_claim", attempt: 1, totalMs: 9, steps: { adopt: 9 } }; },
      remove: async () => { order.push("remove"); },
    };
    const s = await timeStart(base, 0, clock);
    expect(s.ok).toBe(true);
    expect(s.ms.daemon).toBe(1_000);
    expect(s.facts.trace).toEqual({ outcome: "spare_claim", attempt: 1, totalMs: 9, steps: { adopt: 9 } });
    expect(order).toEqual(["trace", "remove"]);
    const failed = await timeStart({ ...base, trace: async () => { throw new Error("403"); } }, 1, clock);
    expect(failed.ok).toBe(true);
    expect(failed.facts.trace).toBeUndefined();
    expect(failed.facts.trace_missing).toBe("read failed: Error");
    const refused = await timeStart({ ...base, trace: async () => "HTTP 404" }, 2, clock);
    expect(refused.facts.trace).toBeUndefined();
    expect(startBenchMarkdown([refused])).toContain("Samples with no create trace: HTTP 404 (1)");
  });
  test("the create answer's value.timings is kept as a trace and gets its own p50 table", () => {
    const t = answerTimings({ machine: "vm_1", timings: { path: "create", steps: { plan_read: 40, ensure: 2_100, bad: "x" }, total_ms: 2_300 } });
    expect(t).toEqual({ outcome: "create", attempt: null, totalMs: 2_300, steps: { plan_read: 40, ensure: 2_100 } });
    expect(answerTimings({ machine: "vm_1" })).toBeNull();
    const s: StartSample = { ...sample("cold", undefined), facts: { timings: t } };
    expect(traceStepSummary([s], "timings")).toEqual([{ path: "cold", traced: 1, steps: [{ step: "plan_read", p50: 40 }, { step: "ensure", p50: 2_100 }, { step: "totalMs", p50: 2_300 }] }]);
    expect(startBenchMarkdown([s])).toContain("| cold | 1 | ensure | 2100 ms |");
  });
});
