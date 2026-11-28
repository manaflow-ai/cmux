/**
 * Wake-to-first-echo (cloud-journey.ts --wake-echo N, hq#21300): one Cloud machine paused and woken N times by the
 * platform (cloud.machine.pause, a short hold after it reads `paused`, cloud.machine.start). A guest-side probe
 * (wake-echo-probe.py, kept alive across the pauses) marks, on the guest's wall clock, when the guest runs again,
 * when it first reaches the network, when a person-kind client attaches to a terminal of the guest's cmux-tui
 * daemon, and when one typed character's echo comes back. The runner puts the guest's marks on its own clock by an
 * offset (the min-RTT midpoint of a few `date` execs after the wake) and cuts phases, in runner ms:
 *
 *   wake_at       the cloud.machine.start call sent
 *   restore       resumed_at - wake_at              (resumed_at: the probe's first tick after the pause's gap)
 *   net_up        net_up_at - resumed_at            (first successful TCP connect to the platform host's address,
 *                                                    resolved at setup; the name's own resolve is the dns mark)
 *   pty_attach    pty_attach_at - resumed_at        (the daemon is a local unix socket: it runs beside net_up, not
 *                                                    after it, so both count from resumed_at)
 *   echo          echo_at - max(input_at, pty_attach_at)
 *   total         echo_at - wake_at
 *
 * A cycle that fails counts apart (with its cause, causeOf); percentiles are over the cycles that echoed, with n.
 * Before each pause the machine settles out of a transition (pausing, starting) by a deadline, so a cycle never
 * pauses a machine still in flight; the run sets idle_seconds 0 so the platform's own idle pause does not race it.
 */
import { readFileSync } from "node:fs";
import { awaitPaused, percentile } from "./cloud-resume-matrix.ts";

export const PHASES = ["restore", "net_up", "pty_attach", "echo", "total"] as const;
export type Phase = (typeof PHASES)[number];

export const WAKE_DIR = "/tmp/wake-echo";
export const PROBE_SOURCE = () => readFileSync(new URL("./wake-echo-probe.py", import.meta.url), "utf8");

export type Exec = (command: string, timeoutMs?: number) => Promise<{ code: number; stdout: string; stderr: string }>;

export type PauseAnswer = { status: number; body: any };
export type PauseResult = number | { pausedMs: number; warnings?: string[] };

export type GuestMarks = {
  prev_wall?: number; resumed_wall?: number; wall_gap?: number; mono_gap?: number;
  net_up_at?: number; dns_at?: number; conn_at?: number; pty_attach_at?: number; input_at?: number; echo_at?: number; echo_any_at?: number;
  error?: string; marker?: string;
  daemon?: { pid: number | null; start: number | null };
  surface_lost?: Record<string, unknown>;
};

type StartAttempt = { sent_at_ms: number; answered_at_ms: number; http_status: number; machine_status: string | null; timing_ms: Record<string, number> };

export type WakeCycle = {
  i: number;
  ok: boolean;
  error: string;
  at: string;
  paused_ms: number | null;
  answered_ms: number | null;
  first_exec_ms: number | null;
  offset_ms: number | null;
  offset_rtt_ms: number | null;
  offset_pre_ms: number | null;
  /** Runner-clock ms from wake_at to each guest mark. */
  marks_ms: Partial<Record<"resumed" | "net_up" | "dns" | "pty_attach" | "input" | "echo" | "echo_any", number>>;
  phases: Partial<Record<Phase, number>>;
  warnings: string[];
  guest: GuestMarks | null;
  state_json: boolean;
  state_wake: unknown;
  start_retries?: string[];
  start_attempts?: StartAttempt[];
};

/** Phases from marks already on the runner clock, as ms after wake_at (null: not marked). */
export function phasesOf(m: WakeCycle["marks_ms"]): { phases: Partial<Record<Phase, number>>; warnings: string[] } {
  const phases: Partial<Record<Phase, number>> = {};
  const warnings: string[] = [];
  const { resumed, net_up, pty_attach, input, echo } = m;
  if (resumed !== undefined) phases.restore = resumed;
  if (resumed !== undefined && net_up !== undefined) phases.net_up = net_up - resumed;
  if (resumed !== undefined && pty_attach !== undefined) phases.pty_attach = pty_attach - resumed;
  if (pty_attach !== undefined && echo !== undefined) phases.echo = echo - Math.max(input ?? pty_attach, pty_attach);
  if (echo !== undefined) phases.total = echo;
  for (const [k, v] of Object.entries(phases)) if (v < 0) warnings.push(`${k} ${Math.round(v)} ms is negative (clock offset error)`);
  return { phases, warnings };
}

/** A failed cycle's cause, so failures group by it: a lost terminal is the daemon's (product), the rest the run's. */
export function causeOf(c: Pick<WakeCycle, "error" | "guest">): string {
  const e = c.error;
  if (c.guest?.surface_lost || /unknown surface/.test(e)) return c.guest?.surface_lost?.same_daemon === false ? "daemon restarted across the wake (product)" : "daemon lost the terminal across the wake (product)";
  if (/before the cycle|not_paused|pause did not land|operation_in_flight|did not settle/.test(e)) return "machine state";
  if (/before wake_at: not this wake/.test(e)) return "probe fired before the wake (harness)";
  if (/no probe result|clock offset|^exec: |vm_unavailable/.test(e)) return "guest unreachable";
  if (/guest probe: net|no TCP connect/.test(e)) return "guest network";
  if (/guest probe/.test(e)) return "guest probe";
  if (/cloud\.machine\.start|cloud\.machine\.pause/.test(e)) return "platform op";
  return "other";
}

export function summarize(cycles: WakeCycle[]) {
  const echoed = cycles.filter((c) => c.ok);
  const row = (p: Phase) => {
    const xs = echoed.map((c) => c.phases[p]).filter((x): x is number => typeof x === "number");
    return { phase: p, n: xs.length, p50: percentile(xs, 50), p95: percentile(xs, 95), max: xs.length ? Math.max(...xs) : null };
  };
  const rows = PHASES.map(row);
  const parts = rows.filter((r) => r.phase !== "total" && r.p95 !== null);
  const biggest = parts.length ? parts.reduce((a, b) => ((b.p95 ?? 0) > (a.p95 ?? 0) ? b : a)).phase : null;
  const causes: Record<string, number> = {};
  for (const c of cycles) if (!c.ok) causes[causeOf(c)] = (causes[causeOf(c)] ?? 0) + 1;
  return { cycles: cycles.length, echoed: echoed.length, failed: cycles.length - echoed.length, rows, biggest, causes };
}

/**
 * Wake on intent (cmux#55110, hq#21300): the app starts the wake at the person's intent (focus, a terminal shown, an
 * unlock) instead of at the first key, `lead` ms before that key. The hint changes when the start is sent, never the
 * wake itself, so each measured cycle gives its intent arm too, paired, with no extra machine: on a client-side timer
 * the key lands at wake_at + lead and its echo is seen at echo_at. Before the guest is ready the key waits in the client
 * and echoes at echo_at (key-to-echo = echo - lead); once it is ready the key's echo takes the cycle's own echo phase
 * (echo - input). So key-to-echo = echo - min(input, lead); lead 0 is the baseline (the typing prewarm wakes at the key):
 * echo - 0 = wake-to-first-echo.
 */
/** A prefetch A/B run's cycles carry `arm` (cmux#54915's artifacts); a plain run's cycles are all "off". */
export type PrefetchArm = "off" | "on";
const armOf = (c: WakeCycle): PrefetchArm => ((c as WakeCycle & { arm?: PrefetchArm }).arm ?? "off");
export const INTENT_TARGET_MS = 1000;
/** The leads each table shows: until hq#21300 has the app's own `wake hint outcome ... tag=used ... ms=` lines (the
 *  hint's resume to the first input, which is the lead), a sweep of plausible focus-to-first-key gaps. */
export const INTENT_LEADS_MS = [500, 1000, 2000, 4000];
/** Idle bound of a hint wake nobody used (cmux-cloud-handlers `wake_hint::IDLE_BOUND_MS`). */
export const INTENT_IDLE_BOUND_MS = 30_000;
export function keyToEcho(c: Pick<WakeCycle, "ok" | "marks_ms">, leadMs: number): number | null {
  const { echo, input } = c.marks_ms;
  if (!c.ok || echo === undefined || input === undefined) return null;
  return Math.round(echo - Math.min(input, Math.max(0, leadMs)));
}
/** The four arms (prefetch off/on x hint at lead 0 / `leadMs`) over cycles of a prefetch A/B run, n and p50/p95 each. */
export function intentArms(cycles: WakeCycle[], leadMs: number, targetMs = INTENT_TARGET_MS) {
  const arms = [
    { arm: "baseline", prefetch: "off" as PrefetchArm, lead: 0 },
    { arm: "prefetch", prefetch: "on" as PrefetchArm, lead: 0 },
    { arm: "wake-on-intent", prefetch: "off" as PrefetchArm, lead: leadMs },
    { arm: "both", prefetch: "on" as PrefetchArm, lead: leadMs },
  ];
  return arms.map((a) => {
    const xs = cycles.filter((c) => armOf(c) === a.prefetch).map((c) => keyToEcho(c, a.lead)).filter((x): x is number => x !== null);
    return { ...a, n: xs.length, p50: percentile(xs, 50), p95: percentile(xs, 95), under_target: xs.filter((x) => x <= targetMs).length };
  });
}
/**
 * What one false hint wake (no input within the bound, re-paused) costs, per measured cycle: the wait from the start's
 * answer to running (the bound counts from running), the bound, and the pause until it lands.
 */
export function falseWakeCost(cycles: WakeCycle[]) {
  const xs = cycles.filter((c) => c.ok && typeof c.phases.restore === "number" && c.answered_ms !== null && c.paused_ms !== null)
    .map((c) => Math.max(0, c.phases.restore! - c.answered_ms!) + INTENT_IDLE_BOUND_MS + c.paused_ms!);
  return { n: xs.length, p50: percentile(xs, 50), p95: percentile(xs, 95) };
}
export function intentMarkdown(cycles: WakeCycle[], leadsMs: number[], targetMs = INTENT_TARGET_MS): string {
  const f = (x: number | null) => (x === null ? "-" : (x / 1000).toFixed(2));
  const lines = ["### Wake on intent: key-to-echo by arm (client timer, paired cycles)", "", `Target ${f(targetMs)} s. Lead: the hint's start before the first key.`, "", "| lead | arm | n | p50 | p95 | under target |", "|---|---|---|---|---|---|"];
  for (const lead of leadsMs) for (const a of intentArms(cycles, lead, targetMs)) lines.push(`| ${f(lead)} | ${a.arm} | ${a.n} | ${f(a.p50)} | ${f(a.p95)} | ${a.under_target}/${a.n} |`);
  const cost = falseWakeCost(cycles);
  lines.push("", `A false wake (no input in ${INTENT_IDLE_BOUND_MS / 1000} s) costs ${f(cost.p50)} s awake p50, ${f(cost.p95)} s p95 (n ${cost.n}): wait to running + the bound + the pause.`);
  return `${lines.join("\n")}\n`;
}

export function wakeEchoMarkdown(cycles: WakeCycle[], meta: Record<string, unknown>): string {
  const s = summarize(cycles);
  const asked = typeof meta.asked === "number" ? meta.asked : null;
  const f = (x: number | null) => (x === null ? "-" : (x / 1000).toFixed(2));
  const lines = [
    `Machine ${meta.machine ?? "?"}, size ${JSON.stringify(meta.size ?? "?")}. ${s.cycles}${asked !== null && asked !== s.cycles ? ` of ${asked} asked` : ""} cycles: ${s.echoed} echoed, ${s.failed} failed (counted apart). Seconds, runner clock; percentiles over the ${s.echoed} that echoed.`,
    "",
    "| phase | n | p50 | p95 | max |",
    "|---|---|---|---|---|",
    ...s.rows.map((r) => `| ${r.phase === "total" ? "**wake-to-first-echo**" : r.phase} | ${r.n} | ${f(r.p50)} | ${f(r.p95)} | ${f(r.max)} |`),
    "",
    `Biggest phase by p95: **${s.biggest ?? "none"}**. state.json carried a wake block in ${cycles.filter((c) => c.state_wake != null).length} of ${cycles.length} cycles.`,
  ];
  lines.push("", intentMarkdown(cycles, INTENT_LEADS_MS).trimEnd());
  if (meta.stopped) lines.push("", `Stopped early: ${meta.stopped}.`);
  const bad = cycles.filter((c) => !c.ok);
  if (bad.length) {
    lines.push("", "Failures by cause:", ...Object.entries(s.causes).map(([k, v]) => `- ${k}: ${v}`));
    lines.push("", "Failed cycles:", ...bad.map((c) => `- #${c.i} (${causeOf(c)}): ${c.error}${c.guest?.surface_lost ? ` — evidence ${JSON.stringify(c.guest.surface_lost).slice(0, 600)}` : ""}`));
  }
  const warn = cycles.filter((c) => c.warnings.length);
  if (warn.length) lines.push("", "Warnings:", ...warn.map((c) => `- #${c.i}: ${c.warnings.join("; ")}`));
  return `${lines.join("\n")}\n`;
}

/** The guest's clock minus the runner's from `n` `date` execs: the min-RTT sample's midpoint offset. */
export async function clockOffset(exec: Exec, n = 4): Promise<{ offset: number; rtt: number } | null> {
  let best: { offset: number; rtt: number } | null = null;
  for (let k = 0; k < n; k++) {
    const t0 = Date.now();
    const r = await exec("date +%s%3N", 30_000).catch(() => null);
    const t1 = Date.now();
    const g = r && /^\d{13}$/m.exec(r.stdout)?.[0];
    if (!g) continue;
    const s = { offset: Number(g) - (t0 + t1) / 2, rtt: t1 - t0 };
    if (!best || s.rtt < best.rtt) best = s;
  }
  return best;
}

export type WakeEchoDeps = {
  exec: Exec;
  guest: string;
  netHost: string;
  netPort: number;
  /** pause call, then resolves once the machine reads paused (ms from the call to the read). */
  pause: () => Promise<PauseResult>;
  /** cloud.machine.start, answered; resolves with a note per retry it took (startWithRetry). */
  wake: (recordAttempt?: (attempt: StartAttempt) => void) => Promise<void | string[]>;
  status: (timeoutMs?: number) => Promise<string>;
  holdMs: number;
  deadlineAt?: number;
  failStreak?: number;
  log: (line: string) => void;
  onCycle: (all: WakeCycle[]) => void;
  /** Why the run stopped before n cycles (failure streak, deadline). */
  onStop?: (why: string) => void;
  settleMs?: number;
  sleep?: (ms: number) => Promise<void>;
};

const sleepMs = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const short = (s: string) => s.replace(/\s+/g, " ").slice(0, 300);

/**
 * Reconcile a pause whose accepted request has no terminal answer by reading the same machine until it is paused.
 * A non-200 answer, including an HTTP 503, remains a failed pause because acceptance was not established.
 */
export async function pauseWithReconciliation(
  request: () => Promise<PauseAnswer>,
  status: () => Promise<string>,
  startedAt: number,
  deadlineMs: number,
  now: () => number = Date.now,
  wait: (ms: number) => Promise<void> = sleepMs,
): Promise<{ pausedMs: number; warnings?: string[] }> {
  const answer = await request();
  const accepted = answer.status === 200 && answer.body?.ok === true;
  const indeterminate = answer.status === 200 && answer.body?.ok !== true
    && answer.body?.error?.code === "mutation.indeterminate"
    && answer.body?.error?.retryable === true;
  if (!accepted && !indeterminate) {
    const detail = short(JSON.stringify(answer.body?.error ?? answer.body));
    throw new Error(`cloud.machine.pause: HTTP ${answer.status} ${detail}`);
  }
  let pausedMs: number;
  try {
    pausedMs = await awaitPaused(status, startedAt, deadlineMs, now, wait);
  } catch (e) {
    if (indeterminate) {
      throw new Error(`${(e as Error).message} (pause response mutation.indeterminate; status reconciliation failed)`);
    }
    throw e;
  }
  return indeterminate
    ? { pausedMs, warnings: ["pause response mutation.indeterminate; reconciled by machine status"] }
    : { pausedMs };
}

/** Writes the probe to the guest and runs its setup (daemon socket, terminal, dry run). Returns the setup JSON. */
export async function setupProbe(d: Pick<WakeEchoDeps, "exec" | "guest" | "netHost" | "netPort" | "log">): Promise<Record<string, any>> {
  const b64 = Buffer.from(PROBE_SOURCE()).toString("base64");
  const w = await d.exec(`${d.guest}mkdir -p ${WAKE_DIR} && echo ${b64} | base64 -d > ${WAKE_DIR}/probe.py && echo wrote`, 60_000);
  if (!w.stdout.includes("wrote")) throw new Error(`probe write: ${short(w.stderr || w.stdout)}`);
  const r = await d.exec(`${d.guest}python3 ${WAKE_DIR}/probe.py setup ${WAKE_DIR} "$c" ${d.netHost} ${d.netPort} 2>&1`, 120_000);
  const line = /@@setup (\{.*\})/.exec(r.stdout)?.[1];
  if (!line) throw new Error(`probe setup printed no result: ${short(r.stdout + r.stderr)}`);
  const s = JSON.parse(line);
  d.log(`wake-echo setup: ${JSON.stringify(s).slice(0, 1500)}`);
  if (!s.ok) throw new Error(`probe setup failed: ${short(JSON.stringify(s))}`);
  return s;
}

const ENSURE_PROBE = `if ! [ -s ${WAKE_DIR}/pid ] || ! kill -0 "$(cat ${WAKE_DIR}/pid)" 2>/dev/null; then nohup setsid python3 ${WAKE_DIR}/probe.py run ${WAKE_DIR} >> ${WAKE_DIR}/probe.log 2>&1 < /dev/null & echo $! > ${WAKE_DIR}/pid; echo @@started; sleep 1; fi; echo "@@probe $(cat ${WAKE_DIR}/pid)"`;

const STEADY = new Set(["running", "paused"]);

export type StartAnswer = { status: number; body: any };

/**
 * cloud.machine.start until it lands, by a deadline. Run 45481652567 lost 5 of 50 cycles to two refusals that are
 * the platform's to settle, not the guest's: `mutation.indeterminate` (retryable; "retry with the same key": the same
 * key is sent again) and `not_paused` while the machine reads `pausing` right after cloud.machine.get read `paused`
 * (operation_in_flight: wait for it to settle, then a new key). Each retry is a note in the cycle's warnings, and
 * the cycle's wake_at stays the first call's, so the wait counts in restore.
 */
export async function startWithRetry(
  call: (key: string) => Promise<StartAnswer>,
  newKey: () => string,
  status: () => Promise<string>,
  deadlineMs: number,
  sleep: (ms: number) => Promise<void>,
  now: () => number = Date.now,
): Promise<string[]> {
  const notes: string[] = [];
  const t0 = now();
  let key = newKey();
  for (;;) {
    const r = await call(key);
    if (r.status === 200 && r.body?.ok === true) return notes;
    const err = r.body?.error ?? r.body;
    const what = `cloud.machine.start: HTTP ${r.status} ${short(typeof err === "string" ? err : JSON.stringify(err))}`;
    const code = String(err?.code ?? "");
    const pausing = code === "cloud.machine.not_paused" && err?.details?.state === "pausing";
    const retryable = r.status >= 500 || err?.retryable === true || pausing;
    if (!retryable || now() - t0 >= deadlineMs) throw new Error(notes.length ? `${what} (after ${notes.length} retries: ${notes.join("; ")})` : what);
    notes.push(`${code || `HTTP ${r.status}`} at ${now() - t0} ms`);
    if (pausing) {
      const st = await settle(status, Math.max(1_000, deadlineMs - (now() - t0)), sleep, now);
      if (st === "running") return notes;
      key = newKey();
    } else {
      await sleep(1_000);
    }
  }
}

/** Runs an exec until it answers (the guest can be unreachable for a moment after the machine reads running). */
async function execAnswered(d: WakeEchoDeps, command: string, deadlineMs: number, sleep: (ms: number) => Promise<void>) {
  const end = Date.now() + deadlineMs;
  for (;;) {
    try {
      return await d.exec(command, 60_000);
    } catch (e) {
      if (Date.now() >= end) throw e;
      await sleep(1_000);
    }
  }
}

/** Polls the machine's status until it reads running or paused (out of pausing, starting, ...), by a deadline. */
export async function settle(status: (timeoutMs?: number) => Promise<string>, deadlineMs: number, sleep: (ms: number) => Promise<void>, now: () => number = Date.now): Promise<string> {
  const end = now() + deadlineMs;
  let last = "unread";
  for (;;) {
    last = await status(Math.max(1, end - now())).catch((e: Error) => `unread (${e.message})`);
    if (STEADY.has(last)) return last;
    const remaining = end - now();
    if (remaining <= 0) throw new Error(`machine did not settle: read ${last} ${Math.round(deadlineMs / 1000)} s on`);
    await sleep(Math.min(500, remaining));
  }
}

/** Settles the machine, wakes it when it settled paused, and waits for running. */
async function ensureRunning(d: WakeEchoDeps, sleep: (ms: number) => Promise<void>): Promise<void> {
  const ms = d.settleMs ?? 180_000;
  if ((await settle(d.status, ms, sleep)) === "running") return;
  await d.wake();
  if ((await settle(d.status, ms, sleep)) !== "running") throw new Error("machine read paused after a start");
}

const marker = (i: number) => "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"[i % 62]!;

export async function runWakeEcho(d: WakeEchoDeps, n: number): Promise<WakeCycle[]> {
  const sleep = d.sleep ?? sleepMs;
  const cycles: WakeCycle[] = [];
  const streakMax = d.failStreak ?? 3;
  for (let i = 0; i < n; i++) {
    if (d.deadlineAt && Date.now() > d.deadlineAt - 150_000) { d.log(`wake-echo: deadline near, stopping after ${i} cycles`); d.onStop?.(`deadline near after ${i} of ${n} cycles`); break; }
    const c: WakeCycle = { i, ok: false, error: "", at: new Date().toISOString(), paused_ms: null, answered_ms: null, first_exec_ms: null, offset_ms: null, offset_rtt_ms: null, offset_pre_ms: null, marks_ms: {}, phases: {}, warnings: [], guest: null, state_json: false, state_wake: null };
    cycles.push(c);
    try {
      // A machine still pausing (or starting) from the last cycle settles first; one that settled paused is woken.
      await ensureRunning(d, sleep);
      const arm = await execAnswered(d, `${d.guest}rm -f ${WAKE_DIR}/result.${i}.json; echo '{"seq":${i},"marker":"${marker(i)}","min_gap_ms":${Math.max(0, d.holdMs - 500)}}' > ${WAKE_DIR}/arm; ${ENSURE_PROBE}`, 120_000, sleep);
      if (!arm.stdout.includes("@@probe")) throw new Error(`arm: ${short(arm.stderr || arm.stdout)}`);
      c.offset_pre_ms = (await clockOffset(d.exec, 2))?.offset ?? null;
      const pause = await d.pause();
      if (typeof pause === "number") c.paused_ms = pause;
      else {
        c.paused_ms = pause.pausedMs;
        c.warnings.push(...(pause.warnings ?? []));
      }
      await sleep(d.holdMs);
      const wakeAt = Date.now();
      const retries = await d.wake((attempt) => (c.start_attempts ??= []).push(attempt));
      c.answered_ms = Date.now() - wakeAt;
      if (retries && retries.length) { c.start_retries = retries; c.warnings.push(`start retried: ${retries.join("; ")}`); }
      // Read the result back: exec polls (the guest may not answer yet) until the probe's file is there.
      const end = wakeAt + 150_000;
      let out = "";
      for (;;) {
        const r = await d.exec(`cat ${WAKE_DIR}/result.${i}.json 2>/dev/null; echo; echo "@@done"`, 20_000).catch(() => null);
        if (r && c.first_exec_ms === null) c.first_exec_ms = Date.now() - wakeAt;
        if (r && r.stdout.includes("{")) { out = r.stdout; break; }
        if (Date.now() > end) break;
        await sleep(1000);
      }
      if (!out) {
        const tail = await d.exec(`${d.guest}tail -n 5 ${WAKE_DIR}/probe.log ${WAKE_DIR}/gaps.log 2>&1`, 20_000).catch(() => null);
        throw new Error(`no probe result 150 s after wake_at (exec first answered ${c.first_exec_ms ?? "never"} ms); probe/gap logs: ${short(tail?.stdout ?? "unread")}`);
      }
      const g: GuestMarks = JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1));
      c.guest = g;
      const off = await clockOffset(d.exec, 4);
      if (!off) throw new Error("clock offset: no exec answered");
      c.offset_ms = Math.round(off.offset);
      c.offset_rtt_ms = off.rtt;
      if (c.offset_pre_ms !== null && Math.abs(c.offset_pre_ms - off.offset) > 100) c.warnings.push(`guest clock moved ${Math.round(off.offset - c.offset_pre_ms)} ms between pre-pause and post-wake offsets`);
      const rel = (x: number | undefined) => (x === undefined ? undefined : Math.round(x - off.offset - wakeAt));
      const mm = c.marks_ms;
      for (const [k, v] of [["resumed", g.resumed_wall], ["net_up", g.net_up_at], ["dns", g.dns_at], ["pty_attach", g.pty_attach_at], ["input", g.input_at], ["echo", g.echo_at], ["echo_any", g.echo_any_at]] as const) {
        const r = rel(v);
        if (r !== undefined) mm[k] = r;
      }
      const p = phasesOf(mm);
      c.phases = p.phases;
      c.warnings.push(...p.warnings);
      // The guest ran again before the start was sent: the probe measured a stall, not this wake. Not an echo.
      const early = mm.resumed !== undefined && mm.resumed < -2000 ? `the probe's gap ended ${-mm.resumed} ms before wake_at: not this wake` : "";
      const st = await d.exec(`cat /run/cmux-vm-agent/state.json 2>/dev/null || sudo -n cat /run/cmux-vm-agent/state.json 2>/dev/null; true`, 20_000).catch(() => null);
      try {
        const sj = st && st.stdout.includes("{") ? JSON.parse(st.stdout.slice(st.stdout.indexOf("{"))) : null;
        c.state_json = sj !== null;
        c.state_wake = sj?.wake ?? null;
      } catch { c.state_json = false; }
      if (early) throw new Error(early);
      if (g.error) throw new Error(`guest probe: ${g.error}`);
      if (g.echo_at === undefined) throw new Error("the probe marked no echo");
      c.ok = true;
    } catch (e) {
      c.error = short((e as Error).message ?? String(e));
      d.log(`wake-echo #${i} failed: ${c.error}`);
      // The next cycle needs a running machine: bring it back before anything else.
      try {
        await ensureRunning(d, sleep);
      } catch (e2) { d.log(`wake-echo #${i} recovery: ${short((e2 as Error).message ?? String(e2))}`); }
    }
    d.log(`wake-echo #${i}: ${c.ok ? "ok" : "FAIL"} ${JSON.stringify(c.phases)}${c.warnings.length ? ` warnings ${c.warnings.join("; ")}` : ""}`);
    d.onCycle(cycles);
    if (cycles.length >= streakMax && cycles.slice(-streakMax).every((x) => !x.ok)) { d.log(`wake-echo: ${streakMax} failed cycles in a row, stopping`); d.onStop?.(`${streakMax} failed cycles in a row after ${cycles.length} of ${n}`); break; }
  }
  return cycles;
}

export { awaitPaused };

// `bun scripts/cmux-next/cloud-wake-echo.ts intent wake-echo.json... [--lead MS]...`: the wake-on-intent table over runs'
// artifacts (cycles pooled), with no machine.
if (import.meta.main && process.argv[2] === "intent") {
  const args = process.argv.slice(3);
  const leads: number[] = [];
  const files: string[] = [];
  for (let i = 0; i < args.length; i++) if (args[i] === "--lead") leads.push(Number(args[++i])); else files.push(args[i]!);
  const cycles = files.flatMap((f) => (JSON.parse(readFileSync(f, "utf8")).cycles ?? []) as WakeCycle[]);
  process.stdout.write(intentMarkdown(cycles, leads.length ? leads : INTENT_LEADS_MS));
}
