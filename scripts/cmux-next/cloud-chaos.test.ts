import { describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import * as chaos from "./cloud-chaos.ts";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
import { causeEndedAt, chaosProbeRow, countedSteps, countingTurnScript, countMarker, dropCommand, FAULTS, journalCommand, journalEvent, judgeLoss, judgeTerminal, NOT_INJECTED, relayCutCommand, SeqTerminal, sessionHostKillCommand, type ChaosResult, type SeqEvent, type TerminalRead } from "./cloud-chaos.ts";

const ok = (fault: string, ms: number): ChaosResult => ({ fault, outcome: "ok", felt_ms: ms, recover_ms: Math.round(ms / 3), carrier: "resumed the session", turn: "completed once", detail: "" });

describe("chaosProbeRow", () => {
  test("ok only when every fault that ran passed; ms is the slowest felt time, network_ms the slowest connection", () => {
    const row = chaosProbeRow("p", [ok("drop 5 s", 900), ok("drop 60 s", 2400), { ...ok("vault down", 0), outcome: "not run", felt_ms: null, recover_ms: null }], undefined, new Date("2026-11-08T09:00:00.123Z"));
    expect(row.outcome).toBe("ok");
    expect(row.ms).toBe(2400);
    expect(row.network_ms).toBe(800);
    expect(row.at).toBe("2026-11-08T09:00:00Z");
    expect(row.error).toBeNull();
  });

  test("a failed fault fails the row and is named", () => {
    const row = chaosProbeRow("p", [ok("relay cut", 300), { ...ok("drop 60 s", 0), outcome: "fail", felt_ms: null, recover_ms: null, detail: "no answer within 120 s" }]);
    expect(row.outcome).toBe("fail");
    expect(String(row.error)).toContain("drop 60 s: no answer within 120 s");
  });

  test("a run where nothing ran is a failure, not a pass", () => {
    const row = chaosProbeRow("p", NOT_INJECTED.map((n) => ({ fault: n.name, outcome: "not run" as const, felt_ms: null, recover_ms: null, carrier: "", turn: "", detail: n.why })));
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

  test("an acp tail that fails is the exit the line reports, never an empty journal read as whole", () => {
    const bin = mkdtempSync(join(tmpdir(), "chaos-tail-"));
    try {
      writeFileSync(join(bin, "c"), "#!/bin/sh\necho partial\nexit 3\n");
      chmodSync(join(bin, "c"), 0o755);
      const r = spawnSync("sh", ["-c", `c=${join(bin, "c")}; ${journalCommand("ses-1", 4)}`], { encoding: "utf8" });
      expect(r.stdout.trim().split("\n").pop()).toBe("@@exit 3");
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
      // With every pause made instant the hold loop runs out its bound at once, so the script ends.
      const r = spawnSync("sh", ["-c", SeqTerminal.script(3, file).replace(/sleep [0-9.]+/g, "true")], { encoding: "utf8" });
      expect(r.stdout).toBe(all(3));
      expect(sha(spawnSync("cat", [file], { encoding: "utf8" }).stdout)).toBe(sha(all(3)));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // Codex review F2: the terminal exited during the 60 s drop, and a read after the exit answers with the snapshot.
  test("the guest terminal stays alive after its last line until the leg releases it", async () => {
    const dir = mkdtempSync(join(tmpdir(), "chaos-seq-"));
    try {
      const file = join(dir, "seq.txt");
      const child = spawn("sh", ["-c", SeqTerminal.script(3, file).replace(/sleep 0\.1/g, "true")], { stdio: ["ignore", "pipe", "ignore"] });
      let out = "";
      let exited = false;
      const exit = new Promise<void>((resolve) => child.on("exit", () => { exited = true; resolve(); }));
      await new Promise<void>((resolve) => child.stdout!.on("data", (d) => { out += d; if (out === all(3)) resolve(); }));
      // Every line is out, the tee'd copy is whole, and the terminal has not ended.
      await new Promise((r) => setTimeout(r, 1_500));
      expect(exited).toBe(false);
      expect(spawnSync("cat", [file], { encoding: "utf8" }).stdout).toBe(all(3));
      // The leg's release ends it.
      const release = spawnSync("sh", ["-c", chaos.SeqTerminal.releaseCommand(file)], { encoding: "utf8" });
      expect(release.status).toBe(0);
      await exit;
      expect(exited).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a read after the terminal ended that answers with the snapshot from offset 0 replaces what was read: no loss", () => {
    const text = pty(50);
    const r = reads(text, 17).slice(0, 4);
    // The terminal exits; the next read from r[3].next comes back as the snapshot's projection, from 0, to the end.
    const snapshot: TerminalRead = { after: r[3].next, start: 0, next: text.length + 20, complete: true, text: all(50) };
    const drained: TerminalRead = { after: snapshot.next, start: snapshot.next, next: snapshot.next, complete: true, text: "" };
    const v = judgeTerminal({ n: 50, reads: [...r, snapshot, drained], machineSha256: sha(all(50)), sha256: sha });
    expect(v.text).toContain("all 50 lines");
    expect(v.text).toContain("1 snapshot");
    expect(v.ok).toBe(true);
  });

  test("a snapshot that lost lines, or a chunk that really came back again, still fails", () => {
    const text = pty(50);
    const r = reads(text, 17).slice(0, 4);
    const short: TerminalRead = { after: r[3].next, start: 0, next: text.length, complete: true, text: all(40) };
    expect(judgeTerminal({ n: 50, reads: [...r, short], machineSha256: sha(all(50)), sha256: sha }).ok).toBe(false);
    // A live read that starts inside what was already read (not a snapshot from 0) repeats bytes.
    const repeated = reads(text, 17);
    repeated[3] = { ...repeated[3], start: repeated[3].after - 6, text: text.slice(repeated[3].after - 6, repeated[3].next) };
    const v = judgeTerminal({ n: 50, reads: repeated, machineSha256: sha(all(50)), sha256: sha });
    expect(v.ok).toBe(false);
    expect(v.text).toContain("repeated 6 bytes");
    // A response from 0 that is not complete is not a snapshot the client may take in place of what it read.
    const partial: TerminalRead = { after: r[3].next, start: 0, next: text.length, complete: false, text: all(50) };
    expect(judgeTerminal({ n: 50, reads: [...r, partial], machineSha256: sha(all(50)), sha256: sha }).ok).toBe(false);
    // A response from 0 that ends before the offset asked for answers nothing past it.
    const behind: TerminalRead = { after: r[3].next, start: 0, next: r[3].next - 1, complete: true, text: all(5) };
    expect(judgeTerminal({ n: 50, reads: [...r, behind], machineSha256: sha(all(50)), sha256: sha }).ok).toBe(false);
  });
});

// Codex review F1: a session host restart restores the mux with new numeric surface ids; the chat's tab id stays.
describe("the chat's surface after a restart", () => {
  const tree = (tabs: Array<Record<string, unknown>>) => ({ ok: true, data: { workspaces: [{ id: 1, screens: [{ panes: [{ id: 2, tabs }] }] }] } });
  const agent = (session: string) => ({ agent_session: { host: "registry:r", session, harness: "claude", host_name: null } });
  test("resolves the stable tab id to the tab's current surface", async () => {
    const asked: any[] = [];
    const request = async (frame: Record<string, unknown>) => {
      asked.push(frame);
      return tree([{ surface: 3, tab_resource_id: "tab_other", conversation: agent("s-1") }, { surface: 42, tab_resource_id: "tab_chat", conversation: agent("s-1") }]);
    };
    expect(await chaos.resolveChatSurface(request, "tab_chat", "s-1")).toBe(42);
    expect(asked).toEqual([{ cmd: "list-workspaces" }]);
  });
  test("with no tab id it finds the tab bound to the chat's session, the lowest surface when several are", async () => {
    const request = async () => tree([{ surface: 9, conversation: agent("s-1") }, { surface: 5, conversation: agent("s-1") }, { surface: 2, conversation: agent("s-2") }]);
    expect(await chaos.resolveChatSurface(request, "", "s-1")).toBe(5);
    expect(await chaos.resolveChatSurface(request, "tab_gone", "s-1")).toBe(5);
  });
  test("a tab that is gone is null, and a refused list is an error", async () => {
    expect(await chaos.resolveChatSurface(async () => tree([{ surface: 1, tab_resource_id: "tab_x" }]), "tab_chat", "s-1")).toBeNull();
    await expect(chaos.resolveChatSurface(async () => ({ ok: false, error: "nope" }), "tab_chat", "s-1")).rejects.toThrow();
  });

  /** A fake carrier dial: answers the chat's requests from `answer`, records every frame, and redials on demand. */
  const fakeDial = (answer: (frame: any) => any) => {
    const frames: any[] = [];
    let onDial: () => void = () => undefined;
    const dial = {
      dials: 0,
      start() { this.dials += 1; queueMicrotask(() => onDial()); },
      async request(frame: any) { frames.push(frame); return { ok: true, data: answer(frame) }; },
      stop() {},
    };
    return { frames, dial, make: (_onLine: (m: any) => void, d: () => void) => { onDial = d; return dial; }, redial: () => onDial() };
  };

  test("after a redial the chat attaches, and prompts, on the tab's new surface", async () => {
    let surface = 7;
    const f = fakeDial((frame) => {
      switch (frame.cmd) {
        case "identify": return { registry_id: "r" };
        case "create-workspace": return { workspace: 1 };
        case "new-conversation-tab": return { surface: 7, tab_resource_id: "tab_chat" };
        case "agent-session-start": return { session: "s-1" };
        case "list-workspaces": return tree([{ surface, tab_resource_id: "tab_chat", conversation: agent("s-1") }]).data;
        case "agent-session-attach": return { lastSeq: 10, events: [], hasMore: false };
        default: return {};
      }
    });
    const chat = new chaos.ChatClient({ cmux: "", env: {}, machine: "m", exec: async () => ({ code: 0, stdout: "", stderr: "" }), guest: "", session: "", tag: "t" }, f.make);
    await chat.open("claude");
    expect(chat.surface).toBe(7);
    // The session host restarted: its mux came back with new surface ids, and the client's dial was dialed again.
    surface = 31;
    f.frames.length = 0;
    f.redial();
    await chat.caughtUp(10, 5_000);
    const attach = f.frames.find((x) => x.cmd === "agent-session-attach");
    expect(attach?.surface).toBe(31);
    expect(chat.surface).toBe(31);
    await chat.prompt("hi");
    expect(f.frames.find((x) => x.cmd === "agent-session-prompt")?.surface).toBe(31);
    chat.stop();
  });
});

describe("the felt time after a send", () => {
  const ctx = { cmux: "", env: {}, machine: "m", exec: async () => ({ code: 0, stdout: "", stderr: "" }), guest: "", session: "", tag: "t" };
  /** A chat on a fake dial whose first `refuse` prompts fail (the carrier still down), then answers and pushes `pushes`. */
  const chatWith = async (refuse: number, pushes: Array<{ ms: number; record: any }>) => {
    const prompts: any[] = [];
    let push: (m: any) => void = () => undefined;
    let onDial: () => void = () => undefined;
    const dial = {
      dials: 0,
      start() { queueMicrotask(() => onDial()); },
      async request(frame: any) {
        switch (frame.cmd) {
          case "identify": return { ok: true, data: { registry_id: "r" } };
          case "create-workspace": return { ok: true, data: { workspace: 1 } };
          case "new-conversation-tab": return { ok: true, data: { surface: 7, tab_resource_id: "tab_felt" } };
          case "agent-session-start": return { ok: true, data: { session: "s-felt" } };
          case "list-workspaces": return { ok: true, data: { workspaces: [{ screens: [{ panes: [{ tabs: [{ surface: 7, tab_resource_id: "tab_felt" }] }] }] }] } };
          case "agent-session-attach": return { ok: true, data: { lastSeq: 4, events: [], hasMore: false } };
          case "agent-session-prompt":
            prompts.push(frame);
            if (prompts.length <= refuse) throw new Error("the client has no dial");
            for (const p of pushes) setTimeout(() => push({ surface: 7, event: "agent-session-record", record: p.record }), p.ms);
            return { ok: true, data: {} };
          default: return { ok: true, data: {} };
        }
      },
      stop() {},
    };
    const chat = new chaos.ChatClient(ctx, (onLine, d) => { push = onLine; onDial = d; return dial; });
    await chat.open("claude");
    return { chat, prompts };
  };

  test("runs from the send to the first record of the agent's reply, not to the echo of the prompt", async () => {
    const { chat, prompts } = await chatWith(0, [
      { ms: 10, record: { seq: 5, kind: "user_message_chunk" } },
      { ms: 200, record: { seq: 6, kind: "tool_call", msg: { params: { update: { sessionUpdate: "tool_call" } } } } },
    ]);
    const felt = await chaos.feltAfterSend(chat, `${chaos.feltMarker("t-0")} drop 5 s: reply.`, 5_000);
    expect(felt.felt_ms).toBeGreaterThanOrEqual(190);
    expect(felt.felt_ms).toBeLessThan(1_000);
    expect(felt.tries).toBe(1);
    expect(prompts[0].text).toStartWith("[chaos-felt t-0]");
    chat.stop();
  });

  test("a send the dial cannot take yet is tried again with the same prompt_id, and the clock keeps the wait", async () => {
    const { chat, prompts } = await chatWith(2, [{ ms: 0, record: { seq: 5, params: { update: { sessionUpdate: "agent_message_chunk" } } } }]);
    const felt = await chaos.feltAfterSend(chat, "hi", 10_000);
    expect(felt.tries).toBe(3);
    expect(new Set(prompts.map((p) => p.prompt_id)).size).toBe(1);
    // Two refusals, each followed by a 500 ms pause: the person waited through them.
    expect(felt.felt_ms).toBeGreaterThanOrEqual(950);
    expect(felt.ack_ms).toBeGreaterThanOrEqual(950);
    chat.stop();
  });

  test("no reply within the deadline is null, with the last error", async () => {
    const { chat } = await chatWith(1_000, []);
    const felt = await chaos.feltAfterSend(chat, "hi", 1_200);
    expect(felt.felt_ms).toBeNull();
    expect(felt.ack_ms).toBeNull();
    expect(felt.error).toContain("no dial");
    chat.stop();
  });

  test("a replayed record the chat already held is not the reply", async () => {
    const { chat } = await chatWith(0, [{ ms: 300, record: { seq: 5, kind: "agent_message_chunk" } }]);
    const sending = chaos.feltAfterSend(chat, "hi", 5_000);
    // A re-attach page after the send that repeats held seq 4 (take keeps it, so the loss judge sees the replay).
    (chat as any).take({ events: [{ seq: 4, kind: "agent_message_chunk" }], hasMore: false });
    const felt = await sending;
    expect(felt.felt_ms).toBeGreaterThanOrEqual(290);
    chat.stop();
  });

  test("a late record of the chat's previous turn is not the reply", async () => {
    // The previous turn ended at journal seq 9; its seq 7 arrives late, after the send.
    const { chat } = await chatWith(0, [
      { ms: 20, record: { seq: 7, kind: "agent_message_chunk" } },
      { ms: 300, record: { seq: 10, kind: "agent_message_chunk" } },
    ]);
    const felt = await chaos.feltAfterSend(chat, "hi", 5_000, 9);
    expect(felt.felt_ms).toBeGreaterThanOrEqual(290);
    chat.stop();
  });

  test("a reply received after the deadline does not count", async () => {
    const { chat } = await chatWith(0, [{ ms: 900, record: { seq: 5, kind: "agent_message_chunk" } }]);
    const felt = await chaos.feltAfterSend(chat, "hi", 400);
    expect(felt.felt_ms).toBeNull();
    chat.stop();
  });

  test("a live reply that a re-attach page also carries keeps its earlier arrival time", async () => {
    const { chat } = await chatWith(0, []);
    const c = chat as any;
    // A re-attach is paging: the live push of seq 5 is stashed at its arrival, then the page brings seq 5 later.
    c.paging = true;
    c.onLine({ surface: 7, event: "agent-session-record", record: { seq: 5, kind: "agent_message_chunk" } });
    const pushedAt = c.stash[0].at;
    await sleep(120);
    const pageFrom = c.received.length;
    c.take({ events: [{ seq: 5, kind: "agent_message_chunk" }], hasMore: false });
    c.flushStash(pageFrom);
    expect(chat.received.filter((r) => r.seq === 5)).toHaveLength(1);
    expect(chat.received.find((r) => r.seq === 5)!.at).toBe(pushedAt);
    chat.stop();
  });

  test("a reply still held behind a loading page counts at its own arrival", async () => {
    const { chat } = await chatWith(0, []);
    const c = chat as any;
    const sending = chaos.feltAfterSend(chat, "hi", 5_000);
    await sleep(100);
    // A re-attach is paging: the live reply is stashed now; the page carrying it is still loading.
    c.paging = true;
    c.onLine({ surface: 7, event: "agent-session-record", record: { seq: 5, kind: "agent_message_chunk" } });
    const felt = await sending;
    expect(felt.felt_ms).toBeGreaterThanOrEqual(90);
    expect(felt.felt_ms).toBeLessThan(400);
    chat.stop();
  });

  test("only the agent's own output counts as the reply", () => {
    expect(chaos.isReply({ seq: 1, kind: "agent_message_chunk" })).toBe(true);
    expect(chaos.isReply({ params: { update: { sessionUpdate: "tool_call" } } })).toBe(true);
    expect(chaos.isReply({ seq: 1, kind: "user_message_chunk" })).toBe(false);
    expect(chaos.isReply({ seq: 1, kind: "turn_end" })).toBe(false);
  });

  test("the felt prompt never plays the counting turn", () => {
    expect(new RegExp(countingTurnScript().match).test(chaos.feltMarker("t-0"))).toBe(false);
  });
});
