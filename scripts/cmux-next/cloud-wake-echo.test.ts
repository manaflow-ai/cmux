import { expect, test } from "bun:test";
import { causeOf, phasesOf, runWakeEcho, settle, startWithRetry, summarize, wakeEchoMarkdown, type WakeCycle } from "./cloud-wake-echo.ts";

const cycle = (i: number, ok: boolean, marks: WakeCycle["marks_ms"]): WakeCycle => ({
  i, ok, error: ok ? "" : "boom", at: "", paused_ms: 1, answered_ms: 1, first_exec_ms: 1, offset_ms: 0, offset_rtt_ms: 1, offset_pre_ms: 0,
  marks_ms: marks, phases: phasesOf(marks).phases, warnings: [], guest: null, state_json: false, state_wake: null,
});

test("net_up and pty_attach both count from resumed (they run side by side); echo from max(input, attach)", () => {
  const { phases } = phasesOf({ resumed: 1000, net_up: 1500, pty_attach: 1700, input: 1690, echo: 1750 });
  expect(phases).toEqual({ restore: 1000, net_up: 500, pty_attach: 700, echo: 50, total: 1750 });
  // Run 45475656502's shape: the attach lands before the network is up. Neither phase goes negative.
  const early = phasesOf({ resumed: 1000, net_up: 1080, pty_attach: 1020, input: 1020, echo: 1023 });
  expect(early.phases).toMatchObject({ net_up: 80, pty_attach: 20 });
  expect(early.warnings).toEqual([]);
  // net up before the guest ran again (clock error): negative and warned.
  const odd = phasesOf({ resumed: 1000, net_up: 900, pty_attach: 1100, input: 1100, echo: 1120 });
  expect(odd.phases.pty_attach).toBe(100);
  expect(odd.warnings.length).toBe(1);
});

test("causes: a lost terminal is the product's, counted apart from machine-state failures", () => {
  expect(causeOf({ error: 'guest probe: attach: RuntimeError: attach refused: {"error": "unknown surface 6"}', guest: { surface_lost: { same_daemon: true } } })).toBe("daemon lost the terminal across the wake (product)");
  expect(causeOf({ error: "x", guest: { surface_lost: { same_daemon: false } } })).toBe("daemon restarted across the wake (product)");
  expect(causeOf({ error: "machine read pausing before the cycle", guest: null })).toBe("machine state");
});

test("settle waits out pausing by a deadline", async () => {
  const seq = ["pausing", "pausing", "paused"];
  let t = 0;
  expect(await settle(async () => seq.shift() ?? "paused", 10_000, async (ms) => { t += ms; }, () => t)).toBe("paused");
  await expect(settle(async () => "pausing", 2_000, async (ms) => { t += ms; }, () => t)).rejects.toThrow(/did not settle/);
});

test("a cycle after a pausing read settles, wakes and runs; a failure streak reports a stop", async () => {
  let status = "pausing";
  const reads: string[] = [];
  const stops: string[] = [];
  const cycles = await runWakeEcho({
    exec: async () => ({ code: 1, stdout: "", stderr: "down" }),
    guest: "", netHost: "h", netPort: 443, holdMs: 0, log: () => {}, onCycle: () => {}, onStop: (w) => stops.push(w),
    status: async () => { reads.push(status); const s = status; if (status === "pausing") status = "paused"; return s; },
    pause: async () => 0, wake: async () => { status = "running"; }, sleep: async () => {}, failStreak: 2, settleMs: 1_000,
  }, 5);
  // pausing, then paused: woken, read running, and the cycle goes on (to its arm, which this fake exec fails).
  expect(reads.slice(0, 3)).toEqual(["pausing", "paused", "running"]);
  expect(cycles.length).toBe(2);
  expect(cycles[0]!.error).toMatch(/^arm:/);
  expect(stops).toEqual(["2 failed cycles in a row after 2 of 5"]);
});

test("failed cycles count apart; percentiles over echoed; biggest phase", () => {
  const cs = [cycle(0, true, { resumed: 1000, net_up: 1100, pty_attach: 1200, input: 1200, echo: 1250 }), cycle(1, false, {}), cycle(2, true, { resumed: 3000, net_up: 3100, pty_attach: 3200, input: 3200, echo: 3250 })];
  const s = summarize(cs);
  expect([s.cycles, s.echoed, s.failed, s.biggest]).toEqual([3, 2, 1, "restore"]);
  expect(s.rows.find((r) => r.phase === "total")).toMatchObject({ n: 2, p50: 1250, p95: 3250 });
  expect(wakeEchoMarkdown(cs, { machine: "m" })).toContain("#1 (other): boom");
});

test("start retries an indeterminate answer with the same key, and a pausing refusal after it settles with a new one", async () => {
  let t = 0;
  const sleep = async (ms: number) => { t += ms; };
  let n = 0;
  const keys: string[] = [];
  const answers = [
    { status: 200, body: { ok: false, error: { code: "mutation.indeterminate", retryable: true } } },
    { status: 200, body: { ok: false, error: { code: "cloud.machine.not_paused", retryable: false, details: { state: "pausing" } } } },
    { status: 200, body: { ok: true } },
  ];
  const states = ["pausing", "paused"];
  const notes = await startWithRetry(async (key) => { keys.push(key); return answers.shift()!; }, () => `k${n++}`, async () => states.shift() ?? "paused", 60_000, sleep, () => t);
  expect(keys).toEqual(["k0", "k0", "k1"]);
  expect(notes.length).toBe(2);
  await expect(startWithRetry(async () => ({ status: 200, body: { ok: false, error: { code: "cloud.machine.not_found", retryable: false } } }), () => "k", async () => "paused", 60_000, sleep, () => t)).rejects.toThrow(/not_found/);
});

test("prefetch A/B: even cycles are on, tables split by arm, and slow restores show the platform's share", async () => {
  const { armOf, serverTimingSplit, summarizeArms } = await import("./cloud-wake-echo.ts");
  expect([0, 1, 2, 3].map(armOf)).toEqual(["on", "off", "on", "off"]);
  const on = { ...cycle(0, true, { resumed: 4000, pty_attach: 4100, input: 4100, echo: 4120 }), arm: "on" as const, server_timing: { provider: 3000, vmapi: 1500, total: 5200 } };
  on.guest = { prefetch: { touched: 1000, ms: 300, cut: false } };
  const off = { ...cycle(1, true, { resumed: 1500, pty_attach: 1900, input: 1900, echo: 1950 }), arm: "off" as const, server_timing: { provider: 900, total: 1400 } };
  const arms = summarizeArms([on, off]);
  expect(arms.map((a) => a.arm)).toEqual(["on", "off"]);
  expect(arms[0]!.prefetch).toMatchObject({ n: 1, pages_p50: 1000, ms_p50: 300 });
  expect(arms[1]!.prefetch).toBeNull();
  const st = serverTimingSplit([on, off]);
  expect(st.slow).toEqual([{ i: 0, restore: 4000, answered: 1, server_timing: on.server_timing, ours: 2200, outside: -5199, after_answer: 3999 }]);
  expect(st.slowest.map((r) => r.i)).toEqual([0]);
  const md = wakeEchoMarkdown([on, off], { machine: "m" });
  expect(md).toContain("### By prefetch arm");
  expect(md).toContain("| #0 | 4.00 |");
  expect(md).toContain("The slowest 10% of restores (1)");
  // A run without the A/B prints no arm table.
  expect(wakeEchoMarkdown([cycle(0, true, { resumed: 1, echo: 2 })], {})).not.toContain("By prefetch arm");
});

test("the on arm's arm file names the prefetch and every cycle records a plan before its pause", async () => {
  const cmds: string[] = [];
  let status = "running";
  const cycles = await runWakeEcho({
    exec: async (c) => {
      cmds.push(c);
      if (c.includes("@@plan")) return { code: 0, stdout: '@@plan {"procs":3,"pages":10}\n@@probe 9', stderr: "" };
      if (c.startsWith("date")) return { code: 0, stdout: `${Date.now()}`, stderr: "" };
      if (c.includes("result.")) return { code: 0, stdout: `{"resumed_wall":${Date.now()},"echo_at":${Date.now() + 5},"pty_attach_at":${Date.now()},"prefetch":{"touched":10,"ms":1}}`, stderr: "" };
      return { code: 0, stdout: "", stderr: "" };
    },
    guest: "", netHost: "h", netPort: 443, holdMs: 0, log: () => {}, onCycle: () => {}, prefetchBin: "/tmp/wake-echo/cmux-resume-prefetch",
    status: async () => status,
    pause: async () => { status = "paused"; return 1; },
    wake: async () => { status = "running"; return { retries: [], serverTiming: { provider: 5, total: 9 }, serverTimingHeader: "provider;dur=5, total;dur=9" }; },
    sleep: async () => {},
  }, 2);
  expect(cycles.map((c) => [c.arm, c.ok, c.plan?.pages, c.server_timing?.total, c.server_timing_header])).toEqual([["on", true, 10, 9, "provider;dur=5, total;dur=9"], ["off", true, 10, 9, "provider;dur=5, total;dur=9"]]);
  const arms = cmds.filter((c) => c.includes("> /tmp/wake-echo/arm"));
  expect(arms[0]).toContain('"prefetch":"/tmp/wake-echo/cmux-resume-prefetch"');
  expect(arms[1]).not.toContain('"prefetch"');
});

test("a probe gap that ended before wake_at fails the cycle as the harness's, never counted as an echo", () => {
  expect(causeOf({ error: "the probe's gap ended 9517 ms before wake_at: not this wake", guest: null })).toBe("probe fired before the wake (harness)");
});

test("wake on intent: the key lands lead ms after the wake; before ready it waits for echo, after it takes the echo phase", async () => {
  const { keyToEcho, intentArms, falseWakeCost, intentMarkdown } = await import("./cloud-wake-echo.ts");
  const c = { ...cycle(0, true, { resumed: 3000, pty_attach: 3400, input: 3400, echo: 3450 }), arm: "off" as const, answered_ms: 1000, paused_ms: 2000 };
  c.phases = { ...c.phases, restore: 3000 };
  // Baseline: the typing prewarm wakes at the key: wake-to-first-echo.
  expect(keyToEcho(c, 0)).toBe(3450);
  // A key 1 s after the hint waits for the guest: 2.45 s.
  expect(keyToEcho(c, 1000)).toBe(2450);
  // A key after the guest is ready sees only the echo phase.
  expect(keyToEcho(c, 5000)).toBe(50);
  expect(keyToEcho({ ...c, ok: false }, 1000)).toBeNull();
  const on = { ...c, i: 1, arm: "on" as const, marks_ms: { ...c.marks_ms, echo: 2450, input: 2400 } };
  const arms = intentArms([c, on], 1000);
  expect(arms.map((a) => [a.arm, a.n, a.p50])).toEqual([["baseline", 1, 3450], ["prefetch", 1, 2450], ["wake-on-intent", 1, 2450], ["both", 1, 1450]]);
  // Wait to running (3 - 1 s) + the 30 s bound + the 2 s pause.
  expect(falseWakeCost([c]).p50).toBe(34000);
  expect(intentMarkdown([c, on], [1000])).toContain("| 1.00 | both | 1 | 1.45 | 1.45 | 0/1 |");
  expect(wakeEchoMarkdown([c, on], {})).toContain("Wake on intent");
});
