import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { causeEndedAt, chaosProbeRow, countedSteps, countingTurnScript, countMarker, dropCommand, FAULTS, journalCommand, journalEvent, judgeLoss, judgeTerminal, NOT_INJECTED, relayCutCommand, SeqTerminal, sessionHostKillCommand, type ChaosResult, type SeqEvent, type TerminalRead } from "./cloud-chaos.ts";

const ok = (fault: string, ms: number): ChaosResult => ({ fault, outcome: "ok", recover_ms: ms, carrier: "resumed the session", turn: "completed once", detail: "" });

describe("chaosProbeRow", () => {
  test("ok only when every fault that ran passed; ms is the slowest recovery", () => {
    const row = chaosProbeRow("p", [ok("drop 5 s", 900), ok("drop 60 s", 2400), { ...ok("vault down", 0), outcome: "not run", recover_ms: null }], undefined, new Date("2026-11-08T09:00:00.123Z"));
    expect(row.outcome).toBe("ok");
    expect(row.ms).toBe(2400);
    expect(row.at).toBe("2026-11-08T09:00:00Z");
    expect(row.error).toBeNull();
  });

  test("a failed fault fails the row and is named", () => {
    const row = chaosProbeRow("p", [ok("relay cut", 300), { ...ok("drop 60 s", 0), outcome: "fail", recover_ms: null, detail: "no answer within 120 s" }]);
    expect(row.outcome).toBe("fail");
    expect(String(row.error)).toContain("drop 60 s: no answer within 120 s");
  });

  test("a run where nothing ran is a failure, not a pass", () => {
    const row = chaosProbeRow("p", NOT_INJECTED.map((n) => ({ fault: n.name, outcome: "not run" as const, recover_ms: null, carrier: "", turn: "", detail: n.why })));
    expect(row.outcome).toBe("fail");
    expect(row.error).toBe("no fault ran");
  });
});

describe("faults", () => {
  test("a drop restores itself on the machine after its length", () => {
    const cmd = dropCommand(60);
    expect(cmd).toStartWith("sudo -n sh -c ");
    expect(cmd).toContain("sleep 60");
    expect(cmd).toContain("iptables -D OUTPUT -p tcp --dport 443 -j DROP");
    expect(cmd).toContain("nft delete table inet cmuxchaos");
  });

  test("a drop arms its restore before any rule goes in, and says ok only once every rule is in", () => {
    const cmd = dropCommand(5);
    expect(cmd.indexOf("sleep 5")).toBeLessThan(cmd.indexOf("iptables -I OUTPUT"));
    expect(cmd).toContain("then echo @@ok iptables; else iptables -D OUTPUT");
    expect(cmd).toContain("then echo @@ok nft; else nft delete table inet cmuxchaos");
  });

  test("the session host is found in cmux-host.service's cgroup, never by a name match", () => {
    const restart = FAULTS.find((f) => f.name === "session host restart")!;
    expect(restart.command).toBe(sessionHostKillCommand());
    expect(restart.command).toContain("systemctl show -p ControlGroup --value cmux-host.service");
    // The only kill is of the pid read from the unit's cgroup.
    expect(restart.command.match(/\bkill\b/g)).toEqual(["kill"]);
    expect(restart.command).toContain("-name cgroup.procs");
  });

  test("a relay cut says ok only when ss -K exits 0 and closed a socket", () => {
    // Fake sudo and ss on PATH: ss prints what SSMODE says, as `ss -K -H` lists the sockets it closed.
    const bin = mkdtempSync(join(tmpdir(), "chaos-ss-"));
    try {
      writeFileSync(join(bin, "sudo"), "#!/bin/sh\nshift\nexec \"$@\"\n");
      writeFileSync(join(bin, "ss"), [
        "#!/bin/sh",
        // Without -n, ss names the port (`:https`), which the count must never depend on.
        'case " $* " in *" -n "*) port=443;; *) port=https;; esac',
        'case "$SSMODE" in',
        '  closed) echo "ESTAB 0 0 10.0.0.2:5555 1.2.3.4:$port"; echo "ESTAB 0 0 10.0.0.2:5556 1.2.3.4:$port";;',
        "  nothing) ;;",
        '  refused) echo "SOCK_DESTROY answers: Operation not supported" >&2; exit 1;;',
        "esac",
        "",
      ].join("\n"));
      chmodSync(join(bin, "sudo"), 0o755);
      chmodSync(join(bin, "ss"), 0o755);
      const run = (mode: string) =>
        spawnSync("sh", ["-c", relayCutCommand()], { env: { ...process.env, SSMODE: mode, PATH: `${bin}:${process.env.PATH}` }, encoding: "utf8" }).stdout.trim();
      expect(run("closed")).toBe("@@ok 2");
      // A kernel without SOCK_DESTROY closes nothing and still exits 0: not a cut.
      expect(run("nothing")).toBe("@@failed rc=0 closed=0");
      expect(run("refused")).toBe("@@failed rc=1 closed=0");
      expect(FAULTS.find((f) => f.name === "relay cut")!.command).toBe(relayCutCommand());
    } finally {
      rmSync(bin, { recursive: true, force: true });
    }
  });

  test("recovery is timed from the fault command's answer, never from before the command ran", () => {
    // A cut or a kill answered 800 ms after it went out: an identify sent in between is not recovery.
    expect(causeEndedAt(1_000, 1_800, 0)).toBe(1_800);
    // A 5 s drop whose command answered at once ends 5 s after it went out.
    expect(causeEndedAt(1_000, 1_200, 5)).toBe(6_000);
    // A drop that held the command's answer past its end ends at the answer.
    expect(causeEndedAt(1_000, 7_000, 5)).toBe(7_000);
  });

  test("Leo's 5 s and 60 s drops are both in the leg", () => {
    expect(FAULTS.map((f) => f.name)).toEqual(expect.arrayContaining(["drop 5 s", "drop 60 s", "relay cut", "session host restart"]));
  });
});

/** A turn of n counting steps as a journal: seq from `from`, a tool call then its result per step, then the reply. */
const turn = (n: number, from = 40): SeqEvent[] => {
  const out: SeqEvent[] = [];
  let seq = from;
  for (let k = 1; k <= n; k++) {
    out.push({ seq: seq++, ks: [] });
    out.push({ seq: seq++, ks: [k] });
  }
  out.push({ seq: seq++, ks: [] });
  return out;
};

describe("judgeLoss", () => {
  test("a contiguous stream with every step once is no loss", () => {
    const j = turn(60);
    const v = judgeLoss({ n: 60, journal: j, client: j });
    expect(v.ok).toBe(true);
    expect(v.text).toBe("no lost output: seq 40..160 contiguous, all 60 steps once on both sides");
  });

  test("a gap in the client's stream is lost output, named by where it jumped", () => {
    const j = turn(10);
    const client = j.filter((e) => e.seq !== 47 && e.seq !== 48);
    const v = judgeLoss({ n: 10, journal: j, client });
    expect(v.ok).toBe(false);
    expect(v.text).toContain("the client's stream jumps 46->49");
    expect(v.text).toContain("the client is missing step 4");
  });

  test("a delivery received twice is doubled output", () => {
    const j = turn(10);
    const client = [...j.slice(0, 12), j[11], ...j.slice(12)];
    const v = judgeLoss({ n: 10, journal: j, client });
    expect(v.ok).toBe(false);
    expect(v.text).toContain("the client received seq 51 twice");
  });

  test("a step two tool calls printed ran twice; one call's output in two updates is once", () => {
    const j = turn(3).map((e) => ({ ...e, call: e.ks.length ? `call-${e.ks[0]}` : undefined }));
    // The call's completed update repeats its output: still once.
    const updated = [...j.slice(0, -1), { seq: 46, ks: [3], call: "call-3" }, { seq: 47, ks: [] }];
    expect(judgeLoss({ n: 3, journal: updated, client: updated }).ok).toBe(true);
    // A second call printed step 2 (the turn ran it again).
    const again = [...j.slice(0, -1), { seq: 46, ks: [2], call: "call-2b" }, { seq: 47, ks: [] }];
    const v = judgeLoss({ n: 3, journal: again, client: again });
    expect(v.ok).toBe(false);
    expect(v.text).toContain("the journal has step 2 more than once");
  });

  test("a replay after a reconnect must start at the last seq seen + 1", () => {
    const j = turn(10);
    // Good: the client saw ..45, reconnected, and the replay starts at 46.
    expect(judgeLoss({ n: 10, journal: j, client: j, reconnects: [6] }).text).toContain("1 reconnect(s) each resumed at the next seq");
    // Replay from too early: 44 and 45 come again.
    const early = [...j.slice(0, 6), ...j.slice(4)];
    const v1 = judgeLoss({ n: 10, journal: j, client: early, reconnects: [6] });
    expect(v1.ok).toBe(false);
    expect(v1.text).toContain("the client received seq 44,45 twice");
    // Replay from too late: 46 and 47 never arrive.
    const late = [...j.slice(0, 6), ...j.slice(8)];
    const v2 = judgeLoss({ n: 10, journal: j, client: late, reconnects: [6] });
    expect(v2.ok).toBe(false);
    expect(v2.text).toContain("jumps 45->48 (a replay after a reconnect)");
  });

  test("a client that never caught up, or a journal with a hole, fails", () => {
    const j = turn(10);
    expect(judgeLoss({ n: 10, journal: j, client: j.slice(0, -3) }).text).toContain("the client stopped at seq 57, the journal goes to 60");
    const holed = j.filter((e) => e.seq !== 49);
    const v = judgeLoss({ n: 10, journal: holed, client: holed });
    expect(v.text).toContain("the journal skips seq 49");
    expect(v.text).toContain("the journal is missing step 5");
  });

  test("an event the client got differently from the journal fails", () => {
    const j = turn(5);
    const client = j.map((e) => (e.seq === 43 ? { ...e, ks: [9] } : e));
    expect(judgeLoss({ n: 5, journal: j, client }).text).toContain("the client's seq 43 differ from the journal's");
  });

  test("no events on a side is a failure, not a pass", () => {
    expect(judgeLoss({ n: 3, journal: [], client: turn(3) }).ok).toBe(false);
    expect(judgeLoss({ n: 3, journal: turn(3), client: [] }).ok).toBe(false);
  });

  test("countedSteps reads a step's number exactly", () => {
    expect(countedSteps("a.b", "chaos-a.b-1\nchaos-a.b-10 chaos-axb-3 chaos-a.b-2")).toEqual([1, 10, 2]);
  });
});

describe("the counting turn", () => {
  test("the shared model stub plays it from the turn's own prompt; only a step's output carries its number", () => {
    const script = { version: 1, steps: [{ shell: "echo first" }, { text: "done" }], turns: [countingTurnScript(3)] };
    const dir = mkdtempSync(join(tmpdir(), "chaos-count-"));
    try {
      const file = join(dir, "script.json");
      writeFileSync(file, JSON.stringify(script));
      // An earlier turn's tool result, then the counting prompt and k of its own results: the step the stub plays.
      const py = [
        "import json, sys",
        `sys.path.insert(0, ${JSON.stringify(fileURLToPath(new URL("../../tests/fixtures/model-stub", import.meta.url)))})`,
        "import model_stub as m",
        "s = m.Stub(m.load_script(sys.argv[1]), 'n', None)",
        "out = []",
        "for k in range(5):",
        "    r = m.Results(['first'] + ['x'] * k, 'p', [('hi', 0), ('[chaos-count t1-f0] count', 1)])",
        "    i, step, res, turn = s.step(r, ['Bash'])",
        "    out.append([i, turn, m.render(step.get('shell', step.get('text', '')), 'n', res)])",
        "print(json.dumps(out))",
      ].join("\n");
      const r = spawnSync("python3", ["-c", py, file], { encoding: "utf8" });
      expect(r.stderr).toBe("");
      const played = JSON.parse(r.stdout) as Array<[number, number, string]>;
      expect(played.map((p) => p[0])).toEqual([0, 1, 2, 3, 3]);
      expect(played[3][2]).toBe("Counted 3 steps for t1-f0.");
      const cmd = played[1][2];
      expect(cmd).toBe("sleep 0.2; printf '%s-%s-%s\\n' chaos t1-f0 2");
      expect(countedSteps("t1-f0", cmd)).toEqual([]);
      const ran = spawnSync("sh", ["-c", cmd], { encoding: "utf8" }).stdout;
      expect(countedSteps("t1-f0", ran)).toEqual([2]);
      expect(countMarker("t1-f0")).toBe("[chaos-count t1-f0]");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("judgeLoss on a turn a restart cut short", () => {
  test("every step up to the last one reached, and no more", () => {
    const j = turn(10).slice(0, 12); // steps 1..6 ran
    expect(judgeLoss({ n: 10, journal: j, client: j }).ok).toBe(false);
    const v = judgeLoss({ n: 10, journal: j, client: j, interrupted: true });
    expect(v.text).toBe("no lost output: seq 40..51 contiguous, steps 1..6 of 10 (the turn was cut short) once on both sides");
    const holed = j.filter((e) => e.seq !== 43);
    expect(judgeLoss({ n: 10, journal: j, client: holed, interrupted: true }).text).toContain("the client is missing step 2");
  });
});

describe("journalEvent", () => {
  const update = (k: number, extra: object = {}) => ({ sessionUpdate: "tool_call_update", toolCallId: `toolu_${k}`, status: "completed",
    rawOutput: `chaos-t-${k}\n`, content: [{ type: "content", content: { type: "text", text: `chaos-t-${k}` } }], ...extra });
  test("a stored tool update counts its step once, keyed by its call", () => {
    const e = journalEvent("t", { seq: 7, at: 1, dir: "in", kind: "tool_call_update", msg: { jsonrpc: "2.0", method: "session/update", params: { sessionId: "s", update: update(12) } } });
    expect(e).toEqual({ seq: 7, ks: [12], call: "toolu_12" });
  });
  test("the call's command, a replayed load and a raw transcript event carry no step", () => {
    const call = { sessionUpdate: "tool_call", toolCallId: "toolu_3", rawInput: { command: "sleep 0.2; printf '%s-%s-%s\\n' chaos t 3" } };
    expect(journalEvent("t", { seq: 1, kind: "tool_call", msg: { params: { update: call } } })!.ks).toEqual([]);
    expect(journalEvent("t", { seq: 2, kind: "tool_call_update.replay", msg: { params: { update: update(3) } } })!.ks).toEqual([]);
    expect(journalEvent("t", { seq: 3, kind: "claude.user", msg: { tool_use_result: { stdout: "chaos-t-3" } } })!.ks).toEqual([]);
  });
  test("a line with no seq is not a journal event", () => {
    expect(journalEvent("t", { method: "session/update", params: {} })).toBeNull();
    expect(journalEvent("t", "x")).toBeNull();
  });
});

describe("journalCommand", () => {
  test("reads the chat's tail on the machine down to what the judge needs", () => {
    const bin = mkdtempSync(join(tmpdir(), "chaos-tail-"));
    try {
      // A stand-in `acp tail`: two tool events, a chunk, and a line that is not JSON.
      const lines = [
        { seq: 5, kind: "agent_message_chunk", msg: { params: { update: { sessionUpdate: "agent_message_chunk", content: { text: "x".repeat(50) } } } } },
        { seq: 6, kind: "tool_call_update", dir: "in", msg: { params: { update: { sessionUpdate: "tool_call_update", toolCallId: "a", rawOutput: "chaos-t-1" } } } },
      ];
      writeFileSync(join(bin, "c"), `#!/bin/sh\necho "$@" > ${join(bin, "args")}\ncat <<'EOF'\n${lines.map((l) => JSON.stringify(l)).join("\n")}\nnot json\nEOF\n`);
      chmodSync(join(bin, "c"), 0o755);
      const r = spawnSync("sh", ["-c", `c=${join(bin, "c")}; ${journalCommand("ses-1", 4)}`], { encoding: "utf8" });
      expect(r.stdout.trim().split("\n").pop()).toBe("@@exit 0");
      const events = r.stdout.split("\n").filter((l) => l.startsWith("{")).map((l) => journalEvent("t", JSON.parse(l)));
      expect(events).toEqual([{ seq: 5, ks: [] }, { seq: 6, ks: [1], call: "a" }]);
      expect(r.stdout).not.toContain("xxxxx");
      expect(spawnSync("cat", [join(bin, "args")], { encoding: "utf8" }).stdout.trim()).toBe("acp tail ses-1 --since 4");
    } finally {
      rmSync(bin, { recursive: true, force: true });
    }
  });
});

describe("judgeTerminal", () => {
  const sha = (t: string) => createHash("sha256").update(t).digest("hex");
  const all = (n: number) => Array.from({ length: n }, (_, i) => `${i + 1}\n`).join("");
  /** The terminal's text (CRLF, as a PTY writes it) read in pieces of `size` bytes, each from the last one's end. */
  const reads = (text: string, size: number): TerminalRead[] => {
    const out: TerminalRead[] = [];
    for (let at = 0; at < text.length; at += size) out.push({ after: at, start: at, next: Math.min(text.length, at + size), complete: true, text: text.slice(at, at + size) });
    return out;
  };
  const pty = (n: number) => all(n).replace(/\n/g, "\r\n");
  test("contiguous reads of every line match the machine copy", () => {
    const v = judgeTerminal({ n: 50, reads: reads(pty(50), 17), machineSha256: sha(all(50)), sha256: sha });
    expect(v.ok).toBe(true);
    expect(v.text).toContain("all 50 lines");
  });
  test("a read that came back from a later offset is skipped output", () => {
    const r = reads(pty(50), 17);
    r[3] = { ...r[3], start: r[3].after + 5, text: r[3].text.slice(5) };
    const v = judgeTerminal({ n: 50, reads: r, machineSha256: sha(all(50)), sha256: sha });
    expect(v.ok).toBe(false);
    expect(v.text).toContain("read 3 asked from 51 and got from 56 (skipped 5 bytes)");
  });
  test("an incomplete window, a line read twice, or another file fails", () => {
    const r = reads(pty(10), 8);
    expect(judgeTerminal({ n: 10, reads: r.map((x, i) => (i === 1 ? { ...x, complete: false } : x)), machineSha256: sha(all(10)), sha256: sha }).text).toContain("was not complete");
    const twice = [...r.slice(0, 2), { ...r[1], after: r[1].next }, ...r.slice(2).map((x) => ({ ...x }))];
    expect(judgeTerminal({ n: 10, reads: twice, machineSha256: sha(all(10)), sha256: sha }).ok).toBe(false);
    expect(judgeTerminal({ n: 10, reads: r, machineSha256: sha(all(9)), sha256: sha }).text).toContain("differs from the machine copy");
    expect(judgeTerminal({ n: 10, reads: [], machineSha256: sha(all(10)), sha256: sha }).ok).toBe(false);
  });
  test("the guest terminal's command prints 1..n and tees it", () => {
    const dir = mkdtempSync(join(tmpdir(), "chaos-seq-"));
    try {
      const file = join(dir, "seq.txt");
      const r = spawnSync("sh", ["-c", SeqTerminal.script(3, file).replace(/sleep [0-9.]+/g, "true")], { encoding: "utf8" });
      expect(r.stdout).toBe(all(3));
      expect(sha(spawnSync("cat", [file], { encoding: "utf8" }).stdout)).toBe(sha(all(3)));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
