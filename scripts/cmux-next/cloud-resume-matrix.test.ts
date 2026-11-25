import { describe, expect, test } from "bun:test";
import type { ProviderAdapter } from "./resume-slo-provider.ts";
import { cliExecResult } from "./cloud-journey.ts";
import * as matrix from "./cloud-resume-matrix.ts";
import { armOrder, armUnavailable, awaitPaused, lostPromptFacts, RELAY_REGISTERED, infraCause, largestPhase, productSuspect, cellDeadline, parseAgents, CLIENT_SESSION_MAX_S, CLIENT_SESSION_MIN_S, directSessionPlan, parseServerTiming, parseWakeFacts, percentile, resumeCells, resumeMarkdown, runProviderArm, syncRunning, type ResumeSample } from "./cloud-resume-matrix.ts";

describe("parseWakeFacts", () => {
  test("takes the gap spanning the event and the first relay line after it, guest clock corrected", () => {
    // The guest runs 2000 ms ahead of the runner; the event was at runner time 100_000.
    const t0 = 100_000;
    const out = [
      "@@now 112000", // exec sent 109_900, answered 110_100: midpoint 110_000, offset 2000
      "@@gap 90000 95000", // an earlier freeze: not this wake
      "@@gap 50000 102700", // the pause: spans guest 102_000; running 700 ms after the event
      "@@gap 103000 104500", // a second freeze after it
      "@@j 101.500 cmux-host: relay registration on r1: registered", // before the event: an earlier wake
      "@@j 103.900 cmux-host: relay registration on r1: registered",
      "@@j 102.950 cmux-host: notify event=resumed",
    ].join("\n");
    expect(parseWakeFacts(out, t0, 109_900, 110_100)).toEqual({ offset: 2000, running: 700, registered: 1900, resumed: 950 });
  });
  test("an unreadable guest gives nulls", () => {
    expect(parseWakeFacts("", 1, 2, 3)).toEqual({ offset: null, running: null, registered: null, resumed: null });
  });
});

test("parseServerTiming", () => {
  expect(parseServerTiming("provider;dur=812.4, vmapi;dur=40, total;desc=x;dur=1490")).toEqual({ provider: 812, vmapi: 40, total: 1490 });
  expect(parseServerTiming(null)).toBeUndefined();
});

test("armOrder rotates so no arm always goes first", () => {
  expect(armOrder(["direct", "platform", "send"], 0)).toEqual(["direct", "platform", "send"]);
  expect(armOrder(["direct", "platform", "send"], 1)).toEqual(["platform", "send", "direct"]);
});

test("percentile is nearest rank", () => {
  const xs = Array.from({ length: 20 }, (_, i) => i + 1);
  expect(percentile(xs, 50)).toBe(10);
  expect(percentile(xs, 95)).toBe(19);
  expect(percentile([], 50)).toBeNull();
});

test("resumeMarkdown judges first byte p95 against the direct answer's p95", () => {
  const s = (arm: ResumeSample["arm"], answered: number | null, fb: number): ResumeSample => ({ pause_s: 30, arm, i: 0, machine: "m", at: "", paused_ms: 30_000, answered_ms: answered, running_ms: null, registered_ms: null, first_byte_ms: fb, ack_ms: null, clock_offset_ms: 0, error: "" });
  const md = resumeMarkdown([s("direct", 800, 1500), s("platform", 1200, 2300), s("send", null, 2600)]);
  expect(md).toContain("| 30 s | platform | 1 | 0 | 0 | - | 1.20 / 1.20 | - / - | - / - | 2.30 / 2.30 | 1.50 | - | - |");
  expect(md).toContain("| 30 s | send | 1 | 0 | 0 | - | - / - | - / - | - / - | 2.60 / 2.60 | 1.80 | - |");
});

test("the fill holder ships its python as base64, so no shell or printf reads its % or quotes", () => {
  const { fillStartCommand, TOUCH_COMMAND } = require("./cloud-resume-matrix.ts");
  const b64 = /echo ([A-Za-z0-9+/=]+) \| base64 -d/.exec(fillStartCommand(60))![1];
  const py = Buffer.from(b64, "base64").toString();
  expect(py).toContain("*60/100");
  expect(py).toContain("%256");
  expect(py.split("\n").length).toBeGreaterThan(8);
  expect(TOUCH_COMMAND).toContain("kill -USR1");
});

describe("directSessionPlan", () => {
  test("every ttl it asks is one the client-session route takes (60..900 s; run 45133130690 asked 905 and read 400)", () => {
    for (const pause of [0, 5, 30, 300, 660, 661, 900, 3600, 21_600]) {
      const { ttl } = directSessionPlan(pause);
      expect(ttl).toBeGreaterThanOrEqual(CLIENT_SESSION_MIN_S);
      expect(ttl).toBeLessThanOrEqual(CLIENT_SESSION_MAX_S);
    }
  });
  test("mints before the pause while the hold fits in a session, after it once it does not", () => {
    expect(directSessionPlan(5)).toEqual({ ttl: 245, afterHold: false });
    expect(directSessionPlan(300)).toEqual({ ttl: 540, afterHold: false });
    expect(directSessionPlan(900).afterHold).toBe(true);
    expect(directSessionPlan(3600).afterHold).toBe(true);
  });
});

describe("cliExecResult", () => {
  test("the CLI's JSON answer is the exec's result", () => {
    expect(cliExecResult({ status: 0, signal: null, stdout: '{"exit_code":3,"stdout":"o","stderr":"e"}', stderr: "" })).toEqual({ code: 3, stdout: "o", stderr: "e" });
  });
  test("a CLI killed by a signal says so, with 128 + its number (run 45133130690 read a bare `exit 1`)", () => {
    const r = cliExecResult({ status: null, signal: "SIGILL", stdout: "", stderr: "" });
    expect(r.code).toBe(132);
    expect(r.stderr).toContain("killed by SIGILL");
    expect(r.stderr).toContain("another CPU");
  });
  test("a CLI that exits with no output says it printed nothing; its own output is kept", () => {
    expect(cliExecResult({ status: 1, signal: null, stdout: "", stderr: "" }).stderr).toBe("[the cmux CLI exited 1 and printed nothing]");
    expect(cliExecResult({ status: 2, signal: null, stdout: "", stderr: "error: no such machine\n" })).toEqual({ code: 2, stdout: "", stderr: "error: no such machine\n" });
  });
});

describe("an early stop", () => {
  test("each pause length left gets an even share of the time before the deadline", () => {
    expect(cellDeadline(1_000, 31_000, 3)).toBe(11_000);
    expect(cellDeadline(1_000, 31_000, 1)).toBe(31_000);
    expect(cellDeadline(40_000, 31_000, 2)).toBe(40_000);
    expect(cellDeadline(1_000, undefined, 2)).toBe(Infinity);
  });
  test("the table names each stop and each arm's errors, so a row of failures reads without the job log (run 45147962604)", () => {
    const s = (arm: ResumeSample["arm"], error: string): ResumeSample => ({ pause_s: 5, arm, i: 0, machine: "m", at: "", paused_ms: 5_000, answered_ms: null, running_ms: null, registered_ms: null, first_byte_ms: null, ack_ms: null, clock_offset_ms: 0, error });
    const md = resumeMarkdown([s("send", "no reply within 180 s"), s("send", "no reply within 180 s"), s("direct", "direct start: HTTP 403")], [{ pause_s: 5, arm: "send", after: 2, reason: "2 send samples in a row failed; the last: no reply within 180 s", machine: "m1" }]);
    expect(md).toContain("| 5 s | send | 2 | 2 |");
    expect(md).toContain("- 5 s send (m1): stopped after 2 sample(s): 2 send samples in a row failed");
    expect(md).toContain("- 5 s send: 2x no reply within 180 s");
    expect(md).toContain("- 5 s direct: 1x direct start: HTTP 403");
  });
});

describe("listedMachine (run 45174448964: `vm_... missing from 49 machines` on a shared account of 52)", () => {
  const { listedMachine } = require("./cloud-journey.ts");
  const rows = (a: number, b: number) => Array.from({ length: b - a }, (_, k) => ({ id: `vm_${a + k}`, status: "running" }));
  test("follows next_cursor to the page that holds the machine", async () => {
    const seen: unknown[] = [];
    const list = async (p: any) => { seen.push(p); return p.cursor ? { machines: rows(49, 52) } : { machines: rows(0, 49), next_cursor: "c2" }; };
    const r = await listedMachine("vm_51", list, async () => { throw new Error("not asked"); });
    expect(r.detail).toBe("52 machines");
    expect(seen).toEqual([{ limit: 100 }, { limit: 100, cursor: "c2" }]);
  });
  test("a capped page with no cursor: confirmed by cloud.machine.get, the cap named", async () => {
    const r = await listedMachine("vm_51", async () => ({ machines: rows(0, 49) }), async (id: string) => ({ id, status: "running", size: { cpu: 2 } }));
    expect(r.row.size).toEqual({ cpu: 2 });
    expect(r.detail).toContain("49 machines listed, no next_cursor (a page cap)");
  });
  test("a machine neither read finds fails", async () => {
    await expect(listedMachine("vm_99", async () => ({ machines: rows(0, 3) }), async () => { throw new Error("HTTP 404"); })).rejects.toThrow("vm_99 missing from 3 machines, and cloud.machine.get: HTTP 404");
    await expect(listedMachine("vm_99", async () => ({ machines: rows(0, 3) }), async () => ({ id: "vm_99", status: "deleted" }))).rejects.toThrow("reads deleted");
  });
});

describe("run 45177970049's causes", () => {
  test("a provider with no client sessions makes the direct arm unavailable, not a failed sample", () => {
    expect(armUnavailable("client-session: HTTP 501 {\"code\":\"cloud.provider.unsupported\"}")).toBe(true);
    expect(armUnavailable("direct start: HTTP 403")).toBe(false);
  });
  test("the agent process set reads as pid and start time; an unfinished read is null", () => {
    expect(parseAgents("@@agent 412 9001\n@@agent 77 120\n@@agent 412 9001\n@@agents-read\n")).toEqual(["412 9001", "77 120"]);
    expect(parseAgents("@@agents-read")).toEqual([]);
    expect(parseAgents("@@agent 412 9001")).toBeNull();
  });
  test("the table shows restored k/n, each error's cause, the provider and turns that did not complete", () => {
    const base: ResumeSample = { pause_s: 5, arm: "platform", i: 0, machine: "m", at: "", paused_ms: 5_000, answered_ms: 900, running_ms: 800, registered_ms: null, first_byte_ms: 2_000, ack_ms: null, clock_offset_ms: 0 };
    const md = resumeMarkdown([
      { ...base, restored: true },
      { ...base, i: 1, restored: false, turn: "Not logged in" },
      { ...base, i: 2, answered_ms: null, first_byte_ms: null, cause: "pause", error: "pause did not hold: the machine read running after the 5 s hold" },
    ], [], ["vmapi"]);
    expect(md).toContain("Provider: vmapi.");
    expect(md).toMatch(/\| 5 s \| platform \| 3 \| 1 \| 0 \| 1\/2 \|/);
    expect(md).toContain("- 5 s platform: 1x [pause] pause did not hold: the machine read running after the 5 s hold");
    expect(md).toContain("- 5 s platform: Not logged in (1x)");
  });
});

describe("the dictator's two changes (2026-11-23)", () => {
  const base: ResumeSample = { pause_s: 5, arm: "platform", i: 0, machine: "m", at: "", paused_ms: 5_000, answered_ms: 900, running_ms: 800, registered_ms: null, first_byte_ms: 2_000, ack_ms: null, clock_offset_ms: 0, error: "" };
  test("not_attached and a lost login are product-suspect, counted apart; a harness cause is not", () => {
    expect(productSuspect("agent-session-send: agent_session.not_attached")).toBe(true);
    expect(productSuspect("turn: Not logged in · Please run /login")).toBe(true);
    expect(productSuspect("the client has no dial")).toBe(false);
    const md = resumeMarkdown([
      { ...base, first_byte_ms: null, error: "agent_session.not_attached", product_suspect: true },
      { ...base, i: 1, first_byte_ms: null, error: "the client has no dial", cause: "read", product_suspect: false },
    ]);
    expect(md).toContain("| 5 s | platform | 2 | 2 | 1 |");
    expect(md).toContain("1x [product-suspect] agent_session.not_attached");
    expect(md).toContain("1x [read] the client has no dial");
  });
  test("the largest Server-Timing phase is named with its p50; an answer with no header reads none sent", () => {
    expect(largestPhase([{ ...base, server_timing_header: null }, { ...base, server_timing_header: null }])).toBe("none sent (0/2)");
    expect(largestPhase([
      { ...base, server_timing: { vmapi: 800, pre: 120, total: 1000 }, server_timing_header: "x" },
      { ...base, server_timing: { vmapi: 1200, pre: 90, total: 1400 }, server_timing_header: "x" },
      { ...base, server_timing_header: null },
    ])).toBe("vmapi 0.80 (2/3)");
    expect(largestPhase([base])).toBe("-");
  });
  test("extra arms are labelled", () => {
    expect(resumeMarkdown([{ ...base, arm: "reattach" }])).toContain("| 5 s | reattach (extra) |");
  });
});

test("a model gateway 503 is infra, not a resume failure (run 45193446599)", () => {
  expect(infraCause("turn: API Error: 503 Every Claude upstream account of this team is cooling down or disabled. Retry shortly (coderouter.cmux.internal).")).toBe(true);
  expect(infraCause("cloud.machine.start: HTTP 503 busy")).toBe(false);
  expect(infraCause("no reply within 180 s")).toBe(false);
});

describe("syncRunning", () => {
  const run = async (status: string, startError?: string) => {
    const calls: string[] = [];
    await syncRunning(async () => status, async () => { calls.push("start"); if (startError) throw new Error(startError); }, async () => { calls.push("wait"); });
    return calls;
  };
  test("a machine the send already woke is not started again (run 45308756971)", async () => {
    expect(await run("running")).toEqual(["wait"]);
  });
  test("a paused machine is started, then waited for", async () => {
    expect(await run("paused")).toEqual(["start", "wait"]);
  });
  test("a wake that lands between the read and the start is not a failure", async () => {
    expect(await run("paused", 'cloud.machine.start: HTTP 200 {"code":"cloud.machine.not_paused"}')).toEqual(["start", "wait"]);
  });
  test("any other refused start still fails", async () => {
    await expect(run("paused", "cloud.machine.start: HTTP 503")).rejects.toThrow("HTTP 503");
  });
});

describe("runProviderArm", () => {
  // A fake adapter on a fake clock: resume answers after 100 + 10*i ms, the probe after it takes 50 ms.
  const fake = () => {
    let t = 0;
    let i = 0;
    const calls: string[] = [];
    const adapter: ProviderAdapter = {
      name: "fake",
      create: async () => { calls.push("create"); return "m1"; },
      pause: async () => { calls.push("pause"); },
      resume: async () => { t += 100 + 10 * i++; calls.push("resume"); },
      probe: async () => { t += 50; calls.push("probe"); },
      remove: async () => { calls.push("remove"); },
    };
    return { adapter, calls, now: () => t, sleep: async (ms: number) => { t += ms; } };
  };
  const platformRows = (): ResumeSample[] => Array.from({ length: 20 }, (_, i) => ({
    pause_s: 5, arm: "platform" as const, i, machine: "m", at: "", paused_ms: 5000, answered_ms: 100 + 10 * i, running_ms: 150 + 10 * i,
    registered_ms: null, first_byte_ms: null, ack_ms: null, clock_offset_ms: null, error: "",
  }));

  test("rows carry the same columns and percentiles as the platform arm", async () => {
    const f = fake();
    const r = await runProviderArm("fake", {}, [5], 20, { adapter: f.adapter, now: f.now, sleep: f.sleep });
    expect(r.stops).toEqual([]);
    expect(r.samples).toHaveLength(20);
    expect(f.calls.at(-1)).toBe("remove");
    const plat = platformRows();
    expect(Object.keys(r.samples[0]!).sort()).toEqual(Object.keys(plat[0]!).sort());
    expect(r.samples.every((s) => s.arm === "provider:fake" && s.paused_ms === 5000)).toBe(true);
    const cells = resumeCells([...plat, ...r.samples]);
    const pick = (arm: string) => cells.filter((c) => c.arm === arm).map(({ arm: _a, ...c }) => c);
    expect(pick("provider:fake")).toEqual(pick("platform"));
    expect(pick("provider:fake").map((c) => c.point)).toEqual(["answered", "running", "registered", "first_byte"]);
    const answered = pick("provider:fake")[0]!;
    expect([answered.n, answered.p50, answered.p95]).toEqual([20, 190, 280]);
    const md = resumeMarkdown([...plat, ...r.samples]);
    expect(md).toContain("| 5 s | platform | 20 |");
    expect(md).toContain("| 5 s | provider:fake | 20 |");
  });

  test("Morph without MORPH_API_KEY is skipped in every cell, not failed", async () => {
    const r = await runProviderArm("morph", {}, [5, 30], 20);
    expect(r.samples).toEqual([]);
    expect(r.stops.map((x) => [x.pause_s, x.arm, x.after, x.reason])).toEqual([
      [5, "provider:morph", 0, "skipped: no MORPH_API_KEY"],
      [30, "provider:morph", 0, "skipped: no MORPH_API_KEY"],
    ]);
    expect(resumeMarkdown([], r.stops)).toContain("skipped: no MORPH_API_KEY");
  });

  test("a failing adapter stops its cell after the fail streak and still removes the machine", async () => {
    const f = fake();
    const bad: ProviderAdapter = { ...f.adapter, resume: async () => { throw new Error("boom"); } };
    const r = await runProviderArm("fake", {}, [5], 20, { adapter: bad, now: f.now, sleep: f.sleep });
    expect(r.samples).toHaveLength(3);
    expect(r.samples.every((s) => s.cause === "wake" && s.error === "boom")).toBe(true);
    expect(r.stops[0]!.reason).toContain("3 provider:fake samples in a row failed");
    expect(f.calls.at(-1)).toBe("remove");
  });
});

describe("awaitPaused (the hold starts once the machine reads paused; run 45373442557 read pausing after the hold)", () => {
  test("waits through pausing, answers the ms from the call to the paused read", async () => {
    let t = 1000;
    const reads = ["pausing", "pausing", "paused"];
    const ms = await awaitPaused(async () => reads.shift()!, 1000, 60_000, () => t, async (w) => { t += w; });
    expect(ms).toBe(1000);
    expect(reads).toEqual([]);
  });
  test("at the deadline it names the last status", async () => {
    let t = 0;
    await expect(awaitPaused(async () => "pausing", 0, 3000, () => t, async (w) => { t += w; })).rejects.toThrow("pause did not land: the machine read pausing 3 s after the pause call");
  });
});

describe("lostPromptFacts", () => {
  test("says where the prompt got to: acked, replied, guest frozen or not, platform status", () => {
    expect(lostPromptFacts({ ack_ms: 76, first_byte_ms: 147, running_ms: null, status: "paused" })).toBe("prompt ack 76 ms, reply record 147 ms, guest showed no freeze across the event, platform read paused");
    expect(lostPromptFacts({ ack_ms: null, first_byte_ms: null, running_ms: 900, status: "running" })).toContain("ran again 900 ms after it");
  });
});

describe("the relay registration line", () => {
  test("matches what cmux-remote writes: registered, registered again, and resumed during the wait", () => {
    expect(RELAY_REGISTERED.test("cmux-tui: relay registration on relay+do://cmux-remote-relay-staging.debussy.workers.dev: registered on slot s after 120 ms")).toBe(true);
    expect(RELAY_REGISTERED.test("cmux-tui: relay registration on relay+do://h: registered again, 900 ms after the drop, on slot s after 1 ms")).toBe(true);
    expect(RELAY_REGISTERED.test("cmux-tui: relay registration on relay+do://h: resumed during the wait; registering now")).toBe(true);
    expect(RELAY_REGISTERED.test("cmux-tui: relay registration on relay+do://h: attempt 2 failed, retrying in 500 ms: x")).toBe(false);
  });
});

test("the table has a pause landed column", () => {
  const s: ResumeSample = { pause_s: 5, arm: "platform", i: 0, machine: "m", at: "", paused_ms: 5000, pause_landed_ms: 2500, answered_ms: 800, running_ms: null, registered_ms: null, first_byte_ms: 1500, ack_ms: null, clock_offset_ms: 0, error: "" };
  const md = resumeMarkdown([s]);
  expect(md).toContain("pause landed p50 / p95");
  expect(md).toContain("| 2.50 / 2.50 |");
});

describe("the send arm's pause (run 45389803263: every send sample read `no reply within 180 s`)", () => {
  // A person's pause (cloud.machine.pause) is never woken by a send: cmux-platform CloudDO.ts PERSON_PAUSED refuses the
  // carrier connect. The send arm measures the app's wake on message, so it needs cmux's own idle pause.
  const person = async () => {};
  const idle = async () => {};
  test("the send arm takes cmux's own pause, never the person's", () => {
    expect(typeof matrix.pauseOf).toBe("function");
    expect(matrix.pauseOf("send", { pause: person, autoPause: idle })).toBe(idle);
  });
  test("every arm that resumes with a call keeps the person's pause", () => {
    for (const arm of ["direct", "platform", "reattach", "resume"] as const) expect(matrix.pauseOf(arm, { pause: person, autoPause: idle })).toBe(person);
  });
  test("with no automatic pause the send arm is unavailable, not a failed wake", () => {
    const why = matrix.pauseOf("send", { pause: person });
    expect(typeof why).toBe("string");
    expect(armUnavailable(why as string)).toBe(true);
  });
});

describe("the resume arm's route (run 45389803263: every resume sample read HTTP 404 {})", () => {
  const calls: { method: string; url: string; headers: Record<string, string> }[] = [];
  const answering = (status: number, body: unknown, timing?: string) => async (method: string, url: string, _body: unknown, headers: Record<string, string>) => {
    calls.push({ method, url, headers });
    return { status, body, headers: new Headers(timing ? { "server-timing": timing } : {}) };
  };
  const auth = { authorization: "Bearer t", "x-cmux-team": "team_1" };

  test("goes to the platform origin with the caller's bearer and team, and returns its Server-Timing", async () => {
    expect(typeof matrix.resumeRouteCall).toBe("function");
    calls.length = 0;
    const r = await matrix.resumeRouteCall("https://platform.example/", "vm_1", auth, answering(200, { ok: true }, "provider;dur=12, total;dur=40.4"));
    expect(calls).toEqual([{ method: "POST", url: "https://platform.example/v1/machines/vm_1/resume", headers: auth }]);
    expect(r.serverTiming).toEqual({ provider: 12, total: 40 });
  });

  test("a machine with no team-machine record is the arm unavailable, naming why", async () => {
    expect(typeof matrix.resumeRouteCall).toBe("function");
    const e = await matrix.resumeRouteCall("https://platform.example", "vm_1", auth, answering(404, { _tag: "MachineNotFound", code: "machine.not_found", message: "no such machine" })).catch((x: Error) => x);
    expect(e).toBeInstanceOf(Error);
    expect(armUnavailable((e as Error).message)).toBe(true);
    expect((e as Error).message).toContain("no team-machine record");
  });

  test("a refusal that is not a missing route or record is a failed wake", async () => {
    expect(typeof matrix.resumeRouteCall).toBe("function");
    const e = await matrix.resumeRouteCall("https://platform.example", "vm_1", auth, answering(409, { code: "machine.conflict" })).catch((x: Error) => x);
    expect(armUnavailable((e as Error).message)).toBe(false);
  });
});
