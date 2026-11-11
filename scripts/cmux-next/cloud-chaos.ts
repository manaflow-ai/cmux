/**
 * The Cloud journey's chaos leg (`cloud-journey.ts --chaos`): faults injected into a live machine's carrier mid-turn,
 * each timed from the moment its cause ends until the person sees the reply to what they sent, with what they saw.
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
 * Per fault it records: felt_ms, the time the person feels: at the cause's end a second chat (FeltChat: idle, on its
 * own dial, as the person's other chat tab) sends a prompt, and felt_ms runs from that send to the first record of the
 * agent's reply the client receives (feltAfterSend). A send the dial cannot take yet is tried again with the same
 * prompt_id until it is, as the app holds a send while it reconnects, so the clock starts at the person's send, not
 * at the connection's return. recover_ms is the network's part of it (from the cause's end to the first identify
 * answered after it). Also how the carrier came back (resumed in the same session, or a new dial), and the turn's
 * outcome from `acp history` (completed once, missing, or started twice: a lost or duplicated prompt). Faults it
 * cannot inject from the machine (the vault, an image roll during a spare claim) are recorded as not run with the
 * reason.
 *
 * And whether the person lost output. A second dial is the person's chat as the app holds it (ChatClient: a chat tab
 * on the machine's store, `agent-session-start`, `agent-session-prompt`, `agent-session-attach` and its live records,
 * attached again from the newest seq held after a redial or a close). Each fault's turn is a counting turn: the model
 * stub's turn script (countingTurnScript) makes COUNT_STEPS numbered shell calls, and the fault goes in once the client
 * has seen a third of them. A guest terminal prints 1..SEQ_LINES across the same span, tee'd to a file, and the client
 * reads it with `terminal.output_read` from offsets (SeqTerminal). After the turn, judgeLoss compares what the client
 * received with the machine's own journal (`acp tail --since`), and judgeTerminal compares its terminal reads with the
 * tee'd copy; either finding a loss fails the fault, with the verdict in its detail.
 */
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";

export type ChaosExec = (command: string, timeoutMs?: number) => Promise<{ code: number; stdout: string; stderr: string }>;

export type ChaosResult = {
  fault: string;
  outcome: "ok" | "fail" | "not run";
  /** From a send at the cause's end to the first record of the reply the client received: the person's felt time. */
  felt_ms: number | null;
  /** From the cause's end to the first identify the carrier answered: the connection's part of felt_ms. */
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
  /** The harness the client's chat runs (`agent-session-start`), as the journey's `--agent`. */
  harness?: string;
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
 * Reset every established 443 connection on the machine. `ss -K` lists each socket it closed (`-n`, so the port reads
 * `:443`, never `:https`), so `@@ok` needs both its exit status and at least one closed socket: a missing `sudo`, a
 * missing `ss`, or a kernel without SOCK_DESTROY (where `ss -K` closes nothing) prints `@@failed` instead of passing
 * as a cut that never happened.
 */
export function relayCutCommand(): string {
  return "out=$(sudo -n ss -K -H -n state established '( dport = :443 )' 2>&1); rc=$?; " +
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

/**
 * When a fault's cause is surely over: no earlier than the fault command's answer (a cut or a kill has happened by
 * then, and an identify sent before it may have been answered before the cause), and no earlier than the drop's own
 * length after the command went out. Recovery is timed from here, so an answer to a request sent before the cause
 * never counts as recovery.
 */
export function causeEndedAt(sentAt: number, answeredAt: number, secs: number): number {
  return Math.max(answeredAt, sentAt + secs * 1000);
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

/** A frame's answer: a legacy `{id, ok, data}` line or a `cmux.protocol/2` `{id, ok, result}` response. */
function answerOf(msg: any): any {
  if (msg?.ok !== true) throw new Error(`${msg?.error_code ?? msg?.error?.code ?? "refused"}: ${String(msg?.error?.message ?? msg?.error ?? "").slice(0, 200)}`);
  return msg.data ?? msg.result ?? {};
}

/** What the chat and the guest terminal need of a carrier dial (ClientDial; a fake in the tests). */
export type DialLike = {
  dials: number;
  start(): void;
  request(frame: Record<string, unknown>, timeoutMs?: number): Promise<any>;
  stop(): void;
};

/**
 * One more `cmux carrier dial`, the client's: requests matched to their answers by id, every other line handed to
 * `onLine`. A dial that ends rejects what it still owed and is dialed again, and `onDial` runs once each new dial
 * says it connected, so the client can attach again as the app does after its redial.
 */
class ClientDial implements DialLike {
  dials = 0;
  private child: ReturnType<typeof spawn> | null = null;
  private pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  private n = 0;
  private stopped = false;

  constructor(private ctx: ChaosContext, private onLine: (msg: any) => void, private onDial: () => void) {}

  start(): void {
    this.dial();
  }

  private dial(): void {
    if (this.stopped) return;
    this.dials += 1;
    const args = ["carrier", "dial", "--machine", this.ctx.machine, ...(this.ctx.team ? ["--team", this.ctx.team] : [])];
    const child = spawn(this.ctx.cmux, args, { env: this.ctx.env, stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    child.stdin!.on("error", () => undefined);
    let out = "";
    child.stdout!.setEncoding("utf8").on("data", (chunk: string) => {
      out += chunk;
      for (let at = out.indexOf("\n"); at >= 0; at = out.indexOf("\n")) {
        const line = out.slice(0, at);
        out = out.slice(at + 1);
        let msg: any;
        try { msg = JSON.parse(line); } catch { continue; }
        const waiting = typeof msg?.id === "string" ? this.pending.get(msg.id) : undefined;
        if (waiting) {
          this.pending.delete(msg.id);
          clearTimeout(waiting.timer);
          waiting.resolve(msg);
        } else this.onLine(msg);
      }
    });
    let err = "";
    let said = false;
    child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
      err += chunk;
      if (said) return;
      const first = err.split("\n")[0];
      if (!err.includes("\n")) return;
      said = true;
      try { if (JSON.parse(first).ok === true && this.child === child) this.onDial(); } catch { /* not the reply line */ }
    });
    child.on("exit", () => {
      if (this.child === child) this.child = null;
      for (const [id, w] of this.pending) {
        clearTimeout(w.timer);
        w.reject(new Error("the client's dial ended"));
        this.pending.delete(id);
      }
      if (this.stopped) return;
      // At once, as the app's redial; a dial that cannot connect yet ends again and comes back here.
      setTimeout(() => this.dial(), 250);
    });
  }

  /** One request on the current dial; rejects when it is not answered within `timeoutMs` or the dial ends. */
  request(frame: Record<string, unknown>, timeoutMs = 30_000): Promise<any> {
    const child = this.child;
    if (!child?.stdin?.writable) return Promise.reject(new Error("the client has no dial"));
    const id = `chaos-${++this.n}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`no answer within ${timeoutMs / 1000} s`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      child.stdin!.write(`${JSON.stringify({ ...frame, id })}\n`);
    });
  }

  stop(): void {
    this.stopped = true;
    this.child?.stdin?.end();
    this.child?.kill("SIGTERM");
  }
}

/**
 * The chat tab's current numeric surface, from the machine's tree (`list-workspaces`, as hostd's Cloud ACP adapter
 * resolves its chats): the tab whose stable `tab_resource_id` is `tab`, else (a daemon that gave no tab id, or a tab
 * that lost it) the lowest surface whose agent tab is bound to `session`. A session host restart restores the mux
 * with new surface ids, so a surface held from before it names nothing, or another tab. Null when no tab matches.
 */
export async function resolveChatSurface(request: (frame: Record<string, unknown>) => Promise<any>, tab: string, session: string): Promise<number | null> {
  const tree = answerOf(await request({ cmd: "list-workspaces" }));
  let bySession: number | null = null;
  for (const workspace of Array.isArray(tree?.workspaces) ? tree.workspaces : []) {
    for (const screen of Array.isArray(workspace?.screens) ? workspace.screens : []) {
      for (const pane of Array.isArray(screen?.panes) ? screen.panes : []) {
        for (const t of Array.isArray(pane?.tabs) ? pane.tabs : []) {
          if (typeof t?.surface !== "number") continue;
          if (tab && t.tab_resource_id === tab) return t.surface;
          const bound = t.conversation?.agent_session?.session;
          if (session && bound === session && (bySession === null || t.surface < bySession)) bySession = t.surface;
        }
      }
    }
  }
  return bySession;
}

/** One record as the client received it, and how: on the live push or in a page it read after (re)attaching. */
type Received = { seq: number; record: any; via: "live" | "page"; at: number };

/**
 * The person's chat as the app holds it, over its own carrier dial: a new chat tab on the machine's own store
 * (`new-conversation-tab` with `registry:<id>`), the chat started there (`agent-session-start`), prompts sent with
 * `agent-session-prompt`, and the chat read with `agent-session-attach` and its live `agent-session-record` pushes.
 * After a new dial, or an `agent-session-closed`, it attaches again from the newest seq it holds (`after_seq`) and
 * pages forward until it has caught up, as the attach contract says (cmux-tui-core `agent_session_attach.rs`).
 *
 * It holds the chat by its stable tab id (`tab_resource_id`) and session, never by a numeric surface across a redial:
 * a session host restart restores the mux with new surface ids, so before every (re)attach and every prompt it looks
 * the tab's current surface up again (resolveChatSurface).
 *
 * Every delivery is kept in arrival order, so the judge sees a replay that started early (a seq again) or late (a
 * gap). A live push of a seq it already holds is dropped and counted, as the app drops it (`acp tail -f` does too);
 * live pushes that arrive while it pages are held until the page is in.
 */
export class ChatClient {
  received: Received[] = [];
  /** Indexes into `received` where a re-attach's page began. */
  reconnects: number[] = [];
  held = 0;
  overlaps = 0;
  surface: number | null = null;
  /** The chat tab's stable id (`new-conversation-tab`'s `tab_resource_id`); "" from a daemon that gives none. */
  tab = "";
  /** How many times the tab came back on another surface (a session host restart). */
  surfaceMoves = 0;
  session = "";
  attaches = 0;
  lastError = "";
  private attached = false;
  private paging = false;
  private stash: Array<{ record: any; at: number }> = [];

  /** Every record the client has received from index `from` on, with the live pushes still held while a page loads. */
  arrivals(from: number): Array<{ seq: number; record: any; at: number }> {
    return [...this.received.slice(from), ...this.stash.map((r) => ({ seq: Number(r.record?.seq), record: r.record, at: r.at }))];
  }
  private stopped = false;
  private reattaching = false;
  readonly dial: DialLike;
  private ready: Promise<void>;
  private readyNow!: () => void;

  constructor(private ctx: ChaosContext, makeDial: (onLine: (m: any) => void, onDial: () => void) => DialLike = (onLine, onDial) => new ClientDial(ctx, onLine, onDial)) {
    this.ready = new Promise((r) => (this.readyNow = r));
    this.dial = makeDial((m) => this.onLine(m), () => this.onDial());
  }

  /** Dial, make the chat tab and start the chat in it; the first attach sets the baseline seq. */
  async open(harness: string): Promise<void> {
    this.dial.start();
    await Promise.race([this.ready, sleep(90_000).then(() => { throw new Error("the client's dial never connected"); })]);
    const id = answerOf(await this.dial.request({ cmd: "identify" }));
    const registry = String(id.registry_id ?? "");
    if (!registry) throw new Error(`identify names no registry_id: ${JSON.stringify(id).slice(0, 200)}`);
    const ws = answerOf(await this.dial.request({ cmd: "create-workspace", name: `chaos ${this.ctx.tag}` }));
    const tab = answerOf(await this.dial.request({ cmd: "new-conversation-tab", workspace: ws.workspace, agent_session: { host: `registry:${registry}`, harness } }));
    if (typeof tab.surface !== "number") throw new Error(`new-conversation-tab gave no surface: ${JSON.stringify(tab).slice(0, 200)}`);
    this.surface = tab.surface;
    this.tab = typeof tab.tab_resource_id === "string" ? tab.tab_resource_id : "";
    const started = answerOf(await this.dial.request({ cmd: "agent-session-start", surface: tab.surface, harness, vm_kind: "owner" }, 120_000));
    this.session = String(started.session ?? "");
    if (!this.session) throw new Error(`agent-session-start gave no session: ${JSON.stringify(started).slice(0, 200)}`);
    await this.attach(undefined);
  }

  /**
   * The prompt, as the app sends it; a send tried again keeps its `promptId`, so acpmux takes it once. Each request
   * waits at most until `until` (an absolute time), from the budget left when it goes out.
   */
  async prompt(text: string, promptId = `chaos-${Date.now().toString(36)}`, until = Date.now() + 90_000): Promise<void> {
    const left = (cap: number) => Math.max(1, Math.min(cap, until - Date.now()));
    await this.resolveSurface(left(30_000));
    answerOf(await this.dial.request({ cmd: "agent-session-prompt", surface: this.surface, prompt_id: promptId, text }, left(60_000)));
  }

  /** The highest counting step the client has seen for `tag`. */
  reached(tag: string, from: number): number {
    let k = 0;
    for (const r of this.received.slice(from)) for (const s of journalEvent(tag, r.record)?.ks ?? []) k = Math.max(k, s);
    return k;
  }

  /** Waits until the client holds `seq` (true) or `ms` pass (false). */
  async caughtUp(seq: number, ms: number): Promise<boolean> {
    for (const until = Date.now() + ms; Date.now() < until; await sleep(250)) if (this.held >= seq && this.attached) return true;
    return this.held >= seq;
  }

  private onLine(m: any): void {
    if (m?.surface !== this.surface) return;
    if (m.event === "agent-session-record" && m.record && typeof m.record.seq === "number") {
      if (!this.attached) return;
      if (this.paging) this.stash.push({ record: m.record, at: Date.now() });
      else this.live(m.record);
    } else if (m.event === "agent-session-closed") {
      this.attached = false;
      this.lastError = `closed: ${String(m.reason ?? "")}`;
      this.ctx.log?.(`chaos: the chat attachment closed (${String(m.reason ?? "")}); attaching again`);
      void this.reattach();
    }
  }

  private live(record: any, at = Date.now()): void {
    if (record.seq <= this.held) {
      this.overlaps += 1;
      return;
    }
    this.received.push({ seq: record.seq, record, via: "live", at });
    this.held = record.seq;
  }

  private onDial(): void {
    this.readyNow();
    if (this.surface === null) return;
    this.attached = false;
    void this.reattach();
  }

  /** Looks the chat tab's current surface up again (it changes when the session host restarts). */
  private async resolveSurface(timeoutMs = 30_000): Promise<void> {
    const now = await resolveChatSurface((f) => this.dial.request(f, timeoutMs), this.tab, this.session);
    if (now === null) throw new Error(`the chat's tab (${this.tab || `session ${this.session}`}) is not in the machine's tree`);
    if (now === this.surface) return;
    this.ctx.log?.(`chaos: the chat's tab is now surface ${now} (was ${this.surface})`);
    this.surfaceMoves += 1;
    this.surface = now;
  }

  /** Attach again from the newest seq held, until it works or the client stops. */
  private async reattach(): Promise<void> {
    if (this.reattaching) return;
    this.reattaching = true;
    try {
      while (!this.stopped && !this.attached) {
        try {
          await this.resolveSurface();
          await this.attach(this.held);
        } catch (e) {
          this.lastError = (e as Error).message;
          await sleep(1_000);
        }
      }
    } finally {
      this.reattaching = false;
    }
  }

  /** `agent-session-attach` from `after` (the newest page when undefined), then pages forward while it has more. */
  private async attach(after: number | undefined): Promise<void> {
    this.paging = true;
    this.stash = [];
    const from = this.received.length;
    try {
      const page = answerOf(await this.dial.request({ cmd: "agent-session-attach", surface: this.surface, ...(after === undefined ? {} : { after_seq: after }), limit: 500 }));
      this.attaches += 1;
      this.attached = true;
      if (after === undefined) {
        // The baseline: what the chat held before any counting turn; none of it is judged.
        this.held = Math.max(Number(page.lastSeq ?? 0), ...(page.events ?? []).map((e: any) => Number(e.seq ?? 0)));
        return;
      }
      this.reconnects.push(this.received.length);
      let more = this.take(page);
      for (let i = 0; more && i < 200; i++) {
        more = this.take(answerOf(await this.dial.request({ cmd: "agent-session-events", surface: this.surface, after_seq: this.held, limit: 500 })));
      }
    } finally {
      this.flushStash(from);
    }
  }

  /**
   * The live pushes held while a page loaded, in order. A push the page also carried (from index `pageFrom` of
   * `received`) is dropped as an overlap, and the page's copy keeps the push's earlier arrival time.
   */
  private flushStash(pageFrom: number): void {
    this.paging = false;
    const held = this.stash;
    this.stash = [];
    for (const r of held) {
      const copy = r.record.seq <= this.held ? this.received.slice(pageFrom).find((x) => x.seq === r.record.seq) : undefined;
      if (copy) copy.at = Math.min(copy.at, r.at);
      this.live(r.record, r.at);
    }
  }

  private take(page: any): boolean {
    const events: any[] = Array.isArray(page?.events) ? page.events : [];
    for (const e of events) {
      if (typeof e?.seq !== "number") continue;
      // Kept even when already held: a page that repeats a seq is a replay that started too early.
      this.received.push({ seq: e.seq, record: e, via: "page", at: Date.now() });
      this.held = Math.max(this.held, e.seq);
    }
    return page?.hasMore === true && events.length > 0;
  }

  stop(): void {
    this.stopped = true;
    this.dial.stop();
  }
}

/** `terminal.output_read` params for one terminal of the machine's own session. */
const here = { machine: "current", session: "current" };

/**
 * A terminal on the machine that prints `seq 1 n` slowly and tees it to a file there, read by the client over its
 * carrier dial with `terminal.output_read` from the last read's `next_offset`, across the fault, as a client that
 * polls a terminal's output does. A read that is not answered (the carrier is down) is asked again from the same
 * offset on the dial that comes back.
 */
export class SeqTerminal {
  reads: TerminalRead[] = [];
  terminal = "";
  error = "";
  private offset = 0;
  private stopped = false;
  private loop: Promise<void> | null = null;

  constructor(private dial: DialLike, readonly n: number, readonly file: string) {}

  /**
   * The machine command: one number per line, paced, tee'd to `file`, and then the terminal stays up until the leg
   * has read it all and writes `file.done` (releaseCommand), at most SEQ_HOLD_S. Its lines take about 30 s, less than
   * a turn with a 60 s drop in it; a terminal that ended would answer a read under its snapshot's coverage with the
   * whole snapshot from offset 0 (which assembleTerminal takes, but the live path is the one the leg means to judge).
   */
  static script(n: number, file: string): string {
    return `i=0; while [ "$i" -lt ${n} ]; do i=$((i+1)); echo "$i"; sleep 0.1; done | tee ${shq(file)}; ` +
      `h=0; while [ ! -e ${shq(`${file}.done`)} ] && [ "$h" -lt ${SEQ_HOLD_S} ]; do h=$((h+1)); sleep 1; done`;
  }

  /** Ends the terminal's hold (script). */
  static releaseCommand(file: string): string {
    return `touch ${shq(`${file}.done`)}`;
  }

  async start(tag: string): Promise<void> {
    const ws = answerOf(await this.dial.request({ protocol: "cmux.protocol/2", type: "request", operation: "workspace.create", params: { ...here, name: `chaos seq ${tag}`, initial_content: "empty" }, idempotency_key: `chaos-ws-${tag}` }));
    const workspace = ws?.value?.workspace_id;
    if (typeof workspace !== "string") throw new Error(`workspace.create gave no workspace_id: ${JSON.stringify(ws).slice(0, 200)}`);
    const run = answerOf(await this.dial.request({ protocol: "cmux.protocol/2", type: "request", operation: "workspace.run", params: { ...here, workspace, argv: ["/bin/sh", "-c", SeqTerminal.script(this.n, this.file)] }, idempotency_key: `chaos-run-${tag}` }));
    this.terminal = String(run?.value?.terminal_id ?? "");
    if (!this.terminal) throw new Error(`workspace.run gave no terminal_id: ${JSON.stringify(run).slice(0, 200)}`);
    this.loop = this.poll();
  }

  private async poll(): Promise<void> {
    while (!this.stopped) {
      try {
        const r = answerOf(await this.dial.request({ protocol: "cmux.protocol/2", type: "request", operation: "terminal.output_read", params: { ...here, terminal: this.terminal, after: String(this.offset), max_bytes: 1_048_576 } }, 10_000));
        const read: TerminalRead = { after: this.offset, start: Number(r.start_offset), next: Number(r.next_offset), complete: r.complete === true, text: String(r.text ?? "") };
        this.reads.push(read);
        this.offset = read.next;
      } catch (e) {
        this.error = (e as Error).message;
      }
      await sleep(500);
    }
  }

  /** Every line read once the machine's copy is whole (`count` lines), or after `ms`. */
  async finish(count: () => number, ms: number): Promise<void> {
    for (const until = Date.now() + ms; Date.now() < until && count() < this.n; await sleep(500)) { /* reading */ }
    // One more read after the last line, so nothing written just before is left out.
    await sleep(1_500);
    this.stopped = true;
    await this.loop;
  }

  lines(): number {
    return assembleTerminal(this.reads).text.split("\n").filter((l) => /^\d+\s*$/.test(l.replace(/\r/g, ""))).length;
  }
}

/** The record kinds that are the agent's reply as the chat draws it; the echo of the person's own prompt is not. */
const REPLY_KINDS = new Set(["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan"]);

/** Whether a chat record (a journal line or a live `session/update`) is part of the agent's reply. */
export function isReply(record: any): boolean {
  const update = record?.msg?.params?.update ?? record?.params?.update ?? record?.update;
  return REPLY_KINDS.has(String(record?.kind ?? update?.sessionUpdate ?? ""));
}

/** The felt chat's prompt marker: a prompt the stub answers with its short reply, never the counting turn. */
export const feltMarker = (tag: string) => `[chaos-felt ${tag}]`;

export type Felt = { felt_ms: number | null; ack_ms: number | null; tries: number; error: string };

/**
 * The person's felt time: `text` sent on `chat` now, and the time until the client receives the first record of the
 * agent's reply (isReply) after it. A send the dial refuses or never answers (the carrier is still down) is tried
 * again with the same prompt_id, as the app holds a send while it reconnects; the clock keeps running from the first
 * try. `ack_ms` is when the machine took the prompt. Null felt_ms when no reply came within `deadlineMs`.
 *
 * Only a record past `afterSeq` (the journal's last seq of the chat's previous turn) and past what the chat held at
 * the send is this send's reply: a late or replayed record of an earlier turn never stops the clock. A try never
 * waits past the deadline, and a reply received after it does not count.
 */
export async function feltAfterSend(chat: ChatClient, text: string, deadlineMs: number, afterSeq = 0): Promise<Felt> {
  const sentAt = Date.now();
  const from = chat.received.length;
  const held = Math.max(chat.held, afterSeq);
  const promptId = `chaos-felt-${sentAt.toString(36)}`;
  let ack: number | null = null;
  let tries = 0;
  let error = "";
  for (const until = sentAt + deadlineMs; ;) {
    // The earliest arrival of any reply record, a live push still held behind a loading page included.
    const times = chat.arrivals(from).filter((r) => r.seq > held && r.at >= sentAt && r.at <= until && isReply(r.record)).map((r) => r.at);
    if (times.length) return { felt_ms: Math.min(...times) - sentAt, ack_ms: ack, tries, error };
    if (Date.now() > until) return { felt_ms: null, ack_ms: ack, tries, error };
    if (ack === null) {
      tries += 1;
      try {
        await chat.prompt(text, promptId, until);
        ack = Date.now() - sentAt;
      } catch (e) {
        error = (e as Error).message;
        await sleep(500);
      }
      continue;
    }
    await sleep(50);
  }
}

/** How many turns of the session started with this marker, and whether the last one ended. */
async function turnState(ctx: ChaosContext, marker: string, session = ctx.session): Promise<{ started: number; running: boolean; status: string; detail: string }> {
  const r = await ctx.exec(`${ctx.guest}"$c" acp --json history ${shq(session)} --limit 20 2>&1`, 45_000);
  let turns: any[] = [];
  try { turns = JSON.parse(r.stdout.slice(r.stdout.indexOf("{"))).turns ?? []; } catch { /* unreadable: counted as 0 */ }
  const mine = turns.filter((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker));
  // `acp history` rows carry `status`: "running" while the turn is open (acpmux cli/orchestrate.rs).
  const running = mine.some((t: any) => t.status === "running");
  return {
    started: mine.length,
    running,
    status: mine.map((t: any) => String(t.status)).join(","),
    // `detail` names why a failed turn ended (`outcome_unknown` for a restart cut); a daemon older than it carries the
    // reason only in `error`'s text.
    detail: mine.map((t: any) => String(t.detail ?? (typeof t.error === "string" ? t.error : t.error?.message ?? ""))).join(","),
  };
}

async function turnOutcome(ctx: ChaosContext, marker: string, session = ctx.session): Promise<{ ok: boolean; text: string; interrupted?: boolean }> {
  const until = Date.now() + TURN_DEADLINE_MS;
  let last = { started: 0, running: false, status: "", detail: "" };
  while (Date.now() < until) {
    try {
      last = await turnState(ctx, marker, session);
    } catch { /* the exec route itself recovering: try again */ }
    if (last.started > 1) return { ok: false, text: `started ${last.started} times (a duplicated prompt)` };
    // The turn's own terminal row decides (`acp wait` exits non-zero for a turn a restart cut short).
    if (last.started === 1 && !last.running) {
      if (last.status === "completed") return { ok: true, text: "completed once" };
      // A turn a restart cut short ends as acpmux's interrupted outcome (status failed, detail outcome_unknown), which
      // the person sees as such: it ran once and ended, nothing was lost or doubled.
      if (/outcome_unknown|interrupted/.test(`${last.status} ${last.detail}`)) {
        return { ok: true, text: `ended once, interrupted (${last.status}: ${last.detail})`, interrupted: true };
      }
      return { ok: false, text: `ended once as ${last.status}${last.detail ? ` (${last.detail})` : ""}` };
    }
    await sleep(2_000);
  }
  return last.started === 0
    ? { ok: false, text: `never started within ${TURN_DEADLINE_MS / 1000} s (a lost prompt)` }
    : { ok: false, text: `started, not finished within ${TURN_DEADLINE_MS / 1000} s` };
}

/**
 * The machine's own journal of the chat after `baseline`, read on the machine (`acp tail --since`), each line cut
 * down there to what the judge reads (seq, kind and, for tool events, the update), so a long turn fits the exec's
 * answer.
 */
export function journalCommand(session: string, baseline: number): string {
  const py = [
    "import json, sys",
    "for line in sys.stdin:",
    "    try: e = json.loads(line)",
    "    except ValueError: continue",
    "    if not isinstance(e, dict) or not isinstance(e.get('seq'), int): continue",
    "    k = str(e.get('kind', ''))",
    "    out = {'seq': e['seq'], 'kind': k}",
    "    if k in ('tool_call', 'tool_call_update'): out['msg'] = {'params': {'update': ((e.get('msg') or {}).get('params') or {}).get('update')}}",
    "    print(json.dumps(out))",
  ].join("\n");
  // `acp tail` writes to a file first, so its own failure is the exit the line reports (sh has no pipefail).
  return `t=$(mktemp) && { "$c" acp tail ${shq(session)} --since ${baseline} > "$t" 2>/dev/null; rc=$?; ` +
    `python3 -I -c ${shq(py)} < "$t"; py=$?; rm -f "$t"; [ "$rc" -eq 0 ] || py=$rc; echo "@@exit $py"; }`;
}

async function readJournal(ctx: ChaosContext, tag: string, session: string, baseline: number): Promise<SeqEvent[] | string> {
  const r = await ctx.exec(`${ctx.guest}${journalCommand(session, baseline)}`, 120_000).catch((e: Error) => ({ code: 1, stdout: e.message, stderr: "" }));
  if (!/@@exit 0/.test(r.stdout)) return `the machine's journal could not be read: ${(r.stdout + r.stderr).slice(-200)}`;
  const events: SeqEvent[] = [];
  for (const line of r.stdout.split("\n")) {
    try {
      const e = journalEvent(tag, JSON.parse(line));
      if (e) events.push(e);
    } catch { /* the @@exit line */ }
  }
  return events;
}

/**
 * Where the felt chat's next send is measured from: the journal's last seq once its previous turn has ended
 * (`ended`), so no record of that turn can stop the next clock. Null when that end is not verified (the turn did not
 * end, or the journal could not be read): the next felt send is then not measured.
 */
async function feltBoundary(ctx: ChaosContext, session: string, after: number, ended: boolean): Promise<number | null> {
  if (!ended) return null;
  const journal = await readJournal(ctx, "", session, after);
  return typeof journal === "string" ? null : Math.max(after, ...journal.map((e) => e.seq));
}

/** The loss verdict for one fault's counting turn: the client's view from `from` against the machine's journal. */
async function lossVerdict(ctx: ChaosContext, chat: ChatClient, tag: string, baseline: number, from: number, interrupted: boolean): Promise<LossVerdict> {
  const journal = await readJournal(ctx, tag, chat.session, baseline);
  if (typeof journal === "string") return { ok: false, text: journal };
  const last = journal.length ? journal[journal.length - 1].seq : baseline;
  const caught = await chat.caughtUp(last, 30_000);
  const slice = chat.received.slice(from);
  const client = slice.map((r) => journalEvent(tag, r.record) ?? { seq: r.seq, ks: [] });
  const reconnects = chat.reconnects.filter((i) => i >= from).map((i) => i - from);
  const verdict = judgeLoss({ n: COUNT_STEPS, journal, client, reconnects, interrupted });
  const lag = caught ? "" : ` (the client held seq ${chat.held} after 30 s${chat.lastError ? `; last error ${chat.lastError}` : ""})`;
  const pages = slice.filter((r) => r.via === "page").length;
  return { ok: verdict.ok, text: `${verdict.text}${lag}; ${slice.length} records to the client (${pages} from re-attach pages, ${chat.overlaps} live overlaps dropped)` };
}

async function terminalVerdict(ctx: ChaosContext, term: SeqTerminal | null, startError: string): Promise<LossVerdict> {
  if (!term) return { ok: false, text: `terminal: not started: ${startError}` };
  const count = async () => {
    const r = await ctx.exec(`wc -l < ${shq(term.file)} 2>/dev/null`, 30_000).catch(() => null);
    return Number(r?.stdout.trim() || 0);
  };
  let machineLines = 0;
  for (const until = Date.now() + 90_000; Date.now() < until && machineLines < term.n; await sleep(2_000)) machineLines = await count();
  await term.finish(() => term.lines(), 30_000);
  // Every line is read: the terminal may end now.
  const r = await ctx.exec(`sha256sum ${shq(term.file)} 2>&1; ${SeqTerminal.releaseCommand(term.file)}; rm -f ${shq(term.file)} ${shq(`${term.file}.done`)}`, 30_000).catch((e: Error) => ({ code: 1, stdout: e.message, stderr: "" }));
  const machineSha256 = /^([0-9a-f]{64})\s/.exec(r.stdout)?.[1];
  if (!machineSha256) return { ok: false, text: `terminal: the machine copy could not be read: ${r.stdout.slice(-200)}` };
  const v = judgeTerminal({ n: term.n, reads: term.reads, machineSha256, sha256: (t) => createHash("sha256").update(t).digest("hex") });
  return term.error && !v.ok ? { ok: false, text: `${v.text} (last read error: ${term.error})` } : v;
}

/** How many lines the guest terminal prints during each fault's turn (one each 0.1 s: about the turn's length). */
export const SEQ_LINES = 300;
/** How long the guest terminal stays up after its last line, at most, waiting for the leg to have read it all. */
const SEQ_HOLD_S = 900;

/** A tag the stub's marker regex (`\S+`) and a guest shell word both take as it is. */
const safeTag = (tag: string) => tag.replace(/[^A-Za-z0-9-]/g, "-");

/** Run every fault on the machine; one result per fault, the not-injectable ones included. */
export async function runChaos(ctx: ChaosContext): Promise<ChaosResult[]> {
  const out: ChaosResult[] = [];
  const carrier = new Carrier(ctx);
  carrier.start();
  const chat = new ChatClient(ctx);
  // The person's other chat tab, idle: what they send in it at each fault's end times the felt wait (feltAfterSend).
  const felt = new ChatClient(ctx);
  const failed = (fault: string, detail: string): ChaosResult => ({ fault, outcome: "fail", felt_ms: null, recover_ms: null, carrier: "", turn: "", detail });
  try {
    const first = await carrier.answeredAfter(0, 60_000);
    if (first === null) throw new Error("the carrier dial never answered identify before the faults");
    // The person's chat, opened and read over its own carrier dial the way the app does. Without it no fault can be
    // judged for lost output, so each fails with the reason.
    const chatError = await chat.open(ctx.harness ?? "claude").then(() => "", (e: Error) => e.message)
      || await felt.open(ctx.harness ?? "claude").then(() => "", (e: Error) => `the felt chat: ${e.message}`);
    // One reply on the felt chat before any fault, so the first fault's felt time holds no cold agent start.
    // Each felt send counts only records past the felt chat's previous turn (feltFloor; null: not verified).
    let feltFloor: number | null = felt.held;
    let warmError = "";
    if (!chatError) {
      const warmMarker = feltMarker(`${safeTag(ctx.tag)}-warm`);
      const warm = await feltAfterSend(felt, `${warmMarker} warm up.`, RECOVER_DEADLINE_MS, feltFloor);
      const warmTurn = await turnOutcome(ctx, warmMarker, felt.session);
      feltFloor = await feltBoundary(ctx, felt.session, feltFloor, warmTurn.ok);
      if (warm.felt_ms === null) warmError = `the felt chat's warm-up got no reply within ${RECOVER_DEADLINE_MS / 1000} s${warm.error ? ` (${warm.error})` : ""}`;
      else if (feltFloor === null) warmError = `the felt chat's warm-up turn has no verified end (${warmTurn.text})`;
      else ctx.log?.(`chaos: the felt chat's warm-up reply began after ${warm.felt_ms} ms`);
    }
    if (!chatError) ctx.log?.(`chaos: the client's chat ${chat.session} is open on surface ${chat.surface}, its felt chat ${felt.session} on ${felt.surface}, each over its own carrier dial`);
    for (const [i, f] of FAULTS.entries()) {
      if (chatError) {
        out.push(failed(f.name, `the client's chat could not be opened over the carrier: ${chatError}`));
        continue;
      }
      if (warmError) {
        out.push(failed(f.name, warmError));
        continue;
      }
      const tag = `${safeTag(ctx.tag)}-${i}`;
      const marker = countMarker(tag);
      // The client is attached and holds everything before this turn; the turn is judged from here.
      await chat.caughtUp(chat.held, 60_000);
      const baseline = chat.held;
      const from = chat.received.length;
      // The guest terminal printing 1..SEQ_LINES across the fault, read by the client over the carrier.
      const seq = new SeqTerminal(chat.dial, SEQ_LINES, `/tmp/cmux-chaos-seq-${tag}.txt`);
      const seqError = await seq.start(tag).then(() => "", (e: Error) => e.message);
      // The counting turn: COUNT_STEPS numbered tool calls (the model stub's counting script, countingTurnScript).
      const sent = await chat.prompt(`${marker} ${f.name}: run the counting steps.`).then(() => "", (e: Error) => e.message);
      if (sent) {
        out.push(failed(f.name, `the turn did not start: ${sent}`));
        continue;
      }
      // Mid-turn, about a third in: the fault goes in once the client has seen step COUNT_STEPS / 3, or after 120 s
      // whatever it has seen (named in the detail).
      const third = Math.ceil(COUNT_STEPS / 3);
      let reached = 0;
      for (const until = Date.now() + 120_000; Date.now() < until; await sleep(250)) {
        reached = chat.reached(tag, from);
        if (reached >= third) break;
      }
      const state = await turnState(ctx, marker, chat.session).catch(() => ({ started: 0, running: false, status: "", detail: "" }));
      if (state.started === 0) {
        out.push(failed(f.name, `the turn was sent but never showed in the chat's history (the client saw step ${reached})`));
        continue;
      }
      const when = reached >= third ? `mid-turn at step ${reached} of ${COUNT_STEPS}`
        : state.running ? `mid-turn, but the client had seen only step ${reached} of ${COUNT_STEPS}` : `after the turn (${state.status})`;
      const dialsBefore = carrier.dials;
      const movesBefore = chat.surfaceMoves;
      const resumesBefore = carrier.routeLines.filter((l) => /phase=resume .*outcome=ok/.test(l)).length;
      // A drop may hold the exec's own answer until it ends, so its budget covers the drop.
      const injectedAt = Date.now();
      const injected = await ctx.exec(`${ctx.guest}${f.command}`, f.secs * 1000 + 60_000).catch((e: Error) => ({ code: 1, stdout: e.message, stderr: "" }));
      if (!/@@ok/.test(injected.stdout)) {
        // A fault meant to run that could not be injected fails the leg: a probe must never read ok on a fault it skipped.
        out.push(failed(f.name, `could not inject: ${(injected.stdout + injected.stderr).trim().slice(-200)}`));
        continue;
      }
      const healed = causeEndedAt(injectedAt, Date.now(), f.secs);
      await sleep(Math.max(0, healed - Date.now()));
      // The person sends as the cause ends; the connection is timed alongside.
      const floor = feltFloor;
      const feltSent: Promise<Felt> = floor === null
        ? Promise.resolve({ felt_ms: null, ack_ms: null, tries: 0, error: "not sent: the felt chat's previous turn has no verified end" })
        : feltAfterSend(felt, `${feltMarker(tag)} ${f.name}: reply.`, RECOVER_DEADLINE_MS, floor);
      const back = await carrier.answeredAfter(healed, RECOVER_DEADLINE_MS);
      const recover = back === null ? null : back - healed;
      const feel = await feltSent;
      const feltTurn = floor === null ? { ok: false, text: "not sent" } : await turnOutcome(ctx, feltMarker(tag), felt.session);
      feltFloor = floor === null ? null : await feltBoundary(ctx, felt.session, floor, feltTurn.ok);
      const resumed = carrier.routeLines.filter((l) => /phase=resume .*outcome=ok/.test(l)).length > resumesBefore;
      const how = carrier.dials > dialsBefore ? `new dial (${carrier.dials - dialsBefore})` : resumed ? "resumed the session" : "unbroken";
      const turn = await turnOutcome(ctx, marker, chat.session);
      const loss = await lossVerdict(ctx, chat, tag, baseline, from, turn.interrupted === true);
      const terminal = await terminalVerdict(ctx, seqError ? null : seq, seqError);
      const ok = feel.felt_ms !== null && feltTurn.ok && recover !== null && turn.ok && loss.ok && terminal.ok;
      const feltText = feel.felt_ms === null
        ? `no reply within ${RECOVER_DEADLINE_MS / 1000} s of a send at the cause's end (${feel.tries} tries${feel.error ? `; last error ${feel.error}` : ""})`
        : `the reply began ${feel.felt_ms} ms after a send at the cause's end (taken at ${feel.ack_ms} ms, ${feel.tries} ${feel.tries === 1 ? "try" : "tries"})`;
      const result: ChaosResult = {
        fault: f.name,
        outcome: ok ? "ok" : "fail",
        felt_ms: feel.felt_ms,
        recover_ms: recover,
        carrier: how,
        turn: turn.text,
        detail: `injected ${when}; ${feltText}, its turn ${feltTurn.text}; ${recover === null ? `the carrier gave no answer within ${RECOVER_DEADLINE_MS / 1000} s` : `the carrier answered ${recover} ms after the cause ended`}; carrier ${how}; turn ${turn.text}; ${loss.text}${chat.surfaceMoves > movesBefore ? ` (the chat's tab came back on a new surface)` : ""}; ${terminal.text}`,
      };
      ctx.log?.(`chaos: ${f.name}: ${result.detail}`);
      out.push(result);
      // Let the carrier settle before the next fault.
      await carrier.answeredAfter(Date.now(), 30_000);
    }
  } finally {
    carrier.stop();
    chat.stop();
    felt.stop();
  }
  for (const n of NOT_INJECTED) out.push({ fault: n.name, outcome: "not run", felt_ms: null, recover_ms: null, carrier: "", turn: "", detail: n.why });
  return out;
}

/** How many numbered tool calls the counting turn makes, and the pause in each (about 100 x (0.2 s + a round trip)). */
export const COUNT_STEPS = 100;
const COUNT_SLEEP_S = 0.2;

/** The counting turn's prompt marker; the stub's turn script matches it, and its group is the turn's tag. */
export const countMarker = (tag: string) => `[chaos-count ${tag}]`;

/**
 * The model stub's turn script for the counting turn (model_stub.py "turns"): steps 1..n each run one shell call that
 * prints `chaos-<tag>-K` (printf joins it, so the call's own command text never carries it and only its result
 * counts), then a reply. The stub counts steps from the turn's own prompt, so the session's earlier tool calls do not
 * move it.
 */
export function countingTurnScript(n = COUNT_STEPS): { match: string; steps: Array<Record<string, string>> } {
  const tag = "{{prompt~\\[chaos-count (\\S+)\\]}}";
  const steps: Array<Record<string, string>> = [];
  for (let k = 1; k <= n; k++) steps.push({ shell: `sleep ${COUNT_SLEEP_S}; printf '%s-%s-%s\\n' chaos ${tag} ${k}` });
  steps.push({ text: `Counted ${n} steps for ${tag}.` });
  return { match: "\\[chaos-count \\S+\\]", steps };
}

/** One event of a session's journal, as the machine has it or as a client received it. */
export type SeqEvent = {
  seq: number;
  /** The counting steps K whose tool output (`chaos-<tag>-K`) this event carries. */
  ks: number[];
  /**
   * The tool call the event belongs to (ACP `toolCallId`), when it has one: a call's output may come in more than one
   * update, so a step counts once per call, and twice only when two calls printed it.
   */
  call?: string;
};

export type LossVerdict = { ok: boolean; text: string };

/**
 * One acpmux journal event (`acp tail` line: `{seq, kind, msg: {params: {update}}}`, or a live `session/update` whose
 * seq is `_meta.acpmux.seq`) as a SeqEvent. Steps are read only from the ACP tool events the person's chat renders
 * (`tool_call`, `tool_call_update`), keyed by their `toolCallId`: a harness's raw transcript events (`claude.user`)
 * carry the same output again and are not a second run of the step. Null for a line that is not a journal event.
 */
export function journalEvent(tag: string, line: unknown): SeqEvent | null {
  if (!line || typeof line !== "object") return null;
  const e = line as any;
  const update = e.msg?.params?.update ?? e.params?.update ?? e.update;
  const seq = typeof e.seq === "number" ? e.seq
    : typeof e.params?._meta?.acpmux?.seq === "number" ? e.params._meta.acpmux.seq
    : typeof e._meta?.acpmux?.seq === "number" ? e._meta.acpmux.seq : null;
  if (seq === null) return null;
  const kind = String(e.kind ?? update?.sessionUpdate ?? "");
  const tool = kind === "tool_call" || kind === "tool_call_update";
  return {
    seq,
    ks: tool ? [...new Set(countedSteps(tag, JSON.stringify(update ?? e)))] : [],
    ...(tool && typeof update?.toolCallId === "string" ? { call: update.toolCallId } : {}),
  };
}

/** The `chaos-<tag>-K` numbers in an event's text (a tool result's output); K=1 never matches inside 10. */
export function countedSteps(tag: string, text: string): number[] {
  const re = new RegExp(`chaos-${tag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}-(\\d+)(?!\\d)`, "g");
  return [...text.matchAll(re)].map((m) => Number(m[1]));
}

/**
 * Whether a client lost or doubled output: the machine's journal (`journal`, the session's events of the turn from
 * its first seq) against what the client received across the fault (`client`, in arrival order, every delivery kept,
 * a replayed one too), for a counting turn of steps 1..n.
 *
 * - the journal's seqs are contiguous and unique (the machine itself lost or doubled nothing);
 * - the client's seqs, in arrival order, are each the one before plus 1: no gap, no repeat, and so a replay after a
 *   reconnect starts at the last seq seen + 1 (`reconnects` names where the client came back, for the message);
 * - the client's last seq is the journal's last (it caught up), and each delivered event carries the same steps as the
 *   machine's event of that seq;
 * - every step K in 1..n shows exactly once in the journal and exactly once in what the client received. A turn a
 *   restart cut short (`interrupted`) ran only to some step M: then every step in 1..M, M the journal's highest.
 */
export function judgeLoss(input: { n: number; journal: SeqEvent[]; client: SeqEvent[]; reconnects?: number[]; interrupted?: boolean }): LossVerdict {
  const problems: string[] = [];
  const { journal, client } = input;
  const reached = Math.max(0, ...journal.flatMap((e) => e.ks));
  const n = input.interrupted ? Math.min(input.n, reached) : input.n;
  const range = (xs: number[]) => xs.length > 6 ? `${xs.slice(0, 6).join(",")},... (${xs.length})` : xs.join(",");
  if (!journal.length) return { ok: false, text: "the machine's journal has no events for the turn" };
  if (!client.length) return { ok: false, text: "the client received no events for the turn" };
  // The machine's journal.
  const bySeq = new Map<number, SeqEvent>();
  const jGaps: number[] = [];
  const jRepeats: number[] = [];
  for (let i = 0; i < journal.length; i++) {
    const e = journal[i];
    if (bySeq.has(e.seq)) jRepeats.push(e.seq);
    bySeq.set(e.seq, e);
    if (i > 0 && e.seq !== journal[i - 1].seq + 1 && e.seq > journal[i - 1].seq) jGaps.push(journal[i - 1].seq + 1);
  }
  if (jGaps.length) problems.push(`the journal skips seq ${range(jGaps)}`);
  if (jRepeats.length) problems.push(`the journal repeats seq ${range(jRepeats)}`);
  // The client's stream, in arrival order.
  const cGaps: string[] = [];
  const cRepeats: number[] = [];
  const seen = new Set<number>();
  for (let i = 0; i < client.length; i++) {
    const e = client[i];
    if (seen.has(e.seq)) cRepeats.push(e.seq);
    else if (i > 0 && e.seq !== client[i - 1].seq + 1) {
      const at = input.reconnects?.includes(i) ? " (a replay after a reconnect)" : "";
      cGaps.push(`${client[i - 1].seq}->${e.seq}${at}`);
    }
    seen.add(e.seq);
  }
  if (cGaps.length) problems.push(`the client's stream jumps ${cGaps.slice(0, 4).join(", ")}${cGaps.length > 4 ? ` (${cGaps.length})` : ""}`);
  if (cRepeats.length) problems.push(`the client received seq ${range(cRepeats)} twice`);
  const jLast = journal[journal.length - 1].seq;
  const cLast = Math.max(...client.map((e) => e.seq));
  if (cLast < jLast) problems.push(`the client stopped at seq ${cLast}, the journal goes to ${jLast}`);
  const early = client.filter((e) => e.seq < journal[0].seq).map((e) => e.seq);
  if (early.length) problems.push(`the client received seq ${range(early)} from before the turn again (a replay that started too early)`);
  else if (client[0].seq > journal[0].seq) problems.push(`the client started at seq ${client[0].seq}, after the turn's first ${journal[0].seq}`);
  const differ = client.filter((e) => bySeq.has(e.seq) && bySeq.get(e.seq)!.ks.join(",") !== e.ks.join(",")).map((e) => e.seq);
  if (differ.length) problems.push(`the client's seq ${range(differ)} differ from the journal's`);
  // Every counting step, exactly once on each side.
  const steps = (events: SeqEvent[], who: string) => {
    // A delivery the client got twice is already named above; here each step is counted once per tool call.
    const calls = new Map<number, Set<string>>();
    const once = new Set<number>();
    for (const e of events) {
      if (once.has(e.seq)) continue;
      once.add(e.seq);
      for (const k of new Set(e.ks)) {
        if (!calls.has(k)) calls.set(k, new Set());
        calls.get(k)!.add(e.call ?? `seq ${e.seq}`);
      }
    }
    const count = new Map([...calls].map(([k, c]) => [k, c.size]));
    const missing: number[] = [];
    const twice: number[] = [];
    for (let k = 1; k <= n; k++) {
      const c = count.get(k) ?? 0;
      if (c === 0) missing.push(k);
      if (c > 1) twice.push(k);
    }
    if (missing.length) problems.push(`${who} is missing step ${range(missing)}`);
    if (twice.length) problems.push(`${who} has step ${range(twice)} more than once`);
  };
  steps(journal, "the journal");
  steps(client, "the client");
  if (problems.length) return { ok: false, text: `lost or doubled output: ${problems.join("; ")}` };
  const back = input.reconnects?.length ? `, ${input.reconnects.length} reconnect(s) each resumed at the next seq` : "";
  const covered = input.interrupted ? `steps 1..${n} of ${input.n} (the turn was cut short)` : `all ${n} steps`;
  return { ok: true, text: `no lost output: seq ${client[0].seq}..${cLast} contiguous, ${covered} once on both sides${back}` };
}

/** One `terminal.output_read` answer: the offset asked for and what came back. */
export type TerminalRead = { after: number; start: number; next: number; complete: boolean; text: string };

/**
 * The terminal's text as the client holds it after `reads` (each asked from the last one's `next_offset`), and what was
 * wrong with any read. A read answers from where it asked (`start_offset` = `after`) and is appended; or, once the
 * terminal has ended, a read whose offset falls inside the snapshot's coverage answers with the snapshot's whole
 * projection from offset 0 to the stream's end (terminal.output_read's documented contract, tested in cmux-tui's
 * terminal_host_recovery.rs): `start_offset` 0, below `after`, `complete`, `next_offset` at or past `after`. That one
 * replaces what the client held, as a client of the contract does; it is never appended. Any other start is a skip
 * (later) or a repeat (earlier), and an incomplete window is output past retention.
 */
export function assembleTerminal(reads: TerminalRead[]): { text: string; problems: string[]; snapshots: number } {
  const problems: string[] = [];
  let text = "";
  let snapshots = 0;
  for (let i = 0; i < reads.length; i++) {
    const r = reads[i];
    const want = i === 0 ? 0 : reads[i - 1].next;
    if (r.after !== want) problems.push(`read ${i} asked from ${r.after}, not the last read's end ${want}`);
    if (!r.complete) problems.push(`read ${i} from ${r.after} was not complete (output past retention)`);
    if (r.start === r.after) {
      text += r.text;
    } else if (r.start === 0 && r.after > 0 && r.complete && r.next >= r.after) {
      snapshots += 1;
      text = r.text;
    } else if (r.start === 0 && r.after > 0 && r.complete) {
      problems.push(`read ${i} asked from ${r.after} and got a snapshot from 0 that ends at ${r.next}, before it`);
    } else if (r.after === want) {
      problems.push(`read ${i} asked from ${r.after} and got from ${r.start} (${r.start > r.after ? "skipped" : "repeated"} ${Math.abs(r.start - r.after)} bytes)`);
    }
  }
  return { text, problems, snapshots };
}

/**
 * Whether the client lost terminal output: the reads it made over the carrier (in order, each from the last one's
 * `next_offset`) against the copy the machine's own `tee` kept of the same `seq 1 n`.
 *
 * - every read is contiguous with the one before and complete, or is the ended terminal's snapshot (assembleTerminal):
 *   no byte skipped, none read twice, no retention cut (the terminal output paths have no ReplayGap marker; a skip
 *   shows as a later start or an incomplete window);
 * - the numbers the client holds are 1..n, each once, in order, and their sha256 is the machine copy's.
 */
export function judgeTerminal(input: { n: number; reads: TerminalRead[]; machineSha256: string; sha256: (text: string) => string }): LossVerdict {
  const { reads, n } = input;
  if (!reads.length) return { ok: false, text: "the client read no terminal output" };
  const held = assembleTerminal(reads);
  const problems = [...held.problems];
  const lines = held.text.replace(/\r/g, "").split("\n").map((l) => l.trim()).filter((l) => /^\d+$/.test(l));
  const text = lines.length ? `${lines.join("\n")}\n` : "";
  const nums = lines.map(Number);
  const out = nums.findIndex((v, i) => v !== i + 1);
  if (out >= 0) problems.push(`line ${out + 1} reads ${nums[out]}, not ${out + 1}`);
  if (nums.length !== n) problems.push(`the client read ${nums.length} of ${n} lines`);
  const sha = input.sha256(text);
  if (sha !== input.machineSha256) problems.push(`sha256 ${sha.slice(0, 12)} differs from the machine copy's ${input.machineSha256.slice(0, 12)}`);
  if (problems.length) return { ok: false, text: `terminal output lost: ${problems.slice(0, 4).join("; ")}` };
  const snap = held.snapshots ? `, ${held.snapshots} snapshot read${held.snapshots > 1 ? "s" : ""} after the terminal ended taken in place of what was held` : "";
  return { ok: true, text: `terminal: all ${n} lines over ${reads.length} reads, offsets contiguous${snap}, sha256 matches the machine copy` };
}

/**
 * The leg as one synthetic-probe row (cmuxterm-hq probes.py): ok only when every injected fault passed. `ms` is the
 * slowest felt time (send to the reply's first record), the number the person lives; `network_ms` the slowest
 * connection recovery.
 */
export function chaosProbeRow(probe: string, results: ChaosResult[], run?: string, at = new Date()): Record<string, unknown> {
  const ran = results.filter((r) => r.outcome !== "not run");
  const failed = ran.filter((r) => r.outcome === "fail");
  const slowest = (key: "felt_ms" | "recover_ms") => {
    const times = ran.map((r) => r[key]).filter((n): n is number => typeof n === "number");
    return times.length ? Math.max(...times) : null;
  };
  return {
    probe,
    at: at.toISOString().replace(/\.\d+Z$/, "Z"),
    outcome: ran.length && !failed.length ? "ok" : "fail",
    ms: slowest("felt_ms"),
    network_ms: slowest("recover_ms"),
    error: failed.length ? failed.map((r) => `${r.fault}: ${r.detail}`).join("; ").slice(0, 500) : ran.length ? null : "no fault ran",
    faults: results,
    ...(run ? { run } : {}),
  };
}
