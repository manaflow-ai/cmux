/**
 * The Cloud journey's chaos leg (`cloud-journey.ts --chaos`): faults injected into a live machine's carrier mid-turn,
 * each timed from the moment its cause ends until the person's client answers again, with what the person saw.
 *
 * One `cmux carrier dial` stays open the whole leg, the way the app's carrier serve socket holds one. A pinger writes
 * `identify` on it every PING_MS, and every answer is timed. When the dial ends (the session is gone, which a daemon
 * restart does by design), the leg dials again at once, as the app's redial does, and counts it.
 *
 * Each fault starts one turn first (`acp send --no-wait`, a marker in its prompt), so the fault lands mid-turn:
 *
 * - `relay cut`: every established TCP connection to port 443 on the machine is reset (`ss -K`): the session host's
 *   relay sockets drop as when the relay restarts;
 * - `drop 5 s`, `drop 60 s`: the machine drops all of its 443 traffic both ways for that long (iptables, or nft); the
 *   restore is a timer on the machine itself, so it runs even if this run dies;
 * - `session host restart`: the carrier's daemon (the session host, `--relay-slot`) is killed with SIGKILL and its
 *   supervisor (cmux-host) starts it again;
 * - `agent daemon restart`: acpmux on the machine is killed with SIGKILL mid-turn and acpmux.service brings it back.
 *
 * Per fault it records: recover_ms (from the cause's end to the first identify answered after it), how the carrier came
 * back (resumed in the same session, or a new dial), and the turn's outcome from `acp history` (completed once, missing,
 * or started twice: a lost or duplicated prompt). Faults it cannot inject from the machine (the vault, an image roll
 * during a spare claim) are recorded as not run with the reason.
 */
import { spawn } from "node:child_process";

export type ChaosExec = (command: string, timeoutMs?: number) => Promise<{ code: number; stdout: string; stderr: string }>;

export type ChaosResult = {
  fault: string;
  outcome: "ok" | "fail" | "not run";
  recover_ms: number | null;
  carrier: string;
  turn: string;
  detail: string;
};

export type ChaosContext = {
  cmux: string;
  env: Record<string, string | undefined>;
  machine: string;
  team?: string;
  exec: ChaosExec;
  /** The guest shell prefix that sets `$c` to the machine's cmux-tui (cloud-journey.ts GUEST). */
  guest: string;
  session: string;
  tag: string;
  log?: (line: string) => void;
};

const PING_MS = 250;
/** A fault that has not recovered this long after its cause ended is a failure, and the leg moves on. */
export const RECOVER_DEADLINE_MS = 120_000;
/** How long a turn may take after its fault recovered. */
const TURN_DEADLINE_MS = 180_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/** The faults the leg injects, in order, and the guest command for each. `secs` is how long its cause lasts. */
export const FAULTS: Array<{ name: string; secs: number; command: string }> = [
  { name: "relay cut", secs: 0, command: relayCutCommand() },
  { name: "drop 5 s", secs: 5, command: dropCommand(5) },
  { name: "drop 60 s", secs: 60, command: dropCommand(60) },
  {
    name: "session host restart",
    secs: 0,
    command: sessionHostKillCommand(),
  },
  {
    name: "agent daemon restart",
    secs: 0,
    command: 'p=$("$c" acp --json daemon status 2>/dev/null | sed -n \'s/.*"pid": *\\([0-9]*\\).*/\\1/p\' | head -1); [ -n "$p" ] && kill -KILL "$p" && echo "@@ok $p"',
  },
];

/**
 * Reset every established 443 connection on the machine. `ss -K` lists each socket it closed, so `@@ok` needs both its
 * exit status and at least one closed socket: a missing `sudo`, a missing `ss`, or a kernel without SOCK_DESTROY (where
 * `ss -K` closes nothing) prints `@@failed` instead of passing as a cut that never happened.
 */
export function relayCutCommand(): string {
  return "out=$(sudo -n ss -K -H state established '( dport = :443 )' 2>&1); rc=$?; " +
    "n=$(printf '%s\\n' \"$out\" | grep -c ':443'); " +
    "if [ \"$rc\" -eq 0 ] && [ \"$n\" -gt 0 ]; then echo \"@@ok $n\"; else echo \"@@failed rc=$rc closed=$n\"; fi";
}

/**
 * SIGKILL the session host: the one process in cmux-host.service's own cgroup started with `--relay-slot`
 * (carrier_entry.rs). Its pid comes from the unit systemd records, never a match across every process on the machine,
 * and only that pid is killed.
 */
export function sessionHostKillCommand(): string {
  return "cg=$(systemctl show -p ControlGroup --value cmux-host.service 2>/dev/null); host=''; " +
    // Every cgroup.procs under the unit (the session host may sit in a child cgroup). The pattern's brackets keep this
    // shell, whose own command line holds the pattern's text, from matching itself, and its own pid is skipped too.
    "for p in $(find \"/sys/fs/cgroup$cg\" -name cgroup.procs -exec cat {} + 2>/dev/null); do [ \"$p\" = \"$$\" ] && continue; " +
    "{ tr '\\0' ' ' < \"/proc/$p/cmdline\"; } 2>/dev/null | grep -q -- ' --relay-slo[t] ' && { host=$p; break; }; done; " +
    "if [ -n \"$cg\" ] && [ -n \"$host\" ] && sudo -n kill -KILL \"$host\"; then echo \"@@ok $host\"; else echo \"@@failed cgroup=$cg pid=$host\"; fi";
}

/** Not injectable from the machine: recorded as not run, with whose lane can run them. */
export const NOT_INJECTED: Array<{ name: string; why: string }> = [
  {
    name: "vault down",
    why: "not applicable yet: no staging path calls cmux-vault (inference leases and edge grants are not built); cloud-vault-integration adds a per-team fail switch when they land",
  },
  {
    name: "image roll during a spare claim",
    why: "not run live: a staging roll remakes every staging team's spares; the race is tested in-process by cmux-platform#1012's claim-vs-roll tests",
  },
];

/**
 * Drop the machine's 443 traffic both ways for `secs`, undone by a timer on the machine. iptables when the image has
 * it, else an nft table of its own (deleted by the timer). The timer is armed before any rule goes in, a rule set that
 * goes in only partly is taken out at once, and `@@ok` is printed only once every rule is in.
 */
export function dropCommand(secs: number): string {
  const ipt = [
    "iptables -I OUTPUT -p tcp --dport 443 -j DROP",
    "iptables -I INPUT -p tcp --sport 443 -j DROP",
  ];
  const undo = ["iptables -D OUTPUT -p tcp --dport 443 -j DROP", "iptables -D INPUT -p tcp --sport 443 -j DROP"];
  const nft = "nft add table inet cmuxchaos && nft add chain inet cmuxchaos out '{ type filter hook output priority 0; }' && nft add rule inet cmuxchaos out tcp dport 443 drop && nft add chain inet cmuxchaos in '{ type filter hook input priority 0; }' && nft add rule inet cmuxchaos in tcp sport 443 drop";
  const restore = undo.join("; ");
  const script = `if command -v iptables >/dev/null 2>&1; then (sleep ${secs}; ${restore}) >/dev/null 2>&1 & ` +
    `if ${ipt.join(" && ")}; then echo @@ok iptables; else ${restore}; echo @@failed iptables; fi; ` +
    `elif command -v nft >/dev/null 2>&1; then (sleep ${secs}; nft delete table inet cmuxchaos) >/dev/null 2>&1 & ` +
    `if ${nft}; then echo @@ok nft; else nft delete table inet cmuxchaos; echo @@failed nft; fi; else echo @@none; fi`;
  return `sudo -n sh -c ${shq(script)}`;
}

/** One open carrier dial, pinged; every answer's time kept. A dial that ends is replaced at once. */
class Carrier {
  /** Each answered identify: when its request went out, and when the answer came. */
  answers: Array<{ sent: number; at: number }> = [];
  private sentAt = new Map<number, number>();
  routeLines: string[] = [];
  dials = 0;
  ended: string[] = [];
  private child: ReturnType<typeof spawn> | null = null;
  private stopped = false;
  private id = 1;
  private pinger: ReturnType<typeof setInterval> | null = null;

  constructor(private ctx: ChaosContext) {}

  start(): void {
    this.dial();
    this.pinger = setInterval(() => {
      const child = this.child;
      if (!child?.stdin?.writable) return;
      const id = ++this.id;
      this.sentAt.set(id, Date.now());
      child.stdin.write(`${JSON.stringify({ cmd: "identify", id })}\n`);
    }, PING_MS);
  }

  private dial(): void {
    if (this.stopped) return;
    this.dials += 1;
    const args = ["carrier", "dial", "--machine", this.ctx.machine, ...(this.ctx.team ? ["--team", this.ctx.team] : [])];
    const child = spawn(this.ctx.cmux, args, { env: this.ctx.env, stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    child.stdin!.on("error", () => undefined);
    const lines = (stream: NodeJS.ReadableStream, each: (line: string) => void) => {
      let buffered = "";
      stream.setEncoding("utf8");
      stream.on("data", (chunk: string) => {
        buffered += chunk;
        for (let at = buffered.indexOf("\n"); at >= 0; at = buffered.indexOf("\n")) {
          each(buffered.slice(0, at));
          buffered = buffered.slice(at + 1);
        }
      });
    };
    lines(child.stdout!, (line) => {
      try {
        const answer = JSON.parse(line);
        const sent = typeof answer?.id === "number" ? this.sentAt.get(answer.id) : undefined;
        if (sent !== undefined && answer.ok === true) {
          this.sentAt.delete(answer.id);
          this.answers.push({ sent, at: Date.now() });
        }
      } catch { /* a pushed event that is not an answer */ }
    });
    lines(child.stderr!, (line) => {
      if (line.startsWith("cloud.connect ")) this.routeLines.push(`${Date.now()} ${line}`);
    });
    child.on("exit", (code) => {
      if (this.child === child) this.child = null;
      if (this.stopped) return;
      this.ended.push(`exit ${code} at ${Date.now()}`);
      this.ctx.log?.(`chaos: carrier dial ended (exit ${code}); dialing again`);
      this.dial();
    });
  }

  /**
   * When the first identify sent at or after `t` was answered, waiting up to `budgetMs`. Only a request sent after `t`
   * counts: an answer to one sent before (held back by the fault, delivered after) does not show the carrier works.
   */
  async answeredAfter(t: number, budgetMs: number): Promise<number | null> {
    const until = Date.now() + budgetMs;
    for (;;) {
      const hit = this.answers.find((a) => a.sent >= t);
      if (hit !== undefined) return hit.at;
      if (Date.now() > until) return null;
      await sleep(50);
    }
  }

  stop(): void {
    this.stopped = true;
    if (this.pinger) clearInterval(this.pinger);
    this.child?.stdin?.end();
    this.child?.kill("SIGTERM");
  }
}

/** How many turns of the session started with this marker, and whether the last one ended. */
async function turnState(ctx: ChaosContext, marker: string): Promise<{ started: number; running: boolean; status: string; detail: string }> {
  const r = await ctx.exec(`${ctx.guest}"$c" acp --json history ${shq(ctx.session)} --limit 20 2>&1`, 45_000);
  let turns: any[] = [];
  try { turns = JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).turns ?? []; } catch { /* unreadable: counted as 0 */ }
  const mine = turns.filter((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker));
  // `acp history` rows carry `status`: "running" while the turn is open (acpmux cli/orchestrate.rs).
  const running = mine.some((t: any) => t.status === "running");
  return {
    started: mine.length,
    running,
    status: mine.map((t: any) => String(t.status)).join(","),
    detail: mine.map((t: any) => String(t.detail ?? "")).join(","),
  };
}

async function turnOutcome(ctx: ChaosContext, marker: string): Promise<{ ok: boolean; text: string }> {
  const until = Date.now() + TURN_DEADLINE_MS;
  let last = { started: 0, running: false, status: "", detail: "" };
  while (Date.now() < until) {
    try {
      last = await turnState(ctx, marker);
    } catch { /* the exec route itself recovering: try again */ }
    if (last.started > 1) return { ok: false, text: `started ${last.started} times (a duplicated prompt)` };
    // The turn's own terminal row decides (`acp wait` exits non-zero for a turn a restart cut short).
    if (last.started === 1 && !last.running) {
      if (last.status === "completed") return { ok: true, text: "completed once" };
      // A turn a restart cut short ends as acpmux's interrupted outcome (status failed, detail outcome_unknown), which
      // the person sees as such: it ran once and ended, nothing was lost or doubled.
      if (/outcome_unknown|interrupted/.test(`${last.status} ${last.detail}`)) {
        return { ok: true, text: `ended once, interrupted (${last.status}: ${last.detail})` };
      }
      return { ok: false, text: `ended once as ${last.status}${last.detail ? ` (${last.detail})` : ""}` };
    }
    await sleep(2_000);
  }
  return last.started === 0
    ? { ok: false, text: `never started within ${TURN_DEADLINE_MS / 1000} s (a lost prompt)` }
    : { ok: false, text: `started, not finished within ${TURN_DEADLINE_MS / 1000} s` };
}

/** Run every fault on the machine; one result per fault, the not-injectable ones included. */
export async function runChaos(ctx: ChaosContext): Promise<ChaosResult[]> {
  const out: ChaosResult[] = [];
  const carrier = new Carrier(ctx);
  carrier.start();
  try {
    const first = await carrier.answeredAfter(0, 60_000);
    if (first === null) throw new Error("the carrier dial never answered identify before the faults");
    for (const f of FAULTS) {
      const marker = `[chaos ${ctx.tag} ${f.name}]`;
      const sent = await ctx.exec(`${ctx.guest}printf '%s' ${shq(`${marker} Reply with one short sentence.`)} | "$c" acp send --no-wait ${shq(ctx.session)} - 2>&1; echo "@@exit $?"`, 60_000);
      if (!/@@exit 0/.test(sent.stdout)) {
        out.push({ fault: f.name, outcome: "fail", recover_ms: null, carrier: "", turn: "", detail: `the turn did not start: ${sent.stdout.slice(-200)}` });
        continue;
      }
      // Mid-turn: the fault goes in only once the turn shows in the session's history. A stub reply can end before it
      // is ever seen running; that fault is then reported as after the turn, not as mid-turn.
      let state = { started: 0, running: false, status: "", detail: "" };
      for (const until = Date.now() + 60_000; Date.now() < until; await sleep(500)) {
        state = await turnState(ctx, marker).catch(() => state);
        if (state.started > 0) break;
      }
      if (state.started === 0) {
        out.push({ fault: f.name, outcome: "fail", recover_ms: null, carrier: "", turn: "", detail: "the turn was sent but never showed in the session's history within 60 s" });
        continue;
      }
      const when = state.running ? "mid-turn" : `after the turn (${state.status})`;
      const dialsBefore = carrier.dials;
      const resumesBefore = carrier.routeLines.filter((l) => /phase=resume .*outcome=ok/.test(l)).length;
      // The cause starts when the command runs, which is after this moment: timing from here makes recovery an upper
      // bound. A drop may hold the exec's own answer until it ends, so its budget covers the drop.
      const injectedAt = Date.now();
      const injected = await ctx.exec(`${ctx.guest}${f.command}`, f.secs * 1000 + 60_000).catch((e: Error) => ({ code: 1, stdout: e.message, stderr: "" }));
      if (!/@@ok/.test(injected.stdout)) {
        // A fault meant to run that could not be injected fails the leg: a probe must never read ok on a fault it skipped.
        out.push({ fault: f.name, outcome: "fail", recover_ms: null, carrier: "", turn: "", detail: `could not inject: ${(injected.stdout + injected.stderr).trim().slice(-200)}` });
        continue;
      }
      const healed = injectedAt + f.secs * 1000;
      await sleep(Math.max(0, healed - Date.now()));
      const back = await carrier.answeredAfter(healed, RECOVER_DEADLINE_MS);
      const recover = back === null ? null : back - healed;
      const resumed = carrier.routeLines.filter((l) => /phase=resume .*outcome=ok/.test(l)).length > resumesBefore;
      const how = carrier.dials > dialsBefore ? `new dial (${carrier.dials - dialsBefore})` : resumed ? "resumed the session" : "unbroken";
      const turn = await turnOutcome(ctx, marker);
      const ok = recover !== null && turn.ok;
      const result: ChaosResult = {
        fault: f.name,
        outcome: ok ? "ok" : "fail",
        recover_ms: recover,
        carrier: how,
        turn: turn.text,
        detail: `injected ${when}; ${recover === null ? `no answer within ${RECOVER_DEADLINE_MS / 1000} s` : `answered ${recover} ms after the cause ended`}; carrier ${how}; turn ${turn.text}`,
      };
      ctx.log?.(`chaos: ${f.name}: ${result.detail}`);
      out.push(result);
      // Let the carrier settle before the next fault.
      await carrier.answeredAfter(Date.now(), 30_000);
    }
  } finally {
    carrier.stop();
  }
  for (const n of NOT_INJECTED) out.push({ fault: n.name, outcome: "not run", recover_ms: null, carrier: "", turn: "", detail: n.why });
  return out;
}

/** The leg as one synthetic-probe row (cmuxterm-hq probes.py): ok only when every injected fault passed. */
export function chaosProbeRow(probe: string, results: ChaosResult[], run?: string, at = new Date()): Record<string, unknown> {
  const ran = results.filter((r) => r.outcome !== "not run");
  const failed = ran.filter((r) => r.outcome === "fail");
  const times = ran.map((r) => r.recover_ms).filter((n): n is number => typeof n === "number");
  return {
    probe,
    at: at.toISOString().replace(/\.\d+Z$/, "Z"),
    outcome: ran.length && !failed.length ? "ok" : "fail",
    ms: times.length ? Math.max(...times) : null,
    error: failed.length ? failed.map((r) => `${r.fault}: ${r.detail}`).join("; ").slice(0, 500) : ran.length ? null : "no fault ran",
    faults: results,
    ...(run ? { run } : {}),
  };
}
