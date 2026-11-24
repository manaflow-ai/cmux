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
 *
 * Each cycle keeps cloud.machine.start's Server-Timing (cmux-platform#1797: provider, vmapi, pre, finish, total), so
 * a slow restore splits into the provider's call and the platform's own time (`ours` = total - provider).
 *
 * --wake-echo-prefetch BIN (hq#21300): an A/B of the working-set prefetch (cmux-tui/crates/cmux-resume-prefetch). The
 * static binary goes to the guest at setup; every cycle records a plan before its pause, and even cycles are the `on`
 * arm: the probe runs the prefetch at the first tick after the gap, beside the sequence (as cmux-host's Cloud agent
 * runs it beside its wake work). Odd cycles are `off`. Tables split by arm.
 */
import { readFileSync } from "node:fs";
import { awaitPaused, parseServerTiming, percentile } from "./cloud-resume-matrix.ts";

export const PHASES = ["restore", "net_up", "pty_attach", "echo", "total"] as const;
export type Phase = (typeof PHASES)[number];

export const WAKE_DIR = "/tmp/wake-echo";
export const PROBE_SOURCE = () => readFileSync(new URL("./wake-echo-probe.py", import.meta.url), "utf8");

export type Exec = (command: string, timeoutMs?: number) => Promise<{ code: number; stdout: string; stderr: string }>;

export type GuestMarks = {
  prev_wall?: number; resumed_wall?: number; wall_gap?: number; mono_gap?: number;
  net_up_at?: number; dns_at?: number; conn_at?: number; pty_attach_at?: number; input_at?: number; echo_at?: number; echo_any_at?: number;
  error?: string; marker?: string;
  /** The on arm's prefetch, as the binary printed it ({planned,touched,stale_procs,threads,ms,cut}) or {error}. */
  prefetch?: Record<string, unknown>;
  daemon?: { pid: number | null; start: number | null };
  surface_lost?: Record<string, unknown>;
};

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
  /** cloud.machine.start's Server-Timing, ms by name (the last answer's when it was retried). */
  server_timing?: Record<string, number> | null;
  /** The prefetch A/B arm (--wake-echo-prefetch); absent without it. */
  arm?: Arm;
  /** The plan recorded before this cycle's pause ({procs, pages}). */
  plan?: Record<string, unknown> | null;
};

export type Arm = "on" | "off";
export const armOf = (i: number): Arm => (i % 2 === 0 ? "on" : "off");
/** What `wake` answers: the retries it took and the landed answer's Server-Timing. */
export type WakeAnswer = { retries: string[]; serverTiming?: Record<string, number> | null };

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

/** Per-arm summaries (only when the run had arms) and the on arm's prefetch p50s. */
export function summarizeArms(cycles: WakeCycle[]) {
  const arms = [...new Set(cycles.map((c) => c.arm).filter((a): a is Arm => a !== undefined))].sort((a, b) => (a === "on" ? -1 : b === "on" ? 1 : 0));
  return arms.map((arm) => {
    const mine = cycles.filter((c) => c.arm === arm);
    const pf = mine.map((c) => c.guest?.prefetch).filter((x): x is Record<string, unknown> => !!x && typeof x.touched === "number");
    const nums = (k: string) => pf.map((x) => Number(x[k])).filter((x) => Number.isFinite(x));
    return { arm, ...summarize(mine), prefetch: pf.length ? { n: pf.length, pages_p50: percentile(nums("touched"), 50), ms_p50: percentile(nums("ms"), 50), ms_p95: percentile(nums("ms"), 95), cut: pf.filter((x) => x.cut === true).length } : null };
  });
}

/** Slow restores: the platform's own share of cloud.machine.start (total - provider) beside the restore. */
export const SLOW_RESTORE_MS = 3000;
export function serverTimingSplit(cycles: WakeCycle[]) {
  const timed = cycles.filter((c) => c.server_timing && typeof c.server_timing.total === "number");
  const ours = (c: WakeCycle) => (c.server_timing && typeof c.server_timing.provider === "number" && typeof c.server_timing.total === "number" ? c.server_timing.total - c.server_timing.provider : null);
  const names = [...new Set(timed.flatMap((c) => Object.keys(c.server_timing ?? {})))].sort();
  const p50 = Object.fromEntries(names.map((k) => [k, percentile(timed.map((c) => c.server_timing![k]).filter((x): x is number => typeof x === "number"), 50)]));
  const slow = cycles.filter((c) => (c.phases.restore ?? 0) >= SLOW_RESTORE_MS).map((c) => ({ i: c.i, restore: c.phases.restore!, answered: c.answered_ms, server_timing: c.server_timing ?? null, ours: ours(c) }));
  return { timed: timed.length, of: cycles.length, p50, slow };
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
  const arms = summarizeArms(cycles);
  if (arms.length) {
    lines.push("", "### By prefetch arm (even cycles on, odd off)", "", "| arm | phase | n | p50 | p95 | max |", "|---|---|---|---|---|---|");
    for (const a of arms) for (const r of a.rows) lines.push(`| ${a.arm} | ${r.phase === "total" ? "**wake-to-first-echo**" : r.phase} | ${r.n} | ${f(r.p50)} | ${f(r.p95)} | ${f(r.max)} |`);
    for (const a of arms) lines.push("", `${a.arm}: ${a.cycles} cycles, ${a.echoed} echoed.${a.prefetch ? ` Prefetch (n ${a.prefetch.n}): ${a.prefetch.pages_p50} pages p50, ${f(a.prefetch.ms_p50)} s p50, ${f(a.prefetch.ms_p95)} s p95, cut by the deadline ${a.prefetch.cut}.` : ""}`);
  }
  const st = serverTimingSplit(cycles);
  if (st.timed) {
    lines.push("", `### cloud.machine.start Server-Timing (${st.timed} of ${st.of} cycles)`, "", `p50 ms: ${Object.entries(st.p50).map(([k, v]) => `${k} ${v}`).join(", ")}.`);
    if (st.slow.length) {
      lines.push("", `Restores of ${SLOW_RESTORE_MS / 1000} s or more; ours = total - provider:`, "", "| cycle | restore | start answered | total | provider | ours | all |", "|---|---|---|---|---|---|---|");
      for (const r of st.slow) lines.push(`| #${r.i} | ${f(r.restore)} | ${f(r.answered)} | ${f(r.server_timing?.total ?? null)} | ${f(r.server_timing?.provider ?? null)} | ${f(r.ours)} | ${r.server_timing ? Object.entries(r.server_timing).map(([k, v]) => `${k} ${v}`).join(", ") : "-"} |`);
    }
  }
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
  pause: () => Promise<number>;
  /** cloud.machine.start, answered; resolves with a note per retry it took (startWithRetry). */
  wake: () => Promise<void | string[] | WakeAnswer>;
  /** The prefetcher's path on the guest (setupPrefetch): turns the A/B on. */
  prefetchBin?: string;
  status: () => Promise<string>;
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

/** Puts the static cmux-resume-prefetch on the guest (in chunks: one exec argument stays well under 128 KiB) and records a plan once. */
export async function setupPrefetch(d: Pick<WakeEchoDeps, "exec" | "guest" | "log">, binary: Buffer): Promise<{ bin: string; record: Record<string, any> }> {
  const bin = `${WAKE_DIR}/cmux-resume-prefetch`;
  const arch = await d.exec("uname -m", 30_000);
  if (arch.stdout.trim() !== "x86_64") throw new Error(`prefetch binary is x86_64, guest is ${short(arch.stdout)}`);
  const b64 = binary.toString("base64");
  const CHUNK = 64 * 1024;
  await d.exec(`mkdir -p ${WAKE_DIR} && : > ${bin}.b64`, 60_000);
  for (let at = 0; at < b64.length; at += CHUNK) {
    const r = await d.exec(`echo ${b64.slice(at, at + CHUNK)} >> ${bin}.b64 && echo ok`, 60_000);
    if (!r.stdout.includes("ok")) throw new Error(`prefetch upload at ${at}: ${short(r.stderr || r.stdout)}`);
  }
  const r = await d.exec(`base64 -d ${bin}.b64 > ${bin} && chmod +x ${bin} && rm -f ${bin}.b64 && ${RECORD(bin)}`, 120_000);
  const line = /\{.*\}/.exec(r.stdout)?.[0];
  if (!line) throw new Error(`prefetch record printed nothing: ${short(r.stdout + r.stderr)}`);
  const record = JSON.parse(line);
  d.log(`wake-echo prefetch: ${(binary.length / 1024).toFixed(0)} KiB uploaded; record ${JSON.stringify(record)}`);
  return { bin, record };
}

/** Root reads every process's page table; without sudo the plan holds this user's processes only. */
const RECORD = (bin: string) => `{ sudo -n ${bin} record ${WAKE_DIR}/plan.json 2>/dev/null || ${bin} record ${WAKE_DIR}/plan.json; }`;

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
export async function settle(status: () => Promise<string>, deadlineMs: number, sleep: (ms: number) => Promise<void>, now: () => number = Date.now): Promise<string> {
  const end = now() + deadlineMs;
  let last = "unread";
  for (;;) {
    last = await status().catch((e: Error) => `unread (${e.message})`);
    if (STEADY.has(last)) return last;
    if (now() >= end) throw new Error(`machine did not settle: read ${last} ${Math.round(deadlineMs / 1000)} s on`);
    await sleep(500);
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
    if (d.prefetchBin) c.arm = armOf(i);
    cycles.push(c);
    try {
      // A machine still pausing (or starting) from the last cycle settles first; one that settled paused is woken.
      await ensureRunning(d, sleep);
      // Both arms record the plan before the pause (the Cloud agent records 20 s after each resume); only `on` runs it.
      const record = d.prefetchBin ? `echo "@@plan $(${RECORD(d.prefetchBin)})"; ` : "";
      const armJson = JSON.stringify({ seq: i, marker: marker(i), ...(c.arm === "on" ? { prefetch: d.prefetchBin, plan: `${WAKE_DIR}/plan.json` } : {}) });
      const arm = await execAnswered(d, `${d.guest}rm -f ${WAKE_DIR}/result.${i}.json; ${record}echo '${armJson}' > ${WAKE_DIR}/arm; ${ENSURE_PROBE}`, 120_000, sleep);
      if (!arm.stdout.includes("@@probe")) throw new Error(`arm: ${short(arm.stderr || arm.stdout)}`);
      if (d.prefetchBin) {
        const pl = /@@plan (\{.*\})/.exec(arm.stdout)?.[1];
        c.plan = pl ? JSON.parse(pl) : null;
        if (!pl) c.warnings.push(`plan record printed nothing: ${short(arm.stdout)}`);
      }
      c.offset_pre_ms = (await clockOffset(d.exec, 2))?.offset ?? null;
      c.paused_ms = await d.pause();
      await sleep(d.holdMs);
      const wakeAt = Date.now();
      const woke = await d.wake();
      c.answered_ms = Date.now() - wakeAt;
      const retries = Array.isArray(woke) ? woke : woke ? woke.retries : undefined;
      if (woke && !Array.isArray(woke)) c.server_timing = woke.serverTiming ?? null;
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
      if (mm.resumed !== undefined && mm.resumed < -2000) c.warnings.push(`the probe's gap ended ${-mm.resumed} ms before wake_at: not this wake`);
      const st = await d.exec(`cat /run/cmux-vm-agent/state.json 2>/dev/null || sudo -n cat /run/cmux-vm-agent/state.json 2>/dev/null; true`, 20_000).catch(() => null);
      try {
        const sj = st && st.stdout.includes("{") ? JSON.parse(st.stdout.slice(st.stdout.indexOf("{"))) : null;
        c.state_json = sj !== null;
        c.state_wake = sj?.wake ?? null;
      } catch { c.state_json = false; }
      if (c.arm === "on" && !(g.prefetch && typeof g.prefetch.touched === "number")) c.warnings.push(`prefetch did not run: ${short(JSON.stringify(g.prefetch ?? null))}`);
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

export { awaitPaused, parseServerTiming };
