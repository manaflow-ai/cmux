/**
 * The resume matrix (cloud-journey.ts --resume-matrix): one Cloud machine with a live agent chat, paused and woken
 * again and again, each wake timed from its event to four points:
 *
 *   answered    the resume call's answer (the provider's, or the platform's around it)
 *   running     the guest running again: the first tick of a 50 ms guest ticker after the pause's gap
 *   registered  the session host's relay registered again (guest journal: `relay registration on X: registered`)
 *   first_byte  the first record of the agent's reply on the client, over its own carrier dial, as the app holds it
 *
 * The same machine is woken three ways in one run, interleaved sample by sample (so the arms see the same machine,
 * the same image and the same hour):
 *
 *   direct     the provider's own resume, called with the machine's client session (no cmux-platform in the path);
 *              `direct_mode` says which call: `start` (POST {api}/v5/vms/{id}/start), or `exec` (an exec-await, which
 *              the provider answers by resuming the VM) when the session may not start the VM
 *   platform   cmux's resume (`cloud.machine.start` on the cmux API, CloudDO and cmux-platform), as the app's Resume
 *   send       no resume call: the prompt alone, sent to the paused machine (the app's wake on message)
 *
 * In every arm the chat's prompt goes out at the event, as a person's Send does, and is held until the machine takes
 * it (feltAfterSend: retried with the same prompt id, which the daemon takes once).
 *
 * Pause lengths are the treatment (`--resume-matrix 5,30,300,900,3600`): each sample pauses through the platform,
 * waits until the platform reads `paused`, holds that many seconds, then wakes. A sample's `paused_ms` is the hold as
 * it really was. Guest times are on the guest's wall clock, put on the runner's by an offset measured at each
 * sample's end (an exec's round-trip midpoint; Freestyle guest clocks run straight through a pause, RFD 0017).
 *
 * `bun scripts/cmux-next/cloud-resume-matrix.ts aggregate A.json B.json ... [--md OUT.md]` merges the samples of
 * several runs (one machine each, run side by side for the long pauses) into one table: p50 and p95 per pause length,
 * arm and point, with n.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { ChatClient, feltAfterSend, feltBoundary, feltMarker, turnOutcome, type ChaosContext } from "./cloud-chaos.ts";

export type ResumeArm = "direct" | "platform" | "send";
export const RESUME_ARMS: ResumeArm[] = ["direct", "platform", "send"];
export const RESUME_POINTS = ["answered", "running", "registered", "first_byte"] as const;
/** Measured beside the points, not from the event: the fill's page-in walk after the wake. */
export const RESUME_EXTRAS = ["page_in"] as const;
export type ResumePoint = (typeof RESUME_POINTS)[number];

export type ResumeSample = {
  pause_s: number;
  arm: ResumeArm;
  i: number;
  machine: string;
  at: string;
  paused_ms: number | null;
  answered_ms: number | null;
  running_ms: number | null;
  registered_ms: number | null;
  first_byte_ms: number | null;
  ack_ms: number | null;
  /** cmux-platform's Server-Timing on the resume answer, when it sends one (provider, vmapi, total). */
  server_timing?: Record<string, number>;
  direct_mode?: "start" | "exec";
  /** The direct arm's client session was minted after the hold, on the paused machine: a pause longer than a
   * session lives (CLIENT_SESSION_MAX_S). Minting one may wake the machine, so such a sample's direct times read late. */
  session_minted_paused?: boolean;
  /** The guest's wall clock minus the runner's, ms, from the exec at the sample's end. */
  clock_offset_ms: number | null;
  /** The guest touching every page of the matrix's memory fill after the wake (--resume-fill), ms: the lazy page-in. */
  page_in_ms?: number | null;
  /** The guest saw a resume (`notify event=resumed`) this long after the event, guest clock corrected. */
  resumed_notify_ms?: number | null;
  /** With --resume-fill: the MiB the guest held resident through the pause (the page-in's size). */
  fill_mib?: number;
  /**
   * The agent came back as it was (hq#21300 lane C's restore): the same agent processes before the pause and after the
   * wake (`agent_same_process`) and the wake's turn ended once, completed. Null when either read failed.
   */
  agent_same_process?: boolean | null;
  restored?: boolean | null;
  /** The turn's own end, when it did not complete (a product answer: `Not logged in` after a resume, cmux#45776). */
  turn?: string;
  /**
   * Which part failed, so a harness fault is told from a product one: `pause` (the pause did not land or hold),
   * `unavailable` (the arm cannot run here), `wake` (the resume call), `attach` (the client's new dial did not attach
   * the chat after the wake), `reply` (attached, no reply), `turn` (a reply, but the turn did not complete), `read`.
   */
  cause?: "pause" | "unavailable" | "wake" | "attach" | "reply" | "turn" | "read";
  error: string;
};

export type ResumeDeps = {
  ctx: ChaosContext;
  /** Pause through the platform and resolve once it reads `paused`. */
  pause: () => Promise<void>;
  /** cmux's resume (the app's): resolves when the call answers; its Server-Timing when there is one. */
  platformResume: () => Promise<{ serverTiming?: Record<string, number> }>;
  /** After a direct or send arm: tell the platform the machine runs (its own read), so the next pause is real. */
  platformSync: () => Promise<void>;
  /** The platform's status read of the machine (`paused`, `running`, ...): the pause is checked to hold before a wake. */
  status?: () => Promise<string>;
  /** A fresh client session for the machine: the provider's API base, VM id and identity token (ttl 60..900 s). */
  clientSession: (ttlSeconds: number) => Promise<{ token: string; vm_id: string; api_base_url: string }>;
  /**
   * Before each sample: a sign-in that is getting old is made again (the agent test account's Stack access token
   * lasts about an hour, and a 5 s cell runs longer; the first run's 900 s and 3600 s cells read 401 after it).
   */
  refreshAuth?: () => Promise<void>;
  fetchImpl?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  log?: (line: string) => void;
  /** Percent of MemTotal a guest holder keeps resident through every pause (0: none), as resume-memory-probe.sh. */
  fillPct?: number;
  /** Each sample as it ends, with every sample so far: the caller writes them out, so a cut-short run still has them. */
  onSample?: (s: ResumeSample, all: ResumeSample[]) => void;
  /** Each early stop (a cell out of time, an arm or a cell failing K samples in a row), as it happens. */
  onStop?: (stop: ResumeStop, all: ResumeStop[]) => void;
  /**
   * Wall-clock time (runner ms) the whole matrix must end by: what is left is split evenly over the pause lengths
   * still to run, and a cell takes no sample it cannot finish in its share (the longest sample so far, or the pause
   * plus a minute). The job's step timeout would otherwise kill the run before it writes anything (run 45147962604).
   */
  deadlineAt?: number;
  /** The machine's provider as the platform names it, for the table and an unavailable arm's reason. */
  provider?: string;
  /** K: an arm that fails K samples in a row is dropped from its cell, and a cell whose last K samples all failed ends. */
  failStreak?: number;
};

/** Why a cell or arm took fewer samples than asked. */
export type ResumeStop = { pause_s: number; arm?: ResumeArm; after: number; reason: string };

/** Default K for ResumeDeps.failStreak. */
export const FAIL_STREAK = 3;

const TICKER = "/tmp/cmux-resume-matrix";
/** A 50 ms ticker that writes one line per gap longer than 1 s: `<last tick before> <first tick after>` (epoch ms). */
export const TICKER_START = `mkdir -p ${TICKER}; if ! [ -s ${TICKER}/pid ] || ! kill -0 "$(cat ${TICKER}/pid)" 2>/dev/null; then `
  + `nohup sh -c 'prev=$(date +%s%3N); while :; do sleep 0.05; now=$(date +%s%3N); [ $((now-prev)) -gt 1000 ] && echo "$prev $now" >> ${TICKER}/gaps; prev=$now; done' `
  + `>/dev/null 2>&1 & echo $! > ${TICKER}/pid; fi; echo "@@ticker $(cat ${TICKER}/pid)"`;

/**
 * A holder process that keeps `pct`% of MemTotal resident and, on each SIGUSR1, touches every page of it and writes
 * the walk's time to ${TICKER}/touch (cmux-platform scripts/resume-memory-probe.sh's fill, as a long-lived holder).
 */
export function fillStartCommand(pct: number): string {
  const py = [
    "import mmap,os,signal,time",
    `n=int(int(open('/proc/meminfo').read().split()[1])*1024*${pct}/100)//4096*4096`,
    "m=mmap.mmap(-1,n)",
    "for o in range(0,n,4096): m[o]=1",
    "def t(*_):",
    " a=time.monotonic()",
    " for o in range(0,n,4096): m[o]=(m[o]+1)%256",
    ` open('${TICKER}/touch','w').write(str(int((time.monotonic()-a)*1000)))`,
    "signal.signal(signal.SIGUSR1,t)",
    `open('${TICKER}/fill','w').write(str(n))`,
    "while True: signal.pause()",
  ].join("\n");
  return `mkdir -p ${TICKER}; if ! [ -s ${TICKER}/fillpid ] || ! kill -0 "$(cat ${TICKER}/fillpid)" 2>/dev/null; then `
    + `echo ${Buffer.from(`${py}\n`).toString("base64")} | base64 -d > ${TICKER}/fill.py; nohup python3 ${TICKER}/fill.py >/dev/null 2>&1 & echo $! > ${TICKER}/fillpid; fi; `
    + `for i in $(seq 1 600); do [ -s ${TICKER}/fill ] && break; sleep 0.1; done; echo "@@fill $(cat ${TICKER}/fill 2>/dev/null)"`;
}

/** Touch the fill once and print the walk's ms (the page-in after a wake; warm when nothing was paged out). */
export const TOUCH_COMMAND = `rm -f ${TICKER}/touch; kill -USR1 "$(cat ${TICKER}/fillpid)" 2>/dev/null && `
  + `for i in $(seq 1 1200); do [ -s ${TICKER}/touch ] && break; sleep 0.05; done; echo "@@touch $(cat ${TICKER}/touch 2>/dev/null)"`;

/** The agent processes on the guest (pid and start time, so a restarted one with a reused pid differs). */
export const AGENT_PIDS_COMMAND = `for p in $(pgrep -x claude 2>/dev/null; pgrep -f 'claude-code|codex app-server' 2>/dev/null); do echo "@@agent $p $(cut -d' ' -f22 /proc/$p/stat 2>/dev/null)"; done | sort -u; echo "@@agents-read"`;

/** The agent process set an AGENT_PIDS_COMMAND printed, sorted; null when the read did not finish. */
export function parseAgents(stdout: string): string[] | null {
  if (!stdout.includes("@@agents-read")) return null;
  return [...new Set([...stdout.matchAll(/@@agent (\d+ \d+)/g)].map((m) => m[1]))].sort();
}

/** Whether a provider's answer says the arm cannot run on this machine at all (not a failed sample of it). */
export function armUnavailable(error: string): boolean {
  return /cloud\.provider\.unsupported|has no client sessions/.test(error);
}

/** One exec after a wake: the guest's clock now, the ticker's gaps and the journal's relay and resume lines since `sinceS`. */
export function wakeFactsCommand(sinceS: number): string {
  return `echo "@@now $(date +%s%3N)"; sed 's/^/@@gap /' ${TICKER}/gaps 2>/dev/null | tail -n 50; ${AGENT_PIDS_COMMAND}; `
    + `J=journalctl; [ "$(id -u)" = 0 ] || J='sudo -n journalctl'; `
    + `$J -o short-unix --no-pager --since @${Math.max(0, Math.floor(sinceS) - 5)} 2>/dev/null `
    + `| grep -E 'relay registration on \\S+: registered|event=resumed' | head -n 200 | sed 's/^/@@j /'; true`;
}

/** The guest's facts for one wake at runner time `t0` (ms), the exec sent at `sent` and answered at `got`. */
export function parseWakeFacts(stdout: string, t0: number, sent: number, got: number): { offset: number | null; running: number | null; registered: number | null; resumed: number | null } {
  const now = /@@now (\d+)/.exec(stdout);
  const offset = now ? Number(now[1]) - (sent + got) / 2 : null;
  const g0 = t0 + (offset ?? 0);
  let running: number | null = null;
  for (const m of stdout.matchAll(/@@gap (\d+) (\d+)/g)) {
    const [before, after] = [Number(m[1]), Number(m[2])];
    // The pause's gap is the one that spans the event; a gap after it (a second freeze) is not this wake.
    if (before <= g0 && after >= g0 && (running === null || after < running)) running = after;
  }
  let registered: number | null = null;
  let resumed: number | null = null;
  for (const m of stdout.matchAll(/@@j (\d+(?:\.\d+)?) (.*)/g)) {
    const at = Math.round(Number(m[1]) * 1000);
    if (at < g0) continue;
    if (/relay registration on \S+: registered/.test(m[2]) && (registered === null || at < registered)) registered = at;
    if (/event=resumed/.test(m[2]) && (resumed === null || at < resumed)) resumed = at;
  }
  const rel = (x: number | null) => (x === null ? null : Math.max(0, x - g0));
  return { offset: offset === null ? null : Math.round(offset), running: rel(running), registered: rel(registered), resumed: rel(resumed) };
}

/** `provider;dur=812, total;dur=1490` as {provider: 812, total: 1490}. */
export function parseServerTiming(header: string | null | undefined): Record<string, number> | undefined {
  if (!header) return undefined;
  const out: Record<string, number> = {};
  for (const part of header.split(",")) {
    const name = part.split(";")[0]?.trim();
    const dur = /dur=([\d.]+)/.exec(part)?.[1];
    if (name && dur !== undefined) out[name] = Math.round(Number(dur));
  }
  return Object.keys(out).length ? out : undefined;
}

/** The arms in sample i's order: rotated each sample, so no arm always goes first after a pause. */
export function armOrder(arms: ResumeArm[], i: number): ResumeArm[] {
  const k = i % arms.length;
  return [...arms.slice(k), ...arms.slice(0, k)];
}

/**
 * The provider's resume, called directly: POST {api}/v5/vms/{id}/start with the client session's identity; a session
 * that may not start the VM (401, 403, 404, 405) is remembered and the wake is an exec-await instead, which the
 * provider answers by resuming the VM first.
 */
export async function directWake(session: { token: string; vm_id: string; api_base_url: string }, mode: { m: "start" | "exec" }, fetchImpl: typeof fetch = fetch): Promise<{ status: number; mode: "start" | "exec" }> {
  const base = session.api_base_url.replace(/\/+$/, "");
  const headers = { "content-type": "application/json", "x-freestyle-identity-access-token": session.token };
  if (mode.m === "start") {
    const r = await fetchImpl(`${base}/v5/vms/${session.vm_id}/start`, { method: "POST", headers, body: "{}", signal: AbortSignal.timeout(120_000) });
    await r.arrayBuffer().catch(() => undefined);
    if (![401, 403, 404, 405].includes(r.status)) return { status: r.status, mode: "start" };
    mode.m = "exec";
  }
  const r = await fetchImpl(`${base}/v5/vms/${session.vm_id}/exec-await`, { method: "POST", headers, body: JSON.stringify({ command: "true", timeoutMs: 60_000 }), signal: AbortSignal.timeout(120_000) });
  await r.arrayBuffer().catch(() => undefined);
  return { status: r.status, mode: "exec" };
}

const FIRST_BYTE_DEADLINE_MS = 180_000;
/** The client-session route's ttl_seconds bounds (validation.invalid outside them). */
export const CLIENT_SESSION_MIN_S = 60;
export const CLIENT_SESSION_MAX_S = 900;
/** Room a direct sample's session keeps past its hold: the pause's own wait, the wake and the reply. */
const SESSION_SLACK_S = 240;

/**
 * When the direct arm mints its client session and for how long: before the pause while the hold and its slack fit in
 * the longest session the route gives (minting for a paused machine may wake it), else after the hold.
 */
export function directSessionPlan(pauseS: number): { ttl: number; afterHold: boolean } {
  const want = Math.ceil(pauseS) + SESSION_SLACK_S;
  return want <= CLIENT_SESSION_MAX_S
    ? { ttl: Math.max(CLIENT_SESSION_MIN_S, want), afterHold: false }
    : { ttl: Math.max(CLIENT_SESSION_MIN_S, Math.min(CLIENT_SESSION_MAX_S, SESSION_SLACK_S)), afterHold: true };
}
const safe = (tag: string) => tag.replace(/[^A-Za-z0-9-]/g, "-");

/** A cell's end (runner ms): its even share of what is left before `deadlineAt`, over `cellsLeft` pause lengths. */
export function cellDeadline(nowMs: number, deadlineAt: number | undefined, cellsLeft: number): number {
  if (deadlineAt === undefined) return Infinity;
  return nowMs + Math.max(0, deadlineAt - nowMs) / Math.max(1, cellsLeft);
}

/** The whole matrix on one machine: every pause length, n samples of every arm, interleaved. */
export async function runResumeMatrix(deps: ResumeDeps, pauses: number[], n: number, arms: ResumeArm[] = RESUME_ARMS): Promise<ResumeSample[]> {
  const { ctx } = deps;
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const log = deps.log ?? ctx.log ?? (() => undefined);
  const k = Math.max(1, deps.failStreak ?? FAIL_STREAK);
  const out: ResumeSample[] = [];
  const stops: ResumeStop[] = [];
  let fillMib: number | undefined;
  /** Arms no machine of this provider can run (the direct arm on a provider with no client sessions). */
  const unavailable = new Set<ResumeArm>();
  const stop = (x: ResumeStop) => {
    stops.push(x);
    log(`resume matrix: pause ${x.pause_s} s${x.arm ? ` ${x.arm}` : ""}: stopped after ${x.after} sample(s): ${x.reason}`);
    deps.onStop?.(x, stops);
  };
  const started = await ctx.exec(`${ctx.guest}${TICKER_START}`, 60_000);
  if (!/@@ticker \d+/.test(started.stdout)) throw new Error(`the guest ticker did not start: ${(started.stdout + started.stderr).slice(-200)}`);
  if (deps.fillPct) {
    const f = await ctx.exec(`${ctx.guest}${fillStartCommand(deps.fillPct)}`, 120_000);
    if (!/@@fill \d+/.test(f.stdout)) throw new Error(`the guest memory fill did not start: ${(f.stdout + f.stderr).slice(-200)}`);
    fillMib = Math.round(Number(/@@fill (\d+)/.exec(f.stdout)![1]) / 2 ** 20);
    log(`resume matrix: holding ${fillMib} MiB resident (${deps.fillPct}% of MemTotal)`);
  }
  const chat = new ChatClient(ctx);
  await chat.open(ctx.harness ?? "claude");
  let floor: number | null = chat.held;
  const warmMarker = feltMarker(`${safe(ctx.tag)}-rm-warm`);
  const warm = await feltAfterSend(chat, `${warmMarker} warm up.`, FIRST_BYTE_DEADLINE_MS, floor);
  floor = await feltBoundary(ctx, chat.session, floor, (await turnOutcome(ctx, warmMarker, chat.session)).ok);
  if (warm.felt_ms === null || floor === null) throw new Error(`the matrix chat's warm-up turn did not finish: ${warm.error || "no verified end"}`);
  const direct = { m: "start" as "start" | "exec" };
  try {
    for (const [cell, pause_s] of pauses.entries()) {
      const until = cellDeadline(now(), deps.deadlineAt, pauses.length - cell);
      const live = new Set(arms.filter((a) => !unavailable.has(a)));
      const armStreak = new Map<ResumeArm, number>();
      let cellStreak = 0;
      let longest = pause_s * 1000 + 60_000;
      let taken = 0;
      let ended = false;
      for (let i = 0; i < n && !ended; i++) {
        for (const arm of armOrder(arms, i)) {
          if (!live.has(arm)) continue;
          if (now() + longest > until) {
            stop({ pause_s, after: taken, reason: `out of time: the cell's budget ends in ${Math.max(0, Math.round((until - now()) / 1000))} s, a sample takes up to ${Math.round(longest / 1000)} s` });
            ended = true;
            break;
          }
          const sampleStart = now();
          const s: ResumeSample = { pause_s, arm, i, machine: ctx.machine, at: new Date().toISOString(), paused_ms: null, answered_ms: null, running_ms: null, registered_ms: null, first_byte_ms: null, ack_ms: null, clock_offset_ms: null, error: "" };
          out.push(s);
          if (fillMib !== undefined) s.fill_mib = fillMib;
          try {
            await deps.refreshAuth?.();
            // The client session is minted while the machine runs (minting one for a paused machine may wake it),
            // unless the hold outlasts any session the route gives.
            const plan = directSessionPlan(pause_s);
            let session = null as Awaited<ReturnType<ResumeDeps["clientSession"]>> | null;
            if (arm === "direct" && !plan.afterHold) {
              try { session = await deps.clientSession(plan.ttl); } catch (e) { s.cause = armUnavailable((e as Error).message) ? "unavailable" : "wake"; throw e; }
            }
            await chat.caughtUp(chat.held, 30_000);
            const before = parseAgents((await ctx.exec(`${ctx.guest}${AGENT_PIDS_COMMAND}`, 60_000).catch(() => ({ stdout: "" }))).stdout);
            // The client's dial ends before the pause and stays down through the hold: a held dial freezes with the
            // machine, and a redial may wake it (run 45177970049: `not_paused (state running)` after a 5 s hold).
            chat.suspend();
            try { await deps.pause(); } catch (e) { s.cause = "pause"; throw new Error(`pause: ${(e as Error).message}`); }
            const pausedAt = now();
            await sleep(pause_s * 1000);
            if (deps.status) {
              const st = await deps.status().catch((e: Error) => `unread (${e.message})`);
              if (st !== "paused") { s.cause = "pause"; throw new Error(`pause did not hold: the machine read ${st} after the ${pause_s} s hold`); }
            }
            if (arm === "direct" && plan.afterHold) {
              await deps.refreshAuth?.();
              try { session = await deps.clientSession(plan.ttl); } catch (e) { s.cause = armUnavailable((e as Error).message) ? "unavailable" : "wake"; throw e; }
              s.session_minted_paused = true;
            }
            const t0 = now();
            s.paused_ms = t0 - pausedAt;
            const marker = feltMarker(`${safe(ctx.tag)}-rm-${pause_s}-${arm}-${i}`);
            let wakeError = "";
            const wake = arm === "platform"
              ? deps.platformResume().then((r) => { s.answered_ms = now() - t0; s.server_timing = r.serverTiming; })
              : arm === "direct"
                ? directWake(session!, direct, deps.fetchImpl).then((r) => {
                    s.answered_ms = now() - t0;
                    s.direct_mode = r.mode;
                    if (r.status < 200 || r.status >= 300) throw new Error(`direct ${r.mode}: HTTP ${r.status}`);
                  })
                : Promise.resolve();
            // The app's reconnect after a wake: a new dial at the event, the chat attached again on it, and the send
            // held until then; the reply's clock runs from the event (send: the redial and the prompt are the wake).
            chat.wake();
            const until = t0 + FIRST_BYTE_DEADLINE_MS;
            const [felt] = await Promise.all([
              chat.waitAttached(until).then((ok) => ok
                ? feltAfterSend(chat, `${marker} back.`, FIRST_BYTE_DEADLINE_MS, floor ?? chat.held, t0)
                : { felt_ms: null, ack_ms: null, tries: 0, error: `the client's new dial did not attach the chat within ${FIRST_BYTE_DEADLINE_MS / 1000} s${chat.lastError ? ` (last: ${chat.lastError})` : ""}; dial: ${(chat.dial.events ?? []).slice(-4).join("; ")}`, attachFailed: true }),
              wake.catch((e: Error) => { wakeError = e.message; }),
            ]);
            s.first_byte_ms = felt.felt_ms;
            s.ack_ms = felt.ack_ms;
            if (wakeError) { s.error = wakeError; s.cause = "wake"; }
            if (felt.felt_ms === null) {
              s.error ||= `no reply within ${FIRST_BYTE_DEADLINE_MS / 1000} s${felt.error ? ` (${felt.error})` : ""}`;
              s.cause ??= "attachFailed" in felt ? "attach" : "reply";
            }
            if (deps.fillPct) {
              const t = await ctx.exec(`${ctx.guest}${TOUCH_COMMAND}`, 120_000);
              const ms = /@@touch (\d+)/.exec(t.stdout);
              s.page_in_ms = ms ? Number(ms[1]) : null;
            }
            const sent = now();
            const facts = await ctx.exec(`${ctx.guest}${wakeFactsCommand(t0 / 1000)}`, 60_000);
            const got = now();
            const w = parseWakeFacts(facts.stdout, t0, sent, got);
            Object.assign(s, { running_ms: w.running, registered_ms: w.registered, resumed_notify_ms: w.resumed, clock_offset_ms: w.offset });
            const after = parseAgents(facts.stdout);
            s.agent_same_process = before && after ? before.length > 0 && before.join(",") === after.join(",") : null;
            const outcome = s.first_byte_ms === null && s.cause === "attach" ? { ok: false, text: "not sent" } : await turnOutcome(ctx, marker, chat.session);
            if (!outcome.ok) s.turn = outcome.text;
            if (!outcome.ok && s.first_byte_ms !== null) { s.error ||= `turn: ${outcome.text}`; s.cause ??= "turn"; }
            s.restored = s.agent_same_process === null ? null : s.agent_same_process && outcome.ok && s.first_byte_ms !== null;
            floor = await feltBoundary(ctx, chat.session, floor ?? chat.held, outcome.ok);
            if (arm !== "platform") await deps.platformSync();
          } catch (e) {
            s.error ||= (e as Error).message;
            s.cause ??= "read";
            chat.wake();
            await deps.platformSync().catch(() => undefined);
          }
          log(`resume matrix: pause ${pause_s} s ${arm} #${i}: ${RESUME_POINTS.map((p) => `${p} ${s[`${p}_ms` as const] ?? "-"}`).join(", ")}${s.server_timing ? ` (server ${JSON.stringify(s.server_timing)})` : ""}${s.direct_mode ? ` [${s.direct_mode}]` : ""}${s.error ? ` ERROR ${s.error}` : ""}`);
          taken += 1;
          longest = Math.max(longest, now() - sampleStart);
          deps.onSample?.(s, out);
          if (s.cause === "unavailable") {
            // No sample of this arm can run on this machine: one says why, and no other is taken (no fail streak).
            unavailable.add(arm);
            live.delete(arm);
            stop({ pause_s, arm, after: 1, reason: `unavailable${deps.provider ? ` on ${deps.provider}` : ""}: ${s.error}` });
            if (!live.size) { ended = true; break; }
            continue;
          }
          armStreak.set(arm, s.error ? (armStreak.get(arm) ?? 0) + 1 : 0);
          cellStreak = s.error ? cellStreak + 1 : 0;
          if (cellStreak >= k) {
            stop({ pause_s, after: taken, reason: `${k} samples in a row failed; the last: ${s.error}` });
            ended = true;
            break;
          }
          if ((armStreak.get(arm) ?? 0) >= k) {
            live.delete(arm);
            stop({ pause_s, arm, after: out.filter((x) => x.pause_s === pause_s && x.arm === arm).length, reason: `${k} ${arm} samples in a row failed; the last: ${s.error}` });
            if (!live.size) { ended = true; break; }
          }
        }
      }
    }
  } finally {
    chat.stop();
  }
  return out;
}

/** Nearest-rank percentile of `xs` (sorted copy); null for none. */
export function percentile(xs: number[], p: number): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}

export type ResumeCell = { pause_s: number; arm: ResumeArm; point: ResumePoint; n: number; failed: number; p50: number | null; p95: number | null };

export function resumeCells(samples: ResumeSample[]): ResumeCell[] {
  const cells: ResumeCell[] = [];
  const pauses = [...new Set(samples.map((s) => s.pause_s))].sort((a, b) => a - b);
  for (const pause_s of pauses) {
    for (const arm of RESUME_ARMS) {
      const mine = samples.filter((s) => s.pause_s === pause_s && s.arm === arm);
      if (!mine.length) continue;
      for (const point of RESUME_POINTS) {
        const xs = mine.map((s) => s[`${point}_ms` as const]).filter((x): x is number => typeof x === "number");
        cells.push({ pause_s, arm, point, n: xs.length, failed: mine.filter((s) => s.error).length, p50: percentile(xs, 50), p95: percentile(xs, 95) });
      }
    }
  }
  return cells;
}

const sec = (ms: number | null) => (ms === null ? "-" : (ms / 1000).toFixed(2));

/**
 * The table: one row per pause length and arm, p50 / p95 seconds per point, n, and the gap the stop condition judges:
 * the arm's first-byte p95 less the direct arm's answered p95 (our whole path over the provider's own resume).
 */
export function resumeMarkdown(samples: ResumeSample[], stops: (ResumeStop & { machine?: string })[] = [], providers: string[] = []): string {
  const cells = resumeCells(samples);
  const get = (pause_s: number, arm: ResumeArm, point: ResumePoint) => cells.find((c) => c.pause_s === pause_s && c.arm === arm && c.point === point);
  const lines = [
    "| pause | arm | n | failed | restored | answered p50 / p95 | running p50 / p95 | registered p50 / p95 | first byte p50 / p95 | first byte p95 - direct answered p95 | page-in p50 / p95 |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
  ];
  for (const pause_s of [...new Set(cells.map((c) => c.pause_s))]) {
    const floor = get(pause_s, "direct", "answered")?.p95 ?? null;
    for (const arm of RESUME_ARMS) {
      const fb = get(pause_s, arm, "first_byte");
      if (!fb) continue;
      const total = samples.filter((s) => s.pause_s === pause_s && s.arm === arm).length;
      const pts = RESUME_POINTS.map((p) => { const c = get(pause_s, arm, p); return `${sec(c?.p50 ?? null)} / ${sec(c?.p95 ?? null)}`; });
      const gap = fb.p95 !== null && floor !== null ? sec(fb.p95 - floor) : "-";
      const pin = samples.filter((x) => x.pause_s === pause_s && x.arm === arm).map((x) => x.page_in_ms).filter((x): x is number => typeof x === "number");
      const mine = samples.filter((x) => x.pause_s === pause_s && x.arm === arm);
      const judged = mine.filter((x) => typeof x.restored === "boolean");
      const restored = judged.length ? `${judged.filter((x) => x.restored).length}/${judged.length}` : "-";
      lines.push(`| ${pause_s} s | ${arm} | ${total} | ${fb.failed} | ${restored} | ${pts.join(" | ")} | ${gap} | ${pin.length ? `${sec(percentile(pin, 50))} / ${sec(percentile(pin, 95))}` : "-"} |`);
    }
  }
  const stopped = stops.map((x) => `- ${x.pause_s} s${x.arm ? ` ${x.arm}` : ""}${x.machine ? ` (${x.machine})` : ""}: stopped after ${x.after} sample(s): ${x.reason}`);
  // Each arm's errors, so a row of failures says why without the job log.
  const errs: string[] = [];
  for (const pause_s of [...new Set(samples.map((x) => x.pause_s))].sort((a, b) => a - b)) {
    for (const arm of RESUME_ARMS) {
      const counts = new Map<string, number>();
      for (const x of samples) if (x.pause_s === pause_s && x.arm === arm && x.error) { const k = `${x.cause ? `[${x.cause}] ` : ""}${x.error}`; counts.set(k, (counts.get(k) ?? 0) + 1); }
      for (const [e, c] of [...counts].sort((a, b) => b[1] - a[1]).slice(0, 3)) errs.push(`- ${pause_s} s ${arm}: ${c}x ${e.slice(0, 300)}`);
    }
  }
  const extra = `${stopped.length ? `\n\nStopped early:\n\n${stopped.join("\n")}` : ""}${errs.length ? `\n\nErrors:\n\n${errs.join("\n")}` : ""}`;
  const turns = new Map<string, number>();
  for (const x of samples) if (x.turn) turns.set(`${x.pause_s} s ${x.arm}: ${x.turn.slice(0, 200)}`, (turns.get(`${x.pause_s} s ${x.arm}: ${x.turn.slice(0, 200)}`) ?? 0) + 1);
  const turnLines = [...turns].map(([t, c]) => `- ${t} (${c}x)`);
  const fill = [...new Set(samples.map((x) => x.fill_mib).filter((x): x is number => typeof x === "number"))];
  const head = `${providers.length ? `Provider: ${[...new Set(providers)].join(", ")}. ` : ""}${fill.length ? `Resident through each pause: ${fill.join(", ")} MiB (--resume-fill). ` : ""}`;
  return `${head ? `${head}\n\n` : ""}${lines.join("\n")}${extra}${turnLines.length ? `\n\nTurns that did not complete:\n\n${turnLines.join("\n")}` : ""}\n\nrestored: samples whose agent processes were the same before the pause and after the wake and whose turn completed, of those read. Causes: pause (did not land or hold), unavailable, wake (the resume call), attach (the client's new dial did not attach the chat), reply, turn, read.\n\nSeconds from the wake's event. answered: the resume call's answer (send: none). running: the guest's first tick after the pause. registered: the relay registration line. first byte: the agent reply's first record on the client. page-in: with --resume-fill, the guest's walk over its held memory after the reply (cold pages load on first touch; about 0.85 s per GiB in hq#17877). n counts samples; a point's p50/p95 uses the samples that reached it.\n`;
}

if (import.meta.main && process.argv[2] === "aggregate") {
  const args = process.argv.slice(3);
  const mdAt = args.indexOf("--md");
  const md = mdAt >= 0 ? args[mdAt + 1] : undefined;
  const files = args.filter((a, k) => a !== "--md" && k !== mdAt + 1);
  const runs = files.map((f) => JSON.parse(readFileSync(f, "utf8")));
  const samples: ResumeSample[] = runs.flatMap((j) => (Array.isArray(j) ? j : j.samples ?? []));
  const stops: ResumeStop[] = runs.flatMap((j) => (Array.isArray(j) ? [] : (j.stops ?? []).map((x: ResumeStop) => ({ ...x, machine: j.machine }))));
  const table = resumeMarkdown(samples, stops, runs.flatMap((j) => (typeof j?.provider === "string" ? [j.provider] : [])));
  if (md) writeFileSync(md, table);
  console.log(table);
}
