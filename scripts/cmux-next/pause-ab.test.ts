import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Api, JOURNEY_STUB_SCRIPT, MODEL_STUB_PY } from "./cloud-journey.ts";
import {
  GUEST_CMUX,
  accountCensus,
  failedCreateIsTransient,
  failureFacts,
  stubRestart,
  stubStop,
  aggregate,
  gapLine,
  gapSchedule,
  guestLine,
  integrate,
  markdownTable,
  pairTable,
  pairsOf,
  parseWaitOutput,
  historyTurn,
  historyTurnStatus,
  waitVerdict,
  percentile,
  pool,
  vmUnavailableTurns,
  parseGuestUpdate,
  parseReportState,
  missingCapability,
  reportLine,
  stalePauseAbMachines,
  jwtExpiresAt,
  oidcMint,
  sessionExpiresAt,
  type MachineResult,
  laterCapabilities,
} from "./pause-ab.ts";

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
  arm, name: `pause-ab-x-${arm}-1`, pair: 1, seed: 7, gaps_s: resumes.map(() => 20), id: "vm", effective_policy: arm, policy_refused: null, capabilities: adv ? ["activity-turn-end"] : [],
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
  test("p50/p95 by nearest rank; a resume that never reached running and a 502 turn are counted", () => {
    const m = machine("aggressive", 10, 90, [1000, 2000, 3000, 4000], true);
    m.turns.push({ turn: 5, gap_s: 20, resumed: true, resume_ms: null, reply_ms: null, error: "did not resume within 180 s" });
    m.turns.push({ turn: 6, gap_s: 20, resumed: false, resume_ms: null, reply_ms: null, report: "read failed: HTTP 502 vm_unavailable" });
    const [row] = aggregate([m], ["aggressive"]);
    expect(row).toMatchObject({ resumes: 5, p50_resume_ms: 2000, p95_resume_ms: 4000, resume_failures: 1, vm_unavailable: 1 });
    expect(vmUnavailableTurns(m)).toBe(1);
    expect(percentile([], 0.5)).toBeNull();
    expect(percentile([5], 0.95)).toBe(5);
  });
});

describe("pairTable", () => {
  test("one row per pair with each arm's paused seconds and resumes", () => {
    const a = { ...machine("turn_end", 100, 300, [null, 2000], true), pair: 2, seed: 8, gaps_s: [45, 90] };
    const b = { ...machine("aggressive", 50, 350, [null, 1000], true), pair: 2, seed: 8, gaps_s: [45, 90] };
    expect(pairTable([a, b], ["turn_end", "aggressive"]).split("\n")[2]).toBe("| 2 | 8 | 45,90 | 300 / 1 | 350 / 1 |");
  });
  test("a skipped pair shows why and stays out of both arms' rows", () => {
    const a = { ...machine("turn_end", 100, 300, [null, 2000], true), pair: 1 };
    const b = { ...machine("aggressive", 50, 350, [null, 1000], true), pair: 1 };
    const c = { ...machine("turn_end", 0, 0, [], false), pair: 2, skipped: "pause-ab-x-turn_end-2 not running within 300 s" };
    const d = { ...machine("aggressive", 0, 0, [], false), pair: 2, skipped: "pause-ab-x-turn_end-2 not running within 300 s" };
    expect(pairTable([a, b, c, d], ["turn_end", "aggressive"]).split("\n")[3]).toContain("skipped: pause-ab-x-turn_end-2 not running");
    expect(aggregate([a, b, c, d], ["turn_end", "aggressive"]).map((r) => r.machines)).toEqual([1, 1]);
    expect(pairsOf([d, a, c, b]).map((p) => [p.pair, p.machines.map((m) => m.arm)])).toEqual([[1, ["turn_end", "aggressive"]], [2, ["aggressive", "turn_end"]]]);
  });
});

describe("pool", () => {
  test("runs every item with at most n in flight", async () => {
    let live = 0;
    let peak = 0;
    const done: number[] = [];
    await pool([1, 2, 3, 4, 5, 6, 7], 3, async (i) => {
      peak = Math.max(peak, ++live);
      await new Promise((r) => setTimeout(r, 5));
      done.push(i);
      live--;
    });
    expect(done.sort()).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(peak).toBe(3);
  });
  test("pairs start in pair order, 3 at a time (runs 45869919450, 45886952582: one at a time reached 4 of 10 pairs)", async () => {
    const rows = [1, 2, 3, 4, 5].flatMap((pair) => ["turn_end", "aggressive"].map((arm) => ({ pair, arm })));
    const started: number[] = [];
    let live = 0;
    let peak = 0;
    await pool(pairsOf(rows), 3, async ({ pair, machines }) => {
      started.push(pair);
      expect(machines.map((m) => m.arm)).toEqual(["turn_end", "aggressive"]);
      peak = Math.max(peak, ++live);
      await new Promise((r) => setTimeout(r, 5));
      live--;
    });
    expect(started).toEqual([1, 2, 3, 4, 5]);
    expect(peak).toBe(3);
  });
});

describe("stalePauseAbMachines", () => {
  test("only our name shape and an old tag, active or not", () => {
    const now = Date.UTC(2026, 10, 24, 20);
    const old = (now - 4 * 3_600_000).toString(36);
    const fresh = (now - 60_000).toString(36);
    const rows = [
      { id: "a", name: `pause-ab-${old}-turn_end-1`, status: "paused" },
      { id: "b", name: `pause-ab-${fresh}-aggressive-1`, status: "running" },
      { id: "c", name: `my-machine`, status: "paused" },
      { id: "d", name: `pause-ab-${old}-aggressive-2`, status: "running", last_active_at: now - 60_000 },
    ];
    expect(stalePauseAbMachines(rows, now).map((r) => r.id)).toEqual(["a", "d"]);
  });

  test("a tag past the workflow's 80-minute job is left behind; one inside it may still be running", () => {
    const now = Date.UTC(2026, 10, 26, 9, 58);
    const killed = Date.UTC(2026, 10, 26, 8, 0).toString(36);
    const live = (now - 70 * 60_000).toString(36);
    const rows = [
      { id: "vm_killed", name: `pause-ab-${killed}-aggressive-1`, status: "running" },
      { id: "vm_live", name: `pause-ab-${live}-turn_end-1`, status: "running" },
    ];
    expect(stalePauseAbMachines(rows, now).map((r) => r.id)).toEqual(["vm_killed"]);
  });

  test("every pause-ab machine it keeps comes with the reason", () => {
    const now = Date.UTC(2026, 10, 26, 10, 43);
    const old = Date.UTC(2026, 10, 26, 8, 0).toString(36);
    const rows = [
      { id: "vm_busy", name: `pause-ab-${old}-aggressive-1`, status: "running", last_active_at: now - 5 * 60_000 },
      { id: "vm_gone", name: `pause-ab-${old}-turn_end-1`, status: "deleting" },
      { id: "vm_other", name: "someone-else", status: "running" },
    ];
    const kept: string[] = [];
    // Run 45808104119 kept pause-ab-mwxbi2gl (2.5 h old) "active 0 min ago": its own leftover stub is the activity.
    expect(stalePauseAbMachines(rows, now, undefined, kept)).toEqual([{ id: "vm_busy", name: `pause-ab-${old}-aggressive-1`, why: "started 163 min ago, active 5 min ago" }]);
    expect(kept).toEqual([`vm_gone pause-ab-${old}-turn_end-1 status=deleting`]);
  });
});

// Run 45808104119: create took 247 s on a 199-machine account, the machine went `failed` and the record that said why
// was cut at 300 chars. The sweep now says what the account's machines are; a failed machine's own fields come whole.
describe("drill account and failed machines", () => {
  test("census counts by status, age and name shape", () => {
    const now = Date.UTC(2026, 10, 26, 11, 30);
    const rows = [
      { name: "pause-ab-mwxgb9ud-turn_end-1", status: "running", created_at: now - 60_000 },
      { name: "pause-ab-mwx9ibyh-aggressive-1", status: "running", created_at: new Date(now - 3 * 3_600_000).toISOString() },
      { name: "journey-mwx1-chat", status: "failed", created_at: Math.floor((now - 9 * 86_400_000) / 1000) },
      { status: "paused" },
    ];
    expect(accountCensus(rows, now)).toBe(
      "status: running=2 failed=1 paused=1; age: <1d=1 <1h=1 >=7d=1 age?=1; names: (unnamed)=1 journey-*-chat=1 pause-ab-*-aggressive-*=1 pause-ab-*-turn_end-*=1; failed by error: no error=1",
    );
  });
  test("a failed machine keeps its reason past 300 chars and drops who it is", () => {
    const m = { id: "vm_x", team: "team_y", creator: "user_z", name: "pause-ab-a-aggressive-1", size: { cpu: 2 }, status: "failed",
      image: { id: "cloud-native-auto-" + "x".repeat(300) }, status_reason: "provider: no capacity in zone" };
    const f = failureFacts(m);
    expect(f).toContain("no capacity in zone");
    expect(f).not.toContain("team_y");
    expect(f).not.toContain("user_z");
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
    expect(gapLine("m", { turn: 1, gap_s: 20, resumed: false, resume_ms: null, reply_ms: null })).toBe("| m | 1 | 20 | n/a | n/a | n/a |");
  });
});

// Run 45787132980: both arms were kept awake at every gap by {"why":"workload"} on the stub's port, owned by comm
// python3 (the cmux-tui-pab-stub link never reached comm). The drill stops the stub for each gap and restarts it on
// the same port with the next message, as the cloud journey's idle walk does (cmux#58030).
describe("model stub around an idle gap", () => {
  const dir = mkdtempSync(join(tmpdir(), "pab-stub-"));
  const d = join(dir, "pab-model-stub");
  const sh = (cmd: string) => spawnSync("bash", ["-c", cmd], { encoding: "utf8", timeout: 30_000 });
  const info = (port: number) => sh(`curl -fsS -m 2 http://127.0.0.1:${port}/__stub/info`);
  afterAll(() => {
    sh(`p=$(cat ${d}.pid 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; true`);
    rmSync(dir, { recursive: true, force: true });
  });

  test("stopped for the gap, nothing listens, back on its port with the next message", () => {
    copyFileSync(MODEL_STUB_PY, `${d}.py`);
    writeFileSync(`${d}.json`, JSON.stringify(JOURNEY_STUB_SCRIPT));
    writeFileSync(`${d}.log`, '{"before":"gap"}\n');
    // /usr/bin/python3 as on the guest (a dev machine's python3 may be a shim that cannot run a script by path).
    symlinkSync(sh("[ -x /usr/bin/python3 ] && echo /usr/bin/python3 || command -v python3").stdout.trim(), join(dir, "cmux-tui-pab-stub"));
    const up = sh(
      `(nohup ${dir}/cmux-tui-pab-stub ${d}.py --port 0 --script ${d}.json --nonce n0nce --log ${d}.log --ready-file ${d}.ready >${d}.log.out 2>&1 & echo $! >${d}.pid); ` +
        `for i in $(seq 50); do [ -s ${d}.ready ] && break; sleep 0.2; done; cat ${d}.ready`,
    );
    const port = JSON.parse(up.stdout).port as number;
    expect(info(port).stdout).toContain("n0nce");

    const stop = sh(stubStop(dir));
    expect(stop.status).toBe(0);
    expect(stop.stdout).toContain(`@@stopped ${port}`);
    expect(sh(`ss -ltnH "sport = :${port}"`).stdout.trim()).toBe("");

    const back = sh(`${stubRestart(port, "n0nce", dir)}echo sent`);
    expect(back.status).toBe(0);
    expect(back.stdout).toContain("sent");
    expect(info(port).stdout).toContain("n0nce");
    expect(readFileSync(`${d}.log`, "utf8")).toContain('{"before":"gap"}');
  }, 30_000);

  test("no recorded stub: the stop says so instead of a port", () => {
    const empty = mkdtempSync(join(tmpdir(), "pab-nostub-"));
    const r = sh(stubStop(empty));
    rmSync(empty, { recursive: true, force: true });
    expect(r.status).not.toBe(0);
    expect(r.stdout).toContain("@@nostub");
  });
});

describe("a failed create on the drill account", () => {
  const now = Date.UTC(2026, 10, 26, 12, 0);
  test("census names what the failed machines failed of, without ids", () => {
    const line = accountCensus([
      { status: "failed", name: "x-1", created_at: now, error: { code: "cloud.provider.unavailable", message: "VM API: HTTP 503" } },
      { status: "failed", name: "x-2", created_at: now, error: { code: "cloud.provider.unavailable", message: "VM API: HTTP 503" } },
      { status: "failed", name: "x-3", created_at: now, error: { code: "cloud.image.withdrawn", message: "image of vm_abc123 gone" } },
      { status: "running", name: "y-1", created_at: now },
    ], now);
    expect(line).toContain("failed by error: cloud.provider.unavailable VM API: HTTP 503=2 | cloud.image.withdrawn image of vm_* gone=1");
    expect(accountCensus([{ status: "running", name: "y-1", created_at: now }], now)).not.toContain("failed by error");
  });
  test("only a provider failure that never ran gets a replacement", () => {
    const failed = { status: "failed", host: null, last_active_at: null, error: { code: "cloud.provider.unavailable", message: "VM API: HTTP 503" } };
    expect(failedCreateIsTransient(failed)).toBe(true);
    expect(failedCreateIsTransient({ ...failed, error: { code: "cloud.quota.vm_limit" } })).toBe(false);
    expect(failedCreateIsTransient({ ...failed, host: "h1" })).toBe(false);
    expect(failedCreateIsTransient({ ...failed, last_active_at: now })).toBe(false);
    expect(failedCreateIsTransient({ ...failed, status: "running" })).toBe(false);
  });
  test("the sweep takes a replacement's name too", () => {
    const old = (Date.UTC(2026, 10, 26, 9, 0)).toString(36);
    expect(stalePauseAbMachines([{ id: "a", name: `pause-ab-${old}-aggressive-1r`, status: "running" }], now).map((m) => m.id)).toEqual(["a"]);
  });
});

describe("parseReportState", () => {
  test("the report's daemon block, last outcome and acpmux processes", () => {
    const state = JSON.stringify({ last_report: { reason: "activity", ok: true, applied: true, at: 1, status: 200 }, daemon: { version: "0.1.0+abc", capabilities: ["activity", "activity-turns", "activity-turn-end"] } });
    const r = parseReportState(`${state}\n@@acpmux\n2213 /home/cmux/.cmux/bin/acpmux 0123456789ab acpmux 0.1.0\n`);
    expect(r.capabilities).toEqual(["activity", "activity-turns", "activity-turn-end"]);
    expect(r.acpmux).toEqual(["2213 /home/cmux/.cmux/bin/acpmux 0123456789ab acpmux 0.1.0"]);
    expect(reportLine(r)).toBe("reported caps activity,activity-turns,activity-turn-end; daemon 0.1.0+abc; last activity ok=true applied=true status=200; acpmux 2213 /home/cmux/.cmux/bin/acpmux 0123456789ab acpmux 0.1.0");
  });
  test("an unreadable state file is kept verbatim", () => {
    const r = parseReportState("cat: /run/cmux-vm-agent/state.json: No such file or directory\n@@acpmux\n");
    expect(r.capabilities).toBeNull();
    expect(reportLine(r)).toBe("report state unreadable: cat: /run/cmux-vm-agent/state.json: No such file or directory; acpmux none");
  });
});

describe("missingCapability", () => {
  test("a turn_end machine without activity-turn-end fails the run, naming its build; aggressive needs none", () => {
    const out = missingCapability([
      { arm: "turn_end", name: "t1", capabilities: ["activity", "activity-turns"], daemon_version: "1.0.0+67d01201b152" },
      { arm: "turn_end", name: "t2", capabilities: ["activity-turns", "activity-turn-end"], daemon_version: "1.0.0+6fde033d9d34" },
      { arm: "aggressive", name: "a1", capabilities: null, daemon_version: null },
    ]);
    expect(out).toEqual(["t1: arm turn_end needs activity-turn-end, guest daemon 1.0.0+67d01201b152 advertised activity,activity-turns"]);
  });
});

describe("waitVerdict (run 45869919450: acp wait exit 1 after a resume, right reply written)", () => {
  const nonce = "f972a7befbec";
  const reply = `Stub reply ${nonce}. The tool printed ${nonce}-tool`;
  test("parseWaitOutput splits exit code, reply and stderr", () => {
    const p = parseWaitOutput(`@@wait 1\n${reply}\n\n@@werr daemon reconnect: socket closed \n`);
    expect(p).toEqual({ code: "1", text: reply, werr: "daemon reconnect: socket closed" });
  });
  test("historyTurnStatus finds the marker's turn", () => {
    const h = `noise {"turns":[{"prompt":"[pab t turn 1] Run","status":"done"},{"prompt":"[pab t turn 2] Run","status":"running"}]}`;
    expect(historyTurnStatus(h, "[pab t turn 1]")).toBe("done");
    expect(historyTurnStatus(h, "[pab t turn 2]")).toBe("running");
    expect(historyTurnStatus(h, "[pab t turn 3]")).toBeNull();
    expect(historyTurnStatus("not json", "[pab t turn 1]")).toBeNull();
  });
  test("historyTurn says why a turn failed", () => {
    const h = `{"turns":[{"prompt":"[pab t turn 1] Run","status":"failed","error":"the daemon restarted before this turn settled","detail":"outcome_unknown"},{"prompt":"[pab t turn 2] Run","status":"completed"}]}`;
    expect(historyTurn(h, "[pab t turn 1]")).toEqual({ status: "failed", why: "the daemon restarted before this turn settled; outcome_unknown" });
    expect(historyTurn(h, "[pab t turn 2]")).toEqual({ status: "completed", why: "" });
    const v = waitVerdict({ code: "1", text: reply, werr: "", turnStatus: "failed (outcome_unknown)", nonce, waitFails: 0 });
    expect(v).toEqual({ kind: "reply", note: "acp wait exit 1; history lists the turn failed (outcome_unknown)" });
  });
  test("exit 0 with the nonce is a reply; without it a failure", () => {
    expect(waitVerdict({ code: "0", text: reply, werr: "", turnStatus: null, nonce, waitFails: 0 })).toEqual({ kind: "reply" });
    expect(waitVerdict({ code: "0", text: "other", werr: "", turnStatus: null, nonce, waitFails: 0 }).kind).toBe("fail");
  });
  test("exit 3 waits again", () => {
    expect(waitVerdict({ code: "3", text: reply, werr: "", turnStatus: "running", nonce, waitFails: 9 })).toEqual({ kind: "again" });
  });
  test("exit 1 with the turn ended and the nonce is a reply with a note", () => {
    const v = waitVerdict({ code: "1", text: reply, werr: "socket closed", turnStatus: "done", nonce, waitFails: 0 });
    expect(v).toEqual({ kind: "reply", note: "acp wait exit 1: socket closed; history lists the turn done" });
  });
  test("exit 1 with the turn still running retries 3 times, then fails with stderr", () => {
    const a = { code: "1", text: reply, werr: "socket closed", turnStatus: "running", nonce };
    expect(waitVerdict({ ...a, waitFails: 0 }).kind).toBe("retry");
    expect(waitVerdict({ ...a, waitFails: 2 }).kind).toBe("retry");
    const f = waitVerdict({ ...a, waitFails: 3 });
    expect(f.kind).toBe("fail");
    expect(f.kind === "fail" && f.error).toContain("socket closed; turn running");
  });
});

describe("laterCapabilities (run 45898762249 attempt 2: turn 1 read a just-restarted daemon)", () => {
  const full = { capabilities: ["activity", "activity-turns", "activity-turn-end"], version: "1.0.0+ee905dc44cc2" };
  test("a later report with the capability replaces turn 1's, naming the turn", () => {
    const r = { arm: "turn_end", capabilities: ["fs-v1", "activity"], daemon_version: "1.0.0+ee905dc44cc2" };
    const out = laterCapabilities(r, full, 2);
    expect(out).toEqual({ capabilities: full.capabilities, turn_end_advertised: true, capabilities_turn: 2, daemon_version: "1.0.0+ee905dc44cc2" });
    expect(missingCapability([{ name: "t", ...r, ...out }])).toEqual([]);
  });
  test("an old build that never advertises it still fails; aggressive and already-advertised keep turn 1's", () => {
    const old = { arm: "turn_end", capabilities: ["activity"], daemon_version: "1.0.0+67d01201b152" };
    expect(laterCapabilities(old, { capabilities: ["activity"], version: "1.0.0+67d01201b152" }, 5)).toEqual({});
    expect(laterCapabilities(old, { capabilities: null, version: null }, 5)).toEqual({});
    expect(laterCapabilities({ arm: "aggressive", capabilities: null, daemon_version: null }, full, 2)).toEqual({});
    expect(laterCapabilities({ arm: "turn_end", capabilities: full.capabilities, daemon_version: "x" }, full, 3)).toEqual({});
  });
});

describe("sign-in refresh", () => {
  test("sessionExpiresAt reads ISO, epoch seconds and a missing end", () => {
    expect(sessionExpiresAt("2026-11-27T05:00:00.000Z")).toBe(Date.parse("2026-11-27T05:00:00.000Z"));
    expect(sessionExpiresAt("1795000000")).toBe(1795000000_000);
    expect(sessionExpiresAt("?")).toBe(Infinity);
    expect(sessionExpiresAt("")).toBe(Infinity);
  });
  test("jwtExpiresAt reads exp, and never for a token that is no JWT", () => {
    const body = Buffer.from(JSON.stringify({ exp: 1795000000 })).toString("base64url");
    expect(jwtExpiresAt(`h.${body}.s`)).toBe(1795000000_000);
    expect(jwtExpiresAt("opaque")).toBe(Infinity);
  });
  test("an Api with oidcMint signs in again when its session is about to end", async () => {
    let n = 0;
    const fetchJson = (async (_m: string, url: string) => {
      if (url.includes("audience=")) return { status: 200, body: { value: `gh-${n}` } };
      n += 1;
      const end = new Date(Date.now() + (n === 1 ? 30_000 : 3_600_000)).toISOString();
      return { status: 200, body: { access_token: `tok-${n}`, user: "u", session_expires_at: end } };
    }) as any;
    const mint = oidcMint("https://api.example", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/t", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "b" }, [], fetchJson);
    const api = new Api("https://api.example");
    const first = await mint();
    api.bearer = first.token;
    api.expiresAt = first.expiresAt;
    api.remint = mint;
    await api.fresh();
    expect(api.bearer).toBe("tok-2");
    await api.fresh();
    expect(api.bearer).toBe("tok-2");
  });
});
