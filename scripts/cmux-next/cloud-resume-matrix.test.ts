import { describe, expect, test } from "bun:test";
import { cliExecResult } from "./cloud-journey.ts";
import { armOrder, cellDeadline, CLIENT_SESSION_MAX_S, CLIENT_SESSION_MIN_S, directSessionPlan, parseServerTiming, parseWakeFacts, percentile, resumeMarkdown, type ResumeSample } from "./cloud-resume-matrix.ts";

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
  expect(md).toContain("| 30 s | platform | 1 | 0 | 1.20 / 1.20 | - / - | - / - | 2.30 / 2.30 | 1.50 | - |");
  expect(md).toContain("| 30 s | send | 1 | 0 | - / - | - / - | - / - | 2.60 / 2.60 | 1.80 | - |");
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
