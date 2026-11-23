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
};

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

/** One exec after a wake: the guest's clock now, the ticker's gaps and the journal's relay and resume lines since `sinceS`. */
export function wakeFactsCommand(sinceS: number): string {
  return `echo "@@now $(date +%s%3N)"; sed 's/^/@@gap /' ${TICKER}/gaps 2>/dev/null | tail -n 50; `
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

/** The whole matrix on one machine: every pause length, n samples of every arm, interleaved. */
export async function runResumeMatrix(deps: ResumeDeps, pauses: number[], n: number, arms: ResumeArm[] = RESUME_ARMS): Promise<ResumeSample[]> {
  const { ctx } = deps;
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const log = deps.log ?? ctx.log ?? (() => undefined);
  const out: ResumeSample[] = [];
  const started = await ctx.exec(`${ctx.guest}${TICKER_START}`, 60_000);
  if (!/@@ticker \d+/.test(started.stdout)) throw new Error(`the guest ticker did not start: ${(started.stdout + started.stderr).slice(-200)}`);
  if (deps.fillPct) {
    const f = await ctx.exec(`${ctx.guest}${fillStartCommand(deps.fillPct)}`, 120_000);
    if (!/@@fill \d+/.test(f.stdout)) throw new Error(`the guest memory fill did not start: ${(f.stdout + f.stderr).slice(-200)}`);
    log(`resume matrix: holding ${Math.round(Number(/@@fill (\d+)/.exec(f.stdout)![1]) / 2 ** 20)} MiB resident (${deps.fillPct}% of MemTotal)`);
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
    for (const pause_s of pauses) {
      for (let i = 0; i < n; i++) {
        for (const arm of armOrder(arms, i)) {
          const s: ResumeSample = { pause_s, arm, i, machine: ctx.machine, at: new Date().toISOString(), paused_ms: null, answered_ms: null, running_ms: null, registered_ms: null, first_byte_ms: null, ack_ms: null, clock_offset_ms: null, error: "" };
          out.push(s);
          try {
            await deps.refreshAuth?.();
            // The client session is minted while the machine runs (minting one for a paused machine may wake it),
            // unless the hold outlasts any session the route gives.
            const plan = directSessionPlan(pause_s);
            let session = arm === "direct" && !plan.afterHold ? await deps.clientSession(plan.ttl) : null;
            await chat.caughtUp(chat.held, 30_000);
            await deps.pause();
            const pausedAt = now();
            await sleep(pause_s * 1000);
            if (arm === "direct" && plan.afterHold) {
              await deps.refreshAuth?.();
              session = await deps.clientSession(plan.ttl);
              s.session_minted_paused = true;
            }
            const t0 = now();
            s.paused_ms = t0 - pausedAt;
            const marker = feltMarker(`${safe(ctx.tag)}-rm-${pause_s}-${arm}-${i}`);
            const wake = arm === "platform"
              ? deps.platformResume().then((r) => { s.answered_ms = now() - t0; s.server_timing = r.serverTiming; })
              : arm === "direct"
                ? directWake(session!, direct, deps.fetchImpl).then((r) => {
                    s.answered_ms = now() - t0;
                    s.direct_mode = r.mode;
                    if (r.status < 200 || r.status >= 300) throw new Error(`direct ${r.mode}: HTTP ${r.status}`);
                  })
                : Promise.resolve();
            const [felt] = await Promise.all([
              feltAfterSend(chat, `${marker} back.`, FIRST_BYTE_DEADLINE_MS, floor ?? chat.held),
              wake.catch((e: Error) => { s.error = e.message; }),
            ]);
            s.first_byte_ms = felt.felt_ms;
            s.ack_ms = felt.ack_ms;
            if (felt.felt_ms === null) s.error ||= `no reply within ${FIRST_BYTE_DEADLINE_MS / 1000} s${felt.error ? ` (${felt.error})` : ""}`;
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
            const ended = (await turnOutcome(ctx, marker, chat.session)).ok;
            floor = await feltBoundary(ctx, chat.session, floor ?? chat.held, ended);
            if (arm !== "platform") await deps.platformSync();
          } catch (e) {
            s.error ||= (e as Error).message;
            await deps.platformSync().catch(() => undefined);
          }
          log(`resume matrix: pause ${pause_s} s ${arm} #${i}: ${RESUME_POINTS.map((p) => `${p} ${s[`${p}_ms` as const] ?? "-"}`).join(", ")}${s.server_timing ? ` (server ${JSON.stringify(s.server_timing)})` : ""}${s.direct_mode ? ` [${s.direct_mode}]` : ""}${s.error ? ` ERROR ${s.error}` : ""}`);
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
export function resumeMarkdown(samples: ResumeSample[]): string {
  const cells = resumeCells(samples);
  const get = (pause_s: number, arm: ResumeArm, point: ResumePoint) => cells.find((c) => c.pause_s === pause_s && c.arm === arm && c.point === point);
  const lines = [
    "| pause | arm | n | failed | answered p50 / p95 | running p50 / p95 | registered p50 / p95 | first byte p50 / p95 | first byte p95 - direct answered p95 | page-in p50 / p95 |",
    "|---|---|---|---|---|---|---|---|---|---|",
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
      lines.push(`| ${pause_s} s | ${arm} | ${total} | ${fb.failed} | ${pts.join(" | ")} | ${gap} | ${pin.length ? `${sec(percentile(pin, 50))} / ${sec(percentile(pin, 95))}` : "-"} |`);
    }
  }
  return `${lines.join("\n")}\n\nSeconds from the wake's event. answered: the resume call's answer (send: none). running: the guest's first tick after the pause. registered: the relay registration line. first byte: the agent reply's first record on the client. page-in: with --resume-fill, the guest's walk over its held memory after the reply (cold pages load on first touch; about 0.85 s per GiB in hq#17877). n counts samples; a point's p50/p95 uses the samples that reached it.\n`;
}

if (import.meta.main && process.argv[2] === "aggregate") {
  const args = process.argv.slice(3);
  const mdAt = args.indexOf("--md");
  const md = mdAt >= 0 ? args[mdAt + 1] : undefined;
  const files = args.filter((a, k) => a !== "--md" && k !== mdAt + 1);
  const samples: ResumeSample[] = files.flatMap((f) => {
    const j = JSON.parse(readFileSync(f, "utf8"));
    return Array.isArray(j) ? j : j.samples ?? [];
  });
  const table = resumeMarkdown(samples);
  if (md) writeFileSync(md, table);
  console.log(table);
}
