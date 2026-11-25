/**
 * The chaos leg's move drills (`cloud-journey.ts --chaos-move`): one side of a chat move is killed mid-step on real
 * Cloud machines, and the leg reports what the person lost.
 *
 * Directions: local→Cloud (this machine plays the Mac: a headless cmux-tui daemon and its acpmux in a home of their
 * own, `LocalMachine`), Cloud→local, and Cloud→Cloud (two machines). Per run the source chat holds a counting turn in
 * flight (the model stub's `moveTurnScript`), a prompt queued behind it, a composer draft, and a git folder with an
 * unpushed commit and an uncommitted edit made after the folder's first sync. The move is the app's pump
 * (`cmux link agent move`, the args each app flow passes: CloudMove, CloudTransferLocal, CloudMove's relay), run
 * through a line proxy on each of its sockets (`MoveProxy`) that stops the pump exactly at a step:
 *
 *   before-begin   holds agent-transfer-begin's request          after-begin    holds its answer
 *   frozen-sync    holds the first sync-socket request after the begin answered
 *   after-receive  holds agent-transfer-receive's answer         mid-copy       holds the first agent-transfer-write answer
 *   before-finish  holds agent-transfer-finish's request         after-finish   holds its answer
 *   after-commit   holds agent-transfer-commit's answer
 *
 * and, while the pump waits there, kills one side:
 *
 *   kill-src/-dst   SIGKILL that side's cmux-tui daemon and its acpmux (a Cloud machine's supervisors start them again)
 *   off-src/-dst    power off with no shutdown: a Cloud machine's kernel is told to power off (sysrq `o`) and the
 *                   machine is started again; a local side loses every process of that machine, the pump included
 *   cut             the far side the step talks to stops answering: a Cloud machine drops its 443 traffic both ways
 *                   (iptables, restored by a timer on the machine itself); a local daemon's socket is held by the proxy
 *   pause-src/-dst  Freestyle suspend (`cloud.machine.pause`), resumed after a seeded 5–60 s; a local side is
 *                   SIGSTOPped for that long (a Mac that sleeps)
 *
 * Then the survivors come back, the pump runs once more if its first run did not finish (the app's Retry), and the
 * leg records: where the chat is open (exactly one place), whether the survivor's journal still holds every record
 * the source journal held when the move began, how many times the queued prompt ran overall, whether the draft is
 * there, where the uncommitted edit and the unpushed commit can still be found (landed side, source folder, git
 * remote, nowhere), and what the person saw (the pump's error_code and retry, and how long until that answer).
 * Product code is never changed here: a loss is a finding.
 */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import path from "node:path";
import { type ChaosExec, dropCommand, sessionHostKillCommand } from "./cloud-chaos.ts";

export const MOVE_DIRECTIONS = ["local-cloud", "cloud-local", "cloud-cloud"] as const;
export const MOVE_STEPS = ["before-begin", "after-begin", "frozen-sync", "after-receive", "mid-copy", "before-finish", "after-finish", "after-commit"] as const;
export const MOVE_KILLS = ["kill-src", "kill-dst", "off-src", "off-dst", "cut", "pause-src", "pause-dst"] as const;
export type MoveDirection = (typeof MOVE_DIRECTIONS)[number];
export type MoveStep = (typeof MOVE_STEPS)[number];
export type MoveKill = (typeof MOVE_KILLS)[number];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/** The counting turn of a move run: long enough that the move always lands mid-turn. */
export const MOVE_COUNT_STEPS = 240;
const MOVE_COUNT_PAUSE_S = 0.5;
export const moveCountMarker = (tag: string) => `[kmm-count ${tag}]`;
export const moveQueuedMarker = (tag: string) => `[kmm-queued ${tag}]`;
export const moveDraft = (tag: string) => `kmm draft ${tag}: half a thought the person was typing`;

/**
 * The model stub's turn scripts for a move run (model_stub.py "turns"): the counting turn reads `K.txt` in the folder
 * its prompt names, one file every MOVE_COUNT_PAUSE_S, and the queued prompt's turn is one text reply, so it never
 * runs a shell command (which waits for a person under policy `ask`) and never replays the counting turn (the stub
 * plays the latest prompt any turn script matches).
 */
export function moveTurnScripts(n = MOVE_COUNT_STEPS): Array<{ match: string; steps: Array<Record<string, unknown>> }> {
  const tag = "{{prompt~\\[kmm-count (\\S+)\\]}}";
  const dir = "{{prompt~ files in (/\\S+?)/ in order}}";
  const steps: Array<Record<string, unknown>> = [];
  for (let k = 1; k <= n; k++) steps.push({ tool: { name: "Read", input: { file_path: `${dir}/${k}.txt` } }, pause: MOVE_COUNT_PAUSE_S });
  steps.push({ text: `Counted ${n} steps for ${tag}.` });
  return [
    { match: "\\[kmm-count \\S+\\]", steps },
    { match: "\\[kmm-queued \\S+\\]", steps: [{ text: "Queued reply {{prompt}}." }] },
  ];
}

/** A small seeded generator (mulberry32), so a run's choices come back from its seed. */
export function moveRng(seed: string): () => number {
  let h = 1779033703 ^ seed.length;
  for (let i = 0; i < seed.length; i++) h = Math.imul(h ^ seed.charCodeAt(i), 3432918353), (h = (h << 13) | (h >>> 19));
  let a = h >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const pick = <T>(rng: () => number, xs: readonly T[]): T => xs[Math.floor(rng() * xs.length) % xs.length];

/**
 * The buttons lane's Step a drill step falls in (cmux-cloud-start-core src/moves/place.rs Step, as relayed by the
 * kill-mid-move-drills lane): freeze, carry or commit. bulk_sync is the folder's first sync before the move, which
 * these steps never stop in.
 */
export function buttonStep(step: MoveStep): "freeze" | "carry" | "commit" {
  if (step === "before-begin" || step === "after-begin") return "freeze";
  if (step === "frozen-sync") return "carry";
  return "commit";
}

/** Where the pump stops for a step: which socket role, which command, its request or its answer. */
export type MoveTrigger = { roles: Array<"from" | "to" | "sync" | "sync-from">; cmd: string | null; on: "request" | "answer" };
export function moveTrigger(step: MoveStep): MoveTrigger {
  switch (step) {
    case "before-begin": return { roles: ["from"], cmd: "agent-transfer-begin", on: "request" };
    case "after-begin": return { roles: ["from"], cmd: "agent-transfer-begin", on: "answer" };
    case "frozen-sync": return { roles: ["sync", "sync-from"], cmd: null, on: "request" };
    case "after-receive": return { roles: ["to"], cmd: "agent-transfer-receive", on: "answer" };
    case "mid-copy": return { roles: ["to"], cmd: "agent-transfer-write", on: "answer" };
    case "before-finish": return { roles: ["to"], cmd: "agent-transfer-finish", on: "request" };
    case "after-finish": return { roles: ["to"], cmd: "agent-transfer-finish", on: "answer" };
    case "after-commit": return { roles: ["from"], cmd: "agent-transfer-commit", on: "answer" };
  }
}

/** Which side a step talks to (the far side a `cut` drops). frozen-sync talks to the sync socket's machine. */
export function stepSide(step: MoveStep, direction: MoveDirection): "src" | "dst" {
  if (step === "before-begin" || step === "after-begin" || step === "after-commit") return "src";
  if (step === "frozen-sync") return direction === "cloud-local" ? "src" : "dst";
  return "dst";
}

const TRANSFER_CMD = /"cmd"\s*:\s*"(agent-transfer-[a-z-]+)"/;
const ID_OF = /"id"\s*:\s*(\d+)/;

/**
 * The trip wire the proxies share: it fires once, at the step, and the pump's stream waits while `fire` runs. A
 * proxy `blackhole` holds every byte of the named roles both ways until it ends (a local side's `cut`).
 */
export class MoveTripwire {
  fired = false;
  /** The step's own answer came back a refusal, so the step never happened. */
  refused = false;
  firedAt = 0;
  begun = false;
  writes = 0;
  trace: string[] = [];
  private t0 = Date.now();
  private hole: { roles: Set<string>; until: number } | null = null;
  constructor(private trigger: MoveTrigger, private fire: () => Promise<void>) {}

  note(text: string): void {
    this.trace.push(`+${((Date.now() - this.t0) / 1000).toFixed(1)}s ${text}`);
  }

  blackhole(roles: string[], ms: number): void {
    this.hole = { roles: new Set(roles), until: Date.now() + ms };
    this.note(`blackhole ${roles.join(",")} ${ms} ms`);
  }

  async held(role: string): Promise<void> {
    while (this.hole && this.hole.roles.has(role) && Date.now() < this.hole.until) await sleep(100);
  }

  /** Called for every complete line before it is forwarded; resolves once it may go on. */
  async onLine(role: string, dir: "request" | "answer", line: string, cmdOfAnswer: string | null): Promise<void> {
    const cmd = dir === "request" ? TRANSFER_CMD.exec(line)?.[1] ?? null : cmdOfAnswer;
    if (cmd) this.note(`${role} ${dir} ${cmd}${dir === "answer" ? ` ${/"ok"\s*:\s*true/.test(line) ? "ok" : `refused ${/"error_code"\s*:\s*"([^"]+)"/.exec(line)?.[1] ?? "?"}`}` : ""}`);
    if (cmd === "agent-transfer-begin" && dir === "answer") this.begun = true;
    if (cmd === "agent-transfer-write" && dir === "answer") this.writes++;
    if (this.fired) return;
    const t = this.trigger;
    if (!t.roles.includes(role as never) || dir !== t.on) return;
    if (t.cmd === null) {
      // frozen-sync: the first request on a sync socket once the begin has answered.
      if (!this.begun || dir !== "request") return;
      this.note(`${role} sync request ${(/"cmd"\s*:\s*"([^"]+)"/.exec(line)?.[1] ?? line.slice(0, 40))}`);
    } else if (cmd !== t.cmd) return;
    // An answer step happened only when the side said yes: a refusal there is the move ending early, not the step.
    else if (dir === "answer" && !/"ok"\s*:\s*true/.test(line)) { this.refused = true; return; }
    this.fired = true;
    this.firedAt = Date.now();
    this.note(`trigger: holding the ${dir}; fault in`);
    await this.fire().catch((e: Error) => this.note(`fault error: ${e.message}`));
    this.note("fault done; forwarding");
  }
}

/** A Unix-socket forwarder for one pump socket role: every line checked against the trip wire before it goes on. */
export class MoveProxy {
  private server: Server | null = null;
  readonly conns = new Set<Socket>();
  constructor(readonly role: string, readonly listen: string, readonly upstream: string, private wire: MoveTripwire) {}

  async start(): Promise<void> {
    this.server = createServer((down) => this.accept(down));
    await new Promise<void>((resolve, reject) => {
      this.server!.once("error", reject);
      this.server!.listen(this.listen, () => resolve());
    });
    chmodSync(this.listen, 0o600);
  }

  stop(): void {
    for (const c of this.conns) c.destroy();
    this.server?.close();
  }

  private accept(down: Socket): void {
    const up = createConnection(this.upstream);
    this.conns.add(down);
    this.conns.add(up);
    const ids = new Map<string, string>();
    const end = () => {
      down.destroy();
      up.destroy();
      this.conns.delete(down);
      this.conns.delete(up);
    };
    up.on("error", (e) => (this.wire.note(`${this.role} upstream error ${e.message}`), end()));
    down.on("error", end);
    up.on("close", end);
    down.on("close", end);
    this.pipe(down, up, "request", ids);
    this.pipe(up, down, "answer", ids);
  }

  /**
   * Bytes go on at line ends, in order; a partial line waits at most 50 ms (or 1 MiB) and then goes on as it is, so a
   * stream that is not line-framed is never stalled. Only complete lines can trip the wire.
   */
  private pipe(from: Socket, to: Socket, dir: "request" | "answer", ids: Map<string, string>): void {
    let buf = Buffer.alloc(0);
    let chain = Promise.resolve();
    let timer: ReturnType<typeof setTimeout> | null = null;
    const write = (b: Buffer) => { if (!to.destroyed) to.write(b); };
    const flushPartial = () => {
      timer = null;
      chain = chain.then(async () => {
        await this.wire.held(this.role);
        if (buf.length) { const b = buf; buf = Buffer.alloc(0); write(b); }
      });
    };
    from.on("data", (chunk: Buffer) => {
      buf = Buffer.concat([buf, chunk]);
      let nl: number;
      while ((nl = buf.indexOf(10)) >= 0) {
        const line = buf.subarray(0, nl + 1);
        buf = buf.subarray(nl + 1);
        chain = chain.then(async () => {
          const text = line.length < 1 << 20 ? line.toString("utf8") : line.subarray(0, 4096).toString("utf8");
          let cmdOfAnswer: string | null = null;
          if (dir === "request") {
            const cmd = TRANSFER_CMD.exec(text)?.[1];
            const id = ID_OF.exec(text)?.[1];
            if (cmd && id) ids.set(id, cmd);
          } else {
            const id = ID_OF.exec(text)?.[1];
            if (id && ids.has(id) && !/"event"\s*:/.test(text.slice(0, 200))) { cmdOfAnswer = ids.get(id)!; ids.delete(id); }
          }
          await this.wire.held(this.role);
          await this.wire.onLine(this.role, dir, text, cmdOfAnswer);
          write(line);
        });
      }
      if (buf.length >= 1 << 20) flushPartial();
      else if (buf.length && !timer) timer = setTimeout(flushPartial, 50);
    });
    from.on("end", () => { chain = chain.then(() => { if (buf.length) write(buf); to.end(); }); });
  }
}

/** One machine the move touches, as the pump and the leg reach it. */
export type MoveSide = {
  name: string;
  kind: "local" | "cloud";
  /** The daemon socket the pump uses: a local daemon's socket, or a Cloud machine's `cmux carrier serve` socket. */
  socket: string;
  exec: ChaosExec;
  /** The shell prefix that sets `$c` to that machine's cmux-tui. */
  guest: string;
  home: string;
  machine?: string;
  local?: LocalMachine;
};

/**
 * This machine as the person's Mac: a headless daemon and its own acpmux in homes of their own, every process
 * started with an environment built from nothing (no login of this machine's reaches its agents), and the model stub
 * on its loopback. Every process of it carries its HOME, which is how off-src finds them all.
 */
export class LocalMachine {
  readonly socket: string;
  readonly home: string;
  readonly env: Record<string, string>;
  stubPort = 0;
  constructor(readonly dir: string, readonly cmux: string, private stubPy: string, private stubScript: unknown, private claudeBin: string, readonly session = `kmm-${path.basename(dir)}`) {
    this.socket = path.join(dir, "mux.sock");
    this.home = path.join(dir, "home");
    const bin = path.dirname(claudeBin);
    this.env = {
      PATH: `${bin}:${path.dirname(cmux)}:/usr/local/bin:/usr/bin:/bin`,
      HOME: this.home,
      USER: process.env.USER ?? "cmux",
      LANG: "C.UTF-8",
      TMPDIR: path.join(dir, "tmp"),
      ACPMUX_HOME: path.join(dir, "acpmux"),
      CMUX_TUI_STATE_DIR: path.join(dir, "state"),
      CMUX_TUI_CONFIG: path.join(dir, "config.json"),
      GIT_CONFIG_NOSYSTEM: "1",
    };
  }

  run(args: string[], timeoutMs = 60_000): { code: number; out: string } {
    const r = spawnSync(this.cmux, args, { env: this.env, encoding: "utf8", timeout: timeoutMs, stdio: ["ignore", "pipe", "pipe"] });
    return { code: r.status ?? -1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
  }

  readonly exec: ChaosExec = (command, timeoutMs = 60_000) => new Promise((resolve) => {
    const p = spawn("bash", ["-c", command], { env: this.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    p.stdout.on("data", (d) => (stdout += d));
    p.stderr.on("data", (d) => (stderr += d));
    const t = setTimeout(() => p.kill("SIGKILL"), timeoutMs);
    p.on("close", (code) => (clearTimeout(t), resolve({ code: code ?? -1, stdout, stderr })));
  });

  get guest(): string {
    return `c=${shq(this.cmux)}; `;
  }

  async start(): Promise<void> {
    for (const sub of ["home/work", "home/.claude", "acpmux", "state", "tmp"]) mkdirSync(path.join(this.dir, sub), { recursive: true, mode: 0o755 });
    chmodSync(path.join(this.dir, "acpmux"), 0o700);
    const config = path.join(this.dir, "acpmux/config.json");
    if (!existsSync(config)) writeFileSync(config, "{}\n", { mode: 0o600 });
    await this.startStub();
    const ensure = this.run(["server", "ensure", "--json", "--session", this.session, "--socket", this.socket]);
    if (ensure.code !== 0) throw new Error(`local daemon: ${ensure.out.slice(-300)}`);
    const acp = this.run(["acp", "daemon", "start"], 90_000);
    if (acp.code !== 0) throw new Error(`local acpmux: ${acp.out.slice(-300)}`);
  }

  /** The model stub on this machine's loopback, and Claude Code's settings pointed at it. */
  private stubProc: ChildProcess | null = null;
  private async startStub(): Promise<void> {
    if (this.stubProc && this.stubProc.exitCode === null && this.stubProc.signalCode === null) return;
    const script = path.join(this.dir, "stub.json");
    const ready = path.join(this.dir, "stub.ready");
    writeFileSync(script, JSON.stringify(this.stubScript));
    spawnSync("rm", ["-f", ready]);
    const p = spawn("python3", ["-I", this.stubPy, "--port", "0", "--script", script, "--ready-file", ready, "--log", path.join(this.dir, "stub.log")], { env: this.env, stdio: "ignore", detached: true });
    p.unref();
    this.stubProc = p;
    for (let i = 0; i < 100 && !existsSync(ready); i++) await sleep(100);
    this.stubPort = Number(JSON.parse(readFileSync(ready, "utf8")).port);
    const settings = path.join(this.home, ".claude/settings.json");
    writeFileSync(settings, JSON.stringify({ env: { ANTHROPIC_BASE_URL: `http://127.0.0.1:${this.stubPort}`, ANTHROPIC_API_KEY: "kmm-stub" } }));
  }

  /** The pids of every process of this machine: those whose environment carries its HOME. */
  pids(except: number[] = []): number[] {
    const marker = `\0HOME=${this.home}\0`;
    const out: number[] = [];
    for (const name of readdirSync("/proc")) {
      if (!/^\d+$/.test(name) || Number(name) === process.pid || except.includes(Number(name))) continue;
      try {
        if (`\0${readFileSync(`/proc/${name}/environ`, "latin1")}`.includes(marker)) out.push(Number(name));
      } catch { /* gone, or not ours */ }
    }
    return out;
  }

  /** The daemon's and acpmux's own pids, from what each recorded. */
  daemonPids(): number[] {
    const out: number[] = [];
    const st = this.run(["server", "status", "--json", "--session", this.session, "--socket", this.socket], 10_000);
    const dp = /"pid"\s*:\s*(\d+)/.exec(st.out)?.[1];
    if (dp) out.push(Number(dp));
    try { out.push(Number(readFileSync(path.join(this.dir, "acpmux/daemon.pid"), "utf8").trim())); } catch { /* not running */ }
    return out.filter((n) => n > 1);
  }

  signal(pids: number[], sig: NodeJS.Signals): number[] {
    const done: number[] = [];
    for (const p of pids) try { process.kill(p, sig); done.push(p); } catch { /* gone */ }
    return done;
  }

  async stop(): Promise<void> {
    this.run(["acp", "daemon", "shutdown", "--end-agents"], 30_000);
    this.run(["server", "stop", "--end-terminals", "--json", "--session", this.session, "--socket", this.socket], 30_000);
    await sleep(500);
    this.signal(this.pids(), "SIGKILL");
  }
}

/**
 * `cmux carrier serve` for one Cloud machine: the app-link socket the app hands the pump. Serve ends when its stdin
 * closes and removes the socket, so stdin stays an open pipe for as long as this serves (with "ignore" it printed its
 * ready line and left at once: run 45162400826's seed pushes all found no socket). `env` is read at each start, so a
 * restart carries the journey's current access token.
 */
export class CarrierServe {
  proc: ChildProcess | null = null;
  constructor(readonly machine: string, readonly socket: string, private cmux: string, private env: () => Record<string, string | undefined>, private team?: string) {}

  async start(): Promise<void> {
    const args = ["carrier", "serve", "--machine", this.machine, "--socket", this.socket];
    if (this.team) args.push("--team", this.team);
    const p = spawn(this.cmux, args, { env: this.env() as NodeJS.ProcessEnv, stdio: ["pipe", "ignore", "pipe"] });
    this.proc = p;
    let err = "";
    await new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`carrier serve ${this.machine}: not listening after 60 s: ${err.slice(-300)}`)), 60_000);
      p.stderr!.on("data", (d) => {
        err += d;
        if (/"route"\s*:\s*"carrier"/.test(err)) { clearTimeout(t); resolve(); }
      });
      p.on("exit", (code) => { clearTimeout(t); reject(new Error(`carrier serve ${this.machine} exited ${code}: ${err.slice(-300)}`)); });
    });
  }

  stop(): void {
    this.proc?.stdin?.end();
    this.proc?.kill("SIGKILL");
    this.proc = null;
  }
}

/**
 * Requests on one daemon connection, in order, each answered before the next goes (events and other ids skipped):
 * the last one's answer, or the first refusal. A prompt goes after an attach on the same connection, as the app's.
 */
export function daemonRpc(socket: string, frame: Record<string, unknown> | Array<Record<string, unknown>>, timeoutMs = 60_000): Promise<any> {
  const frames = Array.isArray(frame) ? frame : [frame];
  return new Promise((resolve, reject) => {
    const base = Math.floor(Math.random() * 1e9);
    let at = 0;
    const s = createConnection(socket);
    let buf = "";
    const name = frames.map((f) => String(f.cmd)).join("+");
    const t = setTimeout(() => { s.destroy(); reject(new Error(`${name}: no answer in ${timeoutMs} ms`)); }, timeoutMs);
    const send = () => s.write(`${JSON.stringify({ ...frames[at], id: base + at })}\n`);
    s.on("connect", send);
    s.on("data", (d) => {
      buf += d;
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        let m: any;
        try { m = JSON.parse(line); } catch { continue; }
        if (m?.id !== base + at) continue;
        if (!m.ok || at === frames.length - 1) { clearTimeout(t); s.destroy(); resolve(m); return; }
        at++;
        send();
      }
    });
    s.on("error", (e) => { clearTimeout(t); reject(e); });
  });
}

/**
 * The acpmux helper the leg runs on a side (python, through that side's exec): `summary`, `events` and `draft_get`
 * for a session, and `draft_set`. It finds acpmux's socket from `acp --json daemon status`.
 */
export const ACPMUX_PY = String.raw`
import json, os, socket, subprocess, sys
op, session = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
st = json.loads(subprocess.run([os.environ["C"], "acp", "--json", "daemon", "status"], capture_output=True, text=True, timeout=30).stdout or "{}")
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(st["socket"])
f = s.makefile("rwb")
n = [0]
def call(method, params):
    n[0] += 1
    f.write((json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}) + "\n").encode()); f.flush()
    while True:
        m = json.loads(f.readline())
        if m.get("id") == n[0]:
            if "error" in m: raise SystemExit("@@error " + json.dumps(m["error"])[:300])
            return m.get("result")
call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "kmm-drill"}})
if op == "summary":
    r = call("_acpmux/sessions", {})
    rows = r.get("sessions", r) if isinstance(r, dict) else r
    mine = [x for x in rows or [] if x.get("sessionId") == session]
    print("@@json " + json.dumps(mine[0] if mine else None))
elif op == "events":
    out, after = [], 0
    while True:
        r = call("_acpmux/events", {"sessionId": session, "afterSeq": after, "limit": 500})
        evs = r.get("events", r) if isinstance(r, dict) else r
        if not evs: break
        for e in evs:
            m = e.get("msg") or {}
            text = json.dumps(m)[:2000]
            out.append({"seq": e.get("seq"), "kind": e.get("kind"), "promptId": m.get("promptId") or (m.get("_meta") or {}).get("promptId"), "text": text})
        after = max(x.get("seq") or 0 for x in evs)
        if len(evs) < 500: break
    print("@@json " + json.dumps(out))
elif op == "draft_get":
    print("@@json " + json.dumps(call("_acpmux/draft_get", {"sessionId": session})))
elif op == "draft_set":
    print("@@json " + json.dumps(call("_acpmux/draft_set", {"sessionId": session, "text": arg})))
`;

export async function acpmuxOn(side: MoveSide, op: string, session: string, arg = ""): Promise<any> {
  const r = await side.exec(`${side.guest}C="$c" python3 -I -c ${shq(ACPMUX_PY)} ${shq(op)} ${shq(session)} ${shq(arg)} 2>&1`, 60_000);
  const m = /@@json (.*)$/m.exec(r.stdout);
  if (!m) throw new Error(`acpmux ${op} on ${side.name}: ${(r.stdout + r.stderr).trim().slice(-300)}`);
  return JSON.parse(m[1]);
}

/**
 * The chat folder's git state: a bare remote on the source machine, a pushed base commit, and (`dirty`, after the
 * folder's first sync) one unpushed commit and one uncommitted edit, each carrying the run's tag. The counting files
 * live outside the repository's tracked set (`.git/info/exclude`).
 */
export function gitFixtureCommand(folder: string, remote: string, tag: string): string {
  const g = `git -c user.name=kmm -c user.email=kmm@example.com -c commit.gpgsign=false -c init.defaultBranch=main`;
  return `set -e; d=${shq(folder)}; r=${shq(remote)}; mkdir -p "$d"; ${g} init -q --bare "$r"; cd "$d"; ${g} init -q; ` +
    `git remote add origin "$r"; echo chaos-count/ >> .git/info/exclude; echo base > base.txt; ${g} add base.txt; ${g} commit -q -m base; ` +
    `${g} push -q -u origin HEAD:main 2>&1; echo "@@base $(git rev-parse HEAD)"`;
}
export function gitDirtyCommand(folder: string, tag: string): string {
  const g = `git -c user.name=kmm -c user.email=kmm@example.com -c commit.gpgsign=false`;
  return `set -e; cd ${shq(folder)}; echo ${shq(`unpushed ${tag}`)} > unpushed.txt; ${g} add unpushed.txt; ${g} commit -q -m ${shq(`kmm unpushed ${tag}`)}; ` +
    `echo "@@commit $(git rev-parse HEAD)"; echo ${shq(`uncommitted ${tag}`)} >> base.txt; echo "@@dirty ok"`;
}
/** Whether `folder` holds the edit and the commit, and whether `remote` holds the commit. */
export function gitFindCommand(folder: string, remote: string, tag: string, sha: string): string {
  return `if grep -qF ${shq(`uncommitted ${tag}`)} ${shq(folder)}/base.txt 2>/dev/null; then echo @@edit yes; else echo @@edit no; fi; ` +
    `if git -C ${shq(folder)} cat-file -e ${shq(`${sha}^{commit}`)} 2>/dev/null; then echo @@commit yes; else echo @@commit no; fi; ` +
    `if [ -n ${shq(remote)} ] && git --git-dir=${shq(remote)} cat-file -e ${shq(`${sha}^{commit}`)} 2>/dev/null; then echo @@remote yes; else echo @@remote no; fi`;
}

export function countFilesCommand(dir: string, tag: string, n = MOVE_COUNT_STEPS): string {
  return `d=${shq(dir)}; mkdir -p "$d" && k=0 && while [ "$k" -lt ${n} ]; do k=$((k+1)); printf '%s-%s-%s\\n' kmm ${shq(tag)} "$k" > "$d/$k.txt" || exit 1; done && echo "@@dir $d"`;
}

/** What the drill gives each Cloud machine and what it may do to one, supplied by cloud-journey.ts. */
export type MoveContext = {
  cmux: string;
  /** The carrier's environment: the Cloud API and the person's bearer, read at each carrier start (the journey refreshes the token in place). */
  env: Record<string, string | undefined>;
  machines: [string, string];
  team?: string;
  execFor: (machine: string) => ChaosExec;
  guest: string;
  credentials?: { env: Record<string, string> };
  pause: (machine: string) => Promise<void>;
  start: (machine: string) => Promise<void>;
  status: (machine: string) => Promise<string>;
  /** Starts the model stub on the machine again (after a power-off ended it). */
  ensureStub: (machine: string) => Promise<void>;
  stubPy: string;
  stubScript: unknown;
  claudeBin: string;
  tag: string;
  seed: string;
  /** Randomized runs (`--runs N`): each picks direction, step and kill from the seed. 0: the matrix. */
  runs: number;
  directions: MoveDirection[];
  steps: MoveStep[];
  kills: MoveKill[];
  log: (line: string) => void;
  /** Called after each run, so a long matrix leaves its rows even if the job is cancelled. */
  onResult?: (r: MoveResult) => void;
};

export type MoveResult = {
  run: string;
  seed: string;
  direction: MoveDirection;
  step: MoveStep;
  /** The buttons lane's Step name for `step` (buttonStep). */
  button_step: "freeze" | "carry" | "commit";
  kill: MoveKill;
  outcome: "pass" | "fail" | "unmeasured";
  /** What the person lost; empty: nothing. */
  lost: string[];
  open: string;
  /** Distinct runs of the queued prompt overall, and the turn_result records each side's journal holds for it. */
  queued_runs: number;
  queued_src?: number;
  queued_dst?: number;
  draft: string;
  edit: string;
  commit: string;
  pump_first: string;
  pump_retry: string;
  /** From the fault to the pump's last answer: how long until the person saw where the move ended. */
  seen_ms: number | null;
  fault_s: number | null;
  detail: string;
  trace: string[];
};

const PUMP_DEADLINE_MS = 330_000;
const BACK_DEADLINE_MS = 300_000;

/** The pump's one JSON line, or what happened instead. */
type PumpAnswer = { ok: boolean; json: any; code: number | null; killed: boolean; ms: number; text: string };

function pumpText(p: PumpAnswer | null): string {
  if (!p) return "not run";
  if (p.killed) return `killed (${p.text})`;
  if (p.json?.ok === true) return `ok (${p.json.resolved ? `resolved ${p.json.resolved}` : "moved"}, ${p.ms} ms)`;
  if (p.json) return `${p.json.error_code ?? "error"}${p.json.retry_after_seconds !== undefined ? ` retry ${p.json.retry_after_seconds}s` : ""}${p.json.side ? ` side ${p.json.side}` : ""}: ${String(p.json.error ?? "").slice(0, 120)} (${p.ms} ms)`;
  return `exit ${p.code} no JSON: ${p.text.slice(-160)} (${p.ms} ms)`;
}

/** Runs the pump to its end or its deadline; the process is this leg's own, so it may be killed. */
function runPump(cmux: string, args: string[], env: Record<string, string>, onSpawn?: (p: ChildProcess) => void): Promise<PumpAnswer> {
  const t0 = Date.now();
  return new Promise((resolve) => {
    const p = spawn(cmux, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    onSpawn?.(p);
    let out = "";
    let err = "";
    let killed = false;
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    const t = setTimeout(() => { killed = true; p.kill("SIGKILL"); }, PUMP_DEADLINE_MS);
    p.on("close", (code, sig) => {
      clearTimeout(t);
      const line = out.trim().split("\n").reverse().find((l) => l.startsWith("{"));
      let json: any = null;
      try { json = line ? JSON.parse(line) : null; } catch { /* not JSON */ }
      resolve({ ok: json?.ok === true, json, code, killed: killed || sig === "SIGKILL", ms: Date.now() - t0, text: killed ? `past ${PUMP_DEADLINE_MS / 1000} s` : sig ? `signal ${sig}: ${err.slice(-200)}` : err.slice(-300) });
    });
  });
}

/** Every planned run: the matrix (each direction × step × kill once), or `runs` seeded random picks. */
export function movePlan(ctx: Pick<MoveContext, "runs" | "seed" | "directions" | "steps" | "kills">): Array<{ direction: MoveDirection; step: MoveStep; kill: MoveKill; seed: string }> {
  const out: Array<{ direction: MoveDirection; step: MoveStep; kill: MoveKill; seed: string }> = [];
  if (ctx.runs > 0) {
    const rng = moveRng(ctx.seed);
    for (let i = 0; i < ctx.runs; i++) {
      out.push({ direction: pick(rng, ctx.directions), step: pick(rng, ctx.steps), kill: pick(rng, ctx.kills), seed: `${ctx.seed}-${i}` });
    }
    return out;
  }
  for (const direction of ctx.directions) for (const step of ctx.steps) for (const kill of ctx.kills) out.push({ direction, step, kill, seed: `${ctx.seed}-${direction}-${step}-${kill}` });
  return out;
}

/** Run the plan; one result per run. Sides are made once and brought back between runs. */
export async function runMoveChaos(ctx: MoveContext): Promise<MoveResult[]> {
  const root = mkdtempSync("/tmp/kmm-");
  chmodSync(root, 0o700);
  const local = new LocalMachine(path.join(root, "L"), ctx.cmux, ctx.stubPy, ctx.stubScript, ctx.claudeBin);
  await local.start();
  ctx.log(`move: local machine up at ${local.dir} (stub on ${local.stubPort})`);
  const carriers = ctx.machines.map((m, i) => new CarrierServe(m, path.join(root, `c${i}.sock`), ctx.cmux, () => ({ ...ctx.env, CMUX_TUI_STATE_DIR: path.join(root, `cs${i}`) }), ctx.team));
  for (const c of carriers) await c.start();
  const cloudSide = (i: number): MoveSide => ({ name: i === 0 ? "A" : "B", kind: "cloud", socket: carriers[i].socket, exec: ctx.execFor(ctx.machines[i]), guest: ctx.guest, home: "/home/cmux", machine: ctx.machines[i] });
  const localSide: MoveSide = { name: "L", kind: "local", socket: local.socket, exec: local.exec, guest: local.guest, home: local.home, local };
  const results: MoveResult[] = [];
  try {
    for (const [i, plan] of movePlan(ctx).entries()) {
      const run = `${ctx.tag}-${i}`;
      const [src, dst] = plan.direction === "local-cloud" ? [localSide, cloudSide(0)]
        : plan.direction === "cloud-local" ? [cloudSide(0), localSide] : [cloudSide(0), cloudSide(1)];
      ctx.log(`move: run ${run} seed ${plan.seed}: ${plan.direction} ${plan.step} ${plan.kill}`);
      const r = await moveRun(ctx, { ...plan, run, root, src, dst, local, carriers }).catch((e: Error): MoveResult => ({
        run, seed: plan.seed, direction: plan.direction, step: plan.step, button_step: buttonStep(plan.step), kill: plan.kill, outcome: "unmeasured", lost: [], open: "", queued_runs: -1,
        draft: "", edit: "", commit: "", pump_first: "", pump_retry: "", seen_ms: null, fault_s: null, detail: `the run broke: ${e.message}`, trace: [],
      }));
      results.push(r);
      ctx.onResult?.(r);
      ctx.log(`move: ${run} ${r.outcome}: lost ${r.lost.join("; ") || "nothing"}; pump ${r.pump_first}${r.pump_retry !== "not run" ? ` then ${r.pump_retry}` : ""}; ${r.detail}`);
      if (r.outcome !== "pass") ctx.log(`move: ${run} seed ${plan.seed} trace:\n  ${r.trace.join("\n  ")}`);
      // Every side healthy before the next run, whatever this one did.
      await bringBack(ctx, carriers, [localSide, cloudSide(0), cloudSide(1)], () => undefined).catch((e: Error) => ctx.log(`move: sides not all back after ${run}: ${e.message}`));
    }
  } finally {
    for (const c of carriers) c.stop();
    await local.stop().catch(() => undefined);
  }
  return results;
}

export type RunArgs = { direction: MoveDirection; step: MoveStep; kill: MoveKill; seed: string; run: string; root: string; src: MoveSide; dst: MoveSide; local: LocalMachine; carriers: CarrierServe[]; /** The harness's own self-test between two local daemons, which serve no file ops: no folder sync. */ noSync?: boolean };

async function waitIdentify(socket: string, ms: number): Promise<boolean> {
  for (const until = Date.now() + ms; Date.now() < until; await sleep(2_000)) {
    const r = await daemonRpc(socket, { cmd: "identify" }, 20_000).catch(() => null);
    if (r?.ok) return true;
  }
  return false;
}

/** Brings every side back: the local machine and the carriers running, each Cloud machine running and answering. */
export async function bringBack(ctx: Pick<MoveContext, "status" | "start" | "ensureStub">, carriers: CarrierServe[], sides: MoveSide[], note: (s: string) => void): Promise<void> {
  for (const s of sides) {
    const local = s.local;
    if (!local) continue;
    if (!(await daemonRpc(local.socket, { cmd: "identify" }, 5_000).then((r) => r?.ok, () => false)) || local.daemonPids().length < 2) {
      note(`local machine ${s.name}: starting again`);
      await local.start();
    }
  }
  for (const c of carriers) if (!c.proc || c.proc.exitCode !== null) { note(`carrier ${c.machine}: serving again`); await c.start(); }
  for (const s of sides.filter((x) => x.kind === "cloud")) {
    const st = await ctx.status(s.machine!).catch((e: Error) => `unknown (${e.message})`);
    if (st !== "running") {
      note(`${s.name} is ${st}: starting it`);
      await ctx.start(s.machine!);
    }
    const back = await waitIdentify(s.socket, BACK_DEADLINE_MS);
    if (!back) throw new Error(`${s.name} (${s.machine}) does not answer identify ${BACK_DEADLINE_MS / 1000} s after it was brought back`);
    // A power-off ends the stub's process; a stub that does not answer is started again.
    await ctx.ensureStub(s.machine!);
  }
}

export async function moveRun(ctx: MoveContext, a: RunArgs): Promise<MoveResult> {
  const rng = moveRng(a.seed);
  const tag = a.run.replace(/[^A-Za-z0-9-]/g, "-");
  const dir = path.join(a.root, `r${tag.slice(-6)}`);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const trace: string[] = [];
  const note = (s: string) => trace.push(s);
  const srcFolder = `${a.src.home}/work/kmm-${tag}`;
  const dstFolder = `${a.dst.home}/work/kmm-${tag}`;
  const remote = `${a.src.home}/work/kmm-${tag}-remote.git`;
  const queued = moveQueuedMarker(tag);
  const queuedId = `kmm-queued-${tag}`;

  // 1. The folder and its git state.
  const fx = await a.src.exec(gitFixtureCommand(srcFolder, remote, tag), 60_000);
  if (!/@@base [0-9a-f]{40}/.test(fx.stdout)) throw new Error(`git fixture on ${a.src.name}: ${(fx.stdout + fx.stderr).slice(-300)}`);
  const files = await a.src.exec(countFilesCommand(`${srcFolder}/chaos-count/${tag}`, tag), 60_000);
  const countDir = /@@dir (\S+)/.exec(files.stdout)?.[1];
  if (!countDir) throw new Error(`counting files on ${a.src.name}: ${(files.stdout + files.stderr).slice(-200)}`);

  // 2. The folder's first sync, as the app makes it before a move (none for a relay: the move carries it all).
  const pumpEnv = a.local.env;
  const cm = (args: string[], ms = 180_000) => runPump(ctx.cmux, args, pumpEnv).then((p) => (p.ok ? p : Promise.reject(new Error(`${args.slice(0, 3).join(" ")}: ${pumpText(p)}`))));
  if (a.noSync) {
    await a.dst.exec(`mkdir -p ${shq(dstFolder)}`);
  } else if (a.direction === "local-cloud") {
    await cm(["link", "seed", "push", "--socket", a.dst.socket, srcFolder, dstFolder]);
  } else if (a.direction === "cloud-local") {
    await cm(["link", "seed", "fetch", "--socket", a.src.socket, dstFolder, srcFolder, "--find-root", "--adopt"]).catch(async (e: Error) => {
      note(`seed fetch: ${e.message}; seed pull --or-copy instead`);
      await cm(["link", "seed", "pull", "--socket", a.src.socket, dstFolder, srcFolder, "--or-copy"]);
    });
  }
  const dirty = await a.src.exec(gitDirtyCommand(srcFolder, tag), 30_000);
  const sha = /@@commit ([0-9a-f]{40})/.exec(dirty.stdout)?.[1];
  if (!sha) throw new Error(`git dirty on ${a.src.name}: ${(dirty.stdout + dirty.stderr).slice(-200)}`);

  // 3. The chat: a tab, a start in the folder, the counting turn, the queued prompt, the draft.
  const rpc = async (side: MoveSide, frame: Record<string, unknown> | Array<Record<string, unknown>>, ms = 60_000) => {
    const r = await daemonRpc(side.socket, frame, ms);
    if (!r?.ok) throw new Error(`${[frame].flat().map((f) => String(f.cmd)).join("+")} on ${side.name}: ${r?.error_code ?? ""} ${String(r?.error ?? "").slice(0, 200)}`);
    return r.data;
  };
  const tab = async (side: MoveSide, folder: string): Promise<number> => {
    const id = await rpc(side, { cmd: "identify" });
    const ws = await rpc(side, { cmd: "create-workspace", name: `kmm ${tag}` });
    const t = await rpc(side, { cmd: "new-conversation-tab", workspace: ws.workspace, agent_session: { host: `registry:${id.registry_id ?? id.session_id}`, harness: "claude" } });
    // The person trusts the chat's folder (a fresh Cloud folder reads trusted already; a refusal there is noted only).
    await rpc(side, { cmd: "agent-session-trust", surface: t.surface, cwd: folder, level: "trusted", vm_kind: "owner" }).catch((e: Error) => note(`trust ${side.name}: ${e.message}`));
    return t.surface;
  };
  const surface = await tab(a.src, srcFolder);
  const started = await rpc(a.src, { cmd: "agent-session-start", surface, harness: "claude", cwd: srcFolder, vm_kind: "owner", ...(a.src.kind === "cloud" && ctx.credentials ? { credentials: ctx.credentials } : {}) }, 120_000);
  const session = String(started.session ?? "");
  if (!session) throw new Error(`agent-session-start gave no session: ${JSON.stringify(started).slice(0, 200)}`);
  // A local target folder the person trusted (Transfer to This Mac lands a chat in a folder of this Mac).
  if (a.dst.kind === "local") await tab(a.dst, dstFolder).catch((e: Error) => note(`target trust: ${e.message}`));
  await rpc(a.src, [{ cmd: "agent-session-attach", surface, limit: 1 }, { cmd: "agent-session-prompt", surface, prompt_id: `kmm-count-${tag}`, text: `${moveCountMarker(tag)} ${a.step} ${a.kill}: read the counting files in ${countDir}/ in order.` }]);
  const turnRunning = async (min: number) => {
    for (const until = Date.now() + 120_000; Date.now() < until; await sleep(1_500)) {
      const s = await acpmuxOn(a.src, "summary", session).catch(() => null);
      if (s?.turn && (min === 0 || Number(s.queued ?? 0) >= min)) return s;
    }
    throw new Error(`the counting turn is not running (queued ≥ ${min}) on ${a.src.name} after 120 s`);
  };
  await turnRunning(0);
  await rpc(a.src, [{ cmd: "agent-session-attach", surface, limit: 1 }, { cmd: "agent-session-prompt", surface, prompt_id: queuedId, text: `${queued} the prompt the person queued.` }]);
  await turnRunning(1);
  await acpmuxOn(a.src, "draft_set", session, moveDraft(tag));
  const before = await acpmuxOn(a.src, "events", session) as Array<{ seq: number; kind: string; promptId: string | null; text: string }>;
  note(`source ${a.src.name} chat ${session} surface ${surface}: ${before.length} records before the move, queued 1, draft set`);

  // 4. The proxies and the fault.
  const pauseS = 5 + Math.floor(rng() * 56);
  const cutS = 5 + Math.floor(rng() * 56);
  let pump: ChildProcess | null = null;
  let resumeAt = 0;
  let resumeDone: Promise<void> = Promise.resolve();
  const sideOf = (which: "src" | "dst") => (which === "src" ? a.src : a.dst);
  const fault = async (wire: MoveTripwire): Promise<void> => {
    const which: "src" | "dst" = a.kill.endsWith("-dst") ? "dst" : a.kill === "cut" ? stepSide(a.step, a.direction) : "src";
    const s = sideOf(which);
    if (a.kill.startsWith("kill-")) {
      if (s.local) wire.note(`SIGKILL local daemon+acpmux ${s.local.signal(s.local.daemonPids(), "SIGKILL").join(",")}`);
      else {
        const r = await s.exec(`${s.guest}${sessionHostKillCommand()}; p=$("$c" acp --json daemon status 2>/dev/null | sed -n 's/.*"pid": *\\([0-9]*\\).*/\\1/p' | head -1); [ -n "$p" ] && sudo -n kill -KILL "$p" && echo "@@acpmux $p"`, 30_000).catch((e: Error) => ({ stdout: e.message, stderr: "", code: 1 }));
        wire.note(`kill on ${s.name}: ${r.stdout.trim().replace(/\n/g, " ")}`);
      }
    } else if (a.kill.startsWith("off-")) {
      if (s.local) {
        const pids = s.local.pids();
        // Every process of the local machine: its daemon, acpmux, agents, the carriers and the pump.
        s.local.signal(pids, "SIGKILL");
        for (const c of a.carriers) c.stop();
        if (pump?.pid) try { process.kill(pump.pid, "SIGKILL"); } catch { /* gone */ }
        wire.note(`local power off: SIGKILL ${pids.length} processes, the carriers and the pump`);
      } else {
        const r = await s.exec(`sudo -n sh -c 'echo 1 > /proc/sys/kernel/sysrq; echo o > /proc/sysrq-trigger' & sleep 3; echo @@still-up`, 15_000).catch((e: Error) => ({ stdout: `exec ended: ${e.message.slice(0, 100)}`, stderr: "", code: 1 }));
        wire.note(`power off ${s.name}: ${r.stdout.trim().slice(0, 120)}`);
      }
    } else if (a.kill === "cut") {
      if (s.local) {
        wire.blackhole(["from", "to", "sync", "sync-from"], cutS * 1000);
        wire.note(`cut: the local daemon's sockets held ${cutS} s (no network between the pump and a local daemon)`);
      } else {
        const r = await s.exec(dropCommand(cutS), 30_000).catch((e: Error) => ({ stdout: e.message, stderr: "", code: 1 }));
        wire.note(`cut ${s.name} 443 for ${cutS} s: ${r.stdout.trim()}`);
      }
    } else if (a.kill.startsWith("pause-")) {
      if (s.local) {
        const pids = s.local.pids();
        s.local.signal(pids, "SIGSTOP");
        wire.note(`local sleep: SIGSTOP ${pids.length} processes for ${pauseS} s`);
        resumeAt = Date.now() + pauseS * 1000;
        resumeDone = sleep(pauseS * 1000).then(() => { s.local!.signal(pids, "SIGCONT"); wire.note("local wake: SIGCONT"); });
      } else {
        await ctx.pause(s.machine!);
        wire.note(`paused ${s.name}; resuming in ${pauseS} s`);
        resumeAt = Date.now() + pauseS * 1000;
        resumeDone = sleep(pauseS * 1000).then(() => ctx.start(s.machine!)).then(() => wire.note(`resumed ${s.name}`), (e: Error) => wire.note(`resume ${s.name} failed: ${e.message}`));
      }
    }
  };
  let wire!: MoveTripwire;
  wire = new MoveTripwire(moveTrigger(a.step), () => fault(wire));
  const proxies: MoveProxy[] = [];
  const proxy = async (role: string, upstream: string) => {
    const p = new MoveProxy(role, path.join(dir, `${role}.sock`), upstream, wire);
    await p.start();
    proxies.push(p);
    return p.listen;
  };
  const from = await proxy("from", a.src.socket);
  const to = await proxy("to", a.dst.socket);
  const args = ["link", "agent", "move", "--from-socket", from, "--surface", String(surface), "--to-socket", to, "--cwd", dstFolder, "--interrupt", "--state-dir", path.join(dir, "pump")];
  if (a.noSync) {
    // no --sync
  } else if (a.direction === "local-cloud") {
    args.push("--sync", "seed", "--sync-socket", await proxy("sync", a.dst.socket), "--sync-local", srcFolder, "--sync-remote", dstFolder, "--vm-kind", "owner");
  } else if (a.direction === "cloud-local") {
    args.push("--sync", "pull", "--sync-socket", await proxy("sync", a.src.socket), "--sync-local", dstFolder, "--sync-remote", srcFolder);
  } else {
    args.push("--sync", "relay", "--sync-from-socket", await proxy("sync-from", a.src.socket), "--sync-socket", await proxy("sync", a.dst.socket), "--sync-local", srcFolder, "--sync-remote", dstFolder, "--vm-kind", "owner");
  }
  const first = await runPump(ctx.cmux, args, pumpEnv, (p) => (pump = p));
  // The proxies stay up for the Retry: the pump's move record is keyed by --from-socket and names
  // --to-socket, so the app's Retry runs on the same paths, as here. The wire fires once.
  const stopProxies = () => { for (const p of proxies) p.stop(); };
  trace.push(...wire.trace);
  note(`pump: ${pumpText(first)}`);
  const faultS = a.kill === "cut" ? cutS : a.kill.startsWith("pause") ? pauseS : null;
  if (!wire.fired) {
    stopProxies();
    return {
      run: a.run, seed: a.seed, direction: a.direction, step: a.step, button_step: buttonStep(a.step), kill: a.kill, outcome: "unmeasured", lost: [], open: "", queued_runs: -1, draft: "", edit: "", commit: "",
      pump_first: pumpText(first), pump_retry: "not run", seen_ms: null, fault_s: faultS, detail: `the pump never reached ${a.step} (${wire.refused ? `the step's answer was a refusal: ${pumpText(first)}` : a.step === "mid-copy" ? `${wire.writes} writes` : "no such request"})`, trace,
    };
  }

  // 5. The survivors back, then the app's Retry if the move did not finish.
  if (resumeAt) await resumeDone;
  if (a.kill === "cut") await sleep(Math.max(0, wire.firedAt + cutS * 1000 + 2_000 - Date.now()));
  await bringBack(ctx, a.carriers, [a.src, a.dst], note);
  let retry: PumpAnswer | null = null;
  if (!first.ok) {
    retry = await runPump(ctx.cmux, args, pumpEnv);
    note(`retry: ${pumpText(retry)}`);
  }
  stopProxies();
  const last = retry ?? first;
  const seenMs = Date.now() - wire.firedAt - (retry ? 0 : 0);

  // 6. What the person has now.
  const lost: string[] = [];
  const findSummary = async (side: MoveSide) => acpmuxOn(side, "summary", session).catch((e: Error) => ({ error: e.message }));
  // The queued prompt runs once the chat is idle where it is open: give it the turn's time to.
  let srcSum: any = null;
  let dstSum: any = null;
  let srcEv: any[] = [];
  let dstEv: any[] = [];
  // A read that fails is not an empty journal: keep its error so the verdict says which it was.
  const evErr: Record<string, string> = {};
  const eventsOn = (side: MoveSide) =>
    acpmuxOn(side, "events", session).then(
      (evs: any) => { delete evErr[side.name]; return Array.isArray(evs) ? evs : (evErr[side.name] = `not a list: ${JSON.stringify(evs).slice(0, 120)}`, []); },
      (e: Error) => { evErr[side.name] = e.message.slice(0, 200); return []; },
    );
  const runsOf = (evs: any[]) => new Set(evs.filter((e) => e.kind === "turn_result" && e.promptId === queuedId).map((e) => `${e.seq}|${e.text}`)).size;
  for (const until = Date.now() + 240_000; ; await sleep(5_000)) {
    [srcSum, dstSum] = await Promise.all([findSummary(a.src), findSummary(a.dst)]);
    [srcEv, dstEv] = await Promise.all([eventsOn(a.src), eventsOn(a.dst)]);
    const openSum = [srcSum, dstSum].find((s) => s && !s.error && s.status !== "closed");
    if (new Set([...srcEv, ...dstEv].filter((e) => e.kind === "turn_result" && e.promptId === queuedId).map((e) => `${e.seq}|${e.text}`)).size >= 1 && !openSum?.turn) break;
    if (Date.now() > until) break;
  }
  const isOpen = (s: any) => Boolean(s && !s.error && s.status !== "closed");
  const openAt = [isOpen(srcSum) ? `source ${a.src.name}` : "", isOpen(dstSum) ? `target ${a.dst.name}` : ""].filter(Boolean);
  const open = openAt.length ? openAt.join(" and ") : "nowhere";
  if (openAt.length !== 1) lost.push(openAt.length ? "chat open in two places" : "chat open nowhere");
  const survivor = isOpen(dstSum) ? a.dst : isOpen(srcSum) ? a.src : null;
  const survivorEv = survivor === a.dst ? dstEv : survivor === a.src ? srcEv : [];
  // Every record the source held when the move began is in the surviving journal, under the same seq and kind.
  const bySeq = new Map(survivorEv.map((e: any) => [e.seq, e]));
  const missing = survivor ? before.filter((e) => !bySeq.has(e.seq) || bySeq.get(e.seq).kind !== e.kind) : before;
  const unread = survivor ? evErr[survivor.name] : undefined;
  if (missing.length) lost.push(`${missing.length} of ${before.length} chat records (first seq ${missing[0].seq} ${missing[0].kind})${unread ? ` [events on ${survivor!.name} unreadable: ${unread}]` : survivor && !survivorEv.length ? ` [events on ${survivor.name} read empty]` : ""}`);
  // The queued prompt's runs on each side, and overall: a moved journal carries the source's records, so a run
  // the source made before the move shows on both sides with the same seq and content and counts once.
  const qRec = (evs: any[]) => evs.filter((e) => e.kind === "turn_result" && e.promptId === queuedId).map((e) => `${e.seq}|${e.text}`);
  const qSrc = qRec(srcEv).length;
  const qDst = qRec(dstEv).length;
  const qRuns = new Set([...qRec(srcEv), ...qRec(dstEv)]).size;
  if (qRuns !== 1) lost.push(qRuns === 0 ? "queued prompt never ran" : `queued prompt ran ${qRuns} times`);
  let draft = "no survivor";
  if (survivor) {
    const d = await acpmuxOn(survivor, "draft_get", session).catch((e: Error) => ({ error: e.message }));
    draft = d?.draft === moveDraft(tag) ? "present" : d?.error ? `unreadable: ${d.error}` : `missing (${JSON.stringify(d).slice(0, 80)})`;
    if (draft !== "present") lost.push("draft");
  } else lost.push("draft");
  const find = async (side: MoveSide, folder: string, rem: string) => {
    const r = await side.exec(gitFindCommand(folder, rem, tag, sha), 30_000).catch(() => ({ stdout: "", stderr: "", code: 1 }));
    return { edit: /@@edit yes/.test(r.stdout), commit: /@@commit yes/.test(r.stdout), remote: /@@remote yes/.test(r.stdout) };
  };
  const [landed, source] = await Promise.all([find(a.dst, dstFolder, ""), find(a.src, srcFolder, remote)]);
  const editAt = [landed.edit ? "landed" : "", source.edit ? "source folder" : ""].filter(Boolean);
  const commitAt = [landed.commit ? "landed" : "", source.commit ? "source folder" : "", source.remote ? "git remote" : ""].filter(Boolean);
  const edit = editAt.join("+") || "nowhere";
  const commit = commitAt.join("+") || "nowhere";
  if (!editAt.length) lost.push("uncommitted edit");
  if (!commitAt.length) lost.push("unpushed commit");
  // Recoverable but not where the chat is: the person must go back to the other side for it.
  const strand: string[] = [];
  if (survivor === a.dst && !landed.edit && editAt.length) strand.push(`edit only in the ${edit}`);
  if (survivor === a.dst && !landed.commit && commitAt.length) strand.push(`commit only in the ${commit}`);
  return {
    run: a.run, seed: a.seed, direction: a.direction, step: a.step, button_step: buttonStep(a.step), kill: a.kill,
    outcome: lost.length ? "fail" : "pass", lost, open, queued_runs: qRuns, queued_src: qSrc, queued_dst: qDst, draft, edit, commit,
    pump_first: pumpText(first), pump_retry: pumpText(retry), seen_ms: seenMs, fault_s: faultS,
    detail: `${last.ok ? "move finished" : `move did not finish: ${last.json?.error_code ?? "no answer"}`}${strand.length ? `; ${strand.join("; ")}` : ""}`,
    trace,
  };
}

/** The results as a markdown table: direction × step × kill → what was lost. */
export function moveTable(results: MoveResult[]): string {
  const rows = results.map((r) => `| ${r.direction} | ${r.step} (${r.button_step}) | ${r.kill} | ${r.outcome} | ${r.lost.join("; ") || "nothing"} | ${r.open} | ${r.queued_runs} (src ${r.queued_src ?? "?"}, dst ${r.queued_dst ?? "?"}) | ${r.draft} | ${r.edit} | ${r.commit} | ${r.pump_first}${r.pump_retry !== "not run" ? ` → retry ${r.pump_retry}` : ""} | ${r.seen_ms ?? ""} | ${r.run} | ${r.seed} |`);
  return ["| direction | step | kill | outcome | lost | open | queued ran | draft | edit | commit | pump (person sees) | seen ms | run | seed |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|", ...rows].join("\n");
}
