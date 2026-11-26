#!/usr/bin/env bun
/**
 * Pause-policy A/B on staging: how long a cmux Cloud machine stays awake under each pause policy for the same chat.
 *
 *   bun scripts/cmux-next/pause-ab.ts --backend staging --out /tmp/pab
 *   bun scripts/cmux-next/pause-ab.ts --arms turn_end,aggressive --per-arm 2 --turns 8 --seed 7 --gaps 20,45,90,180
 *
 * Signs in as the agent test account the way cloud-journey.ts does (CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD from the
 * environment or a KEY=value --credentials file, or --sign-in oidc in a GitHub Actions job), then for every arm creates
 * --per-arm machines named `pause-ab-<tag>-<arm>-<i>`, sets the arm with `cloud.machine.idle_policy.set {machine,
 * pause_policy}` and reads it back, and drives the same seeded chat on every machine. Pairs come up one after another
 * (the next pair's creates wait until this pair runs, and no pair starts after --bringup-budget minutes, default 25);
 * each pair drives its turns as soon as it runs, and a pair that cannot come up is skipped with its reason: --turns Claude turns
 * against the journey's model stub on the machine's loopback (`--model stub`, no real model), each followed by an
 * idle gap drawn from --gaps with seed --seed + i - 1 for pair i (machine i of every arm gets the same gaps, so each
 * pair differs only by its pause policy, and the pairs cover --per-arm gap schedules), then --tail seconds idle.
 *
 * Before a turn on a machine that is not running the harness sends `cloud.machine.start` (as the app's Send does) and
 * times start -> running: that is one resume and its latency.
 *
 * Awake and paused seconds come from the machine's own platform record: `cloud.machine.get` status, read every
 * --poll seconds (default 5) from the first turn to the end of the tail. Awake is every status but `paused`
 * (`pausing` counts as awake: the VM still runs). The resolution is the poll interval. The account-wide
 * `cloud.plan.get` usage.vm_hours_used_by_you delta over the run is recorded as a cross-check only (it covers every
 * machine of the account, not just these).
 *
 * Per machine it also records the daemon's capabilities as the platform stored them from its last status report
 * (`cloud.machine.connect_info` daemon.capabilities: is `activity-turn-end` advertised?), the guest's build commit
 * (`sudo -n /opt/cmux/current/bin/cmux host update status --json`, start and end: binary, applied commit, channel commit, updater outcome) and the effective pause policy (a refused `turn_end` falls back to
 * `aggressive` with policy_refused set).
 *
 * The model stub listens on loopback. cmux-host's workload probe (cloud/workload.rs) counts any listening socket as
 * work that keeps a machine awake unless its owner's `comm` (/proc/<pid>/stat) is a system process. Run 45787132980
 * showed the stub's comm is `python3` even through the `cmux-tui-pab-stub` link (ss agrees), so both arms were kept by
 * {"why":"workload","ports":[<stub port>]} at every gap. As the cloud journey's idle walk does (cmux#58030), the drill
 * stops the stub after each reply (stubStop: only the pid its launch recorded, while that pid still runs it) and starts
 * it again on the same port at the front of the exec that carries the next message (stubRestart). It stands in for a
 * remote model endpoint, which a real chat has off the machine.
 * At each gap's end the drill reads the host's idle decision (`cloud.machine.get`: paused, or idleHeldBy's clock and
 * `idle_kept` reason with ports) and, when the machine is awake, the guest's listeners with their owners, so a run
 * that never pauses names what kept it awake (summary.md "Idle decision per gap", the "idle decision per gap" step).
 *
 * Output (--out DIR): pause-ab.json (every machine's timeline, turns, resumes) and summary.md (one table row per arm:
 * awake s, paused s, resumes, mean resume ms), plus journey.json (steps). Every machine this run created is deleted
 * at the end, pass or fail; machines named `pause-ab-<tag>-...` whose tag is more than 90 minutes old (PAUSE_AB_STALE_MS, a killed run's,
 * active or not: its stub keeps it active) are swept before create, and each machine is created with ttl_seconds at that
 * cutoff so the platform deletes it even when the job dies first. Any other name is never touched. A machine the provider
 * fails at create (cloud.provider.unavailable, no host, never active) gets one replacement, recorded in the "running"
 * step and in pause-ab.json `replaced`. Exit 0 only when no step failed.
 */
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  Api, CHAT_START_SIZE, JOURNEY_STUB_SCRIPT, Journey, MODEL_STUB_PY, STACK, directExec, http,
  idleHeldBy, launchCredentialStartProgram, listAllMachines, oidcSignIn, passwordSignIn, readEnvFile, resolveBackend, sharedCleanup,
  type Exec,
} from "./cloud-journey.ts";

const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);

/** What a machine on the drill account is, by status and by name shape (segments holding a digit become `*`), so a
 * sweep line says whether the account's machines are live drills, failed leftovers or someone else's. */
export function accountCensus(rows: any[], nowMs: number): string {
  const by = (key: (r: any) => string) => {
    const n = new Map<string, number>();
    for (const r of rows) n.set(key(r), (n.get(key(r)) ?? 0) + 1);
    return [...n].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([k, c]) => `${k}=${c}`).join(" ");
  };
  const shape = (r: any) => (typeof r?.name === "string" && r.name ? r.name.split("-").map((x: string) => (/\d/.test(x) ? "*" : x)).join("-") : "(unnamed)");
  const age = (r: any) => {
    const t = typeof r?.created_at === "number" ? r.created_at : Date.parse(r?.created_at ?? "");
    if (!Number.isFinite(t)) return "age?";
    const h = (nowMs - (t < 1e12 ? t * 1000 : t)) / 3_600_000;
    return h < 1 ? "<1h" : h < 24 ? "<1d" : h < 168 ? "<7d" : ">=7d";
  };
  const failed = rows.filter((r) => r?.status === "failed");
  const cause = (r: any) => {
    const e = r?.error;
    const text = e && typeof e === "object" ? `${e.code ?? "?"} ${e.message ?? ""}`.trim() : "no error";
    return text.replace(/\b(vm|snap|team|user)_[0-9a-z]+/gi, "$1_*").replace(/\s+/g, " ").slice(0, 120);
  };
  const causes = new Map<string, number>();
  for (const r of failed) causes.set(cause(r), (causes.get(cause(r)) ?? 0) + 1);
  const failedBy = failed.length ? `; failed by error: ${[...causes].sort((a, b) => b[1] - a[1]).map(([k, c]) => `${k}=${c}`).join(" | ")}` : "";
  return `status: ${by((r) => String(r?.status ?? "?"))}; age: ${by(age)}; names: ${by(shape)}${failedBy}`;
}

/** A machine the provider failed at create, after the platform's retry window: no host, never active, and the
 * provider's own transient code. Anything else (a refusal, an image, a quota) is not retried by the drill. */
export function failedCreateIsTransient(m: any): boolean {
  return m?.status === "failed" && m?.error?.code === "cloud.provider.unavailable" && !m?.host && m?.last_active_at == null;
}

/** A failed machine's own fields minus who and what it is, whole, so the reason it failed is not cut at 300 chars. */
export function failureFacts(m: any): string {
  const { id: _i, team: _t, creator: _c, name: _n, size: _s, ...rest } = m ?? {};
  return JSON.stringify(rest).slice(0, 2000);
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const argValue = (flag: string, argv: string[]): string | undefined => {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
};

export const TURN_END_CAPABILITY = "activity-turn-end";
export const NAME_PREFIX = "pause-ab-";

/**
 * The guest capability an arm's policy needs before it differs from another arm. Pause.ts gives turn_end its 5 s
 * window only to a report advertising activity-turn-end (cmux#54684); without it the arm runs aggressive's 60 s and
 * the A/B measures one policy twice. Run 45829884458 did exactly that: staging's boot list ended at
 * cloud-native-auto-67d01201 (cmux-tui before #54684) because the 6fde033d roll was rolled back at 04:09Z and
 * re-appended only at 13:37Z, and the guest updater applies the channel build only to an idle, unattached machine,
 * which a driven machine never is. So an arm on a guest without its capability fails the run, naming the build.
 */
export const ARM_NEEDS: Record<string, string> = { turn_end: TURN_END_CAPABILITY };

/** Machines whose arm needs a capability their guest did not advertise at the first turn's end. */
export function missingCapability(results: Pick<MachineResult, "arm" | "name" | "capabilities" | "daemon_version">[]): string[] {
  return results.flatMap((r) => {
    const need = ARM_NEEDS[r.arm];
    if (!need || r.capabilities?.includes(need)) return [];
    return [`${r.name}: arm ${r.arm} needs ${need}, guest daemon ${r.daemon_version ?? "unknown"} advertised ${r.capabilities ? r.capabilities.join(",") || "none" : "nothing readable"}`];
  });
}

/** mulberry32: a small seeded PRNG, so every run with the same seed draws the same gaps. */
export function seededRandom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** The idle gap after each of `turns` turns, in seconds, drawn from `choices` with `seed`. */
export function gapSchedule(seed: number, turns: number, choices: number[]): number[] {
  if (!choices.length) throw new Error("no gap choices");
  const rnd = seededRandom(seed);
  return Array.from({ length: turns }, () => choices[Math.floor(rnd() * choices.length)]);
}

export type Sample = { at: number; status: string };

/**
 * Awake and paused seconds from status samples between `start` and `end` (ms): each sample's status holds until the
 * next sample. Before the first sample in the window, the last sample before it holds (or the first sample's status).
 */
export function integrate(samples: Sample[], start: number, end: number): { awake_s: number; paused_s: number; pauses: number } {
  const sorted = [...samples].sort((a, b) => a.at - b.at);
  let awake = 0;
  let paused = 0;
  let pauses = 0;
  let prev: string | null = null;
  const before = sorted.filter((s) => s.at <= start).pop();
  let cur = before?.status ?? sorted.find((s) => s.at > start)?.status ?? null;
  let t = start;
  const add = (status: string | null, ms: number) => {
    if (status === null || ms <= 0) return;
    if (status === "paused") paused += ms; else awake += ms;
  };
  for (const s of sorted) {
    if (s.at <= start) { prev = s.status; continue; }
    if (s.at >= end) break;
    add(cur, s.at - t);
    if (s.status === "paused" && (prev ?? cur) !== "paused") pauses++;
    prev = s.status;
    cur = s.status;
    t = s.at;
  }
  add(cur, end - t);
  return { awake_s: Math.round(awake / 100) / 10, paused_s: Math.round(paused / 100) / 10, pauses };
}

export type MachineResult = {
  arm: string;
  name: string;
  /** Why the first machine of this slot was replaced (a transient failed create), or unset. */
  replaced?: string;
  id: string | null;
  effective_policy: string | null;
  policy_refused: string | null;
  /** The daemon block of the guest's last report (GUEST_REPORT_STATE), read after turn 1's reply. */
  capabilities: string[] | null;
  /** The row's daemon capabilities (cloud.machine.connect_info), kept apart from the report's. */
  bind_capabilities?: string[] | null;
  turn_end_advertised: boolean | null;
  daemon_version: string | null;
  guest_update_start: GuestUpdate | null;
  guest_update_end: GuestUpdate | null;
  /** The pair this machine belongs to (machine i of every arm), its seed and the gaps it drew. */
  pair: number;
  seed: number;
  gaps_s: number[];
  turns_ok: number;
  turns: { turn: number; gap_s: number; resumed: boolean; resume_ms: number | null; reply_ms: number | null; error?: string; wait_note?: string; kept?: string | null; listeners?: string | null; report?: string | null }[];
  /** The host's idle decision after the tail (idleHeldBy), read without touching the guest. */
  tail_kept: string | null;
  /** GUEST_RESOLVER_FACTS on the first exec that answered after a failed one, and at the end. */
  resolver_recovered?: string | null;
  resolver_end?: string | null;
  samples: Sample[];
  awake_s: number | null;
  paused_s: number | null;
  pauses: number | null;
  error: string | null;
  /** Why this machine's pair never drove a turn (its bring-up failed, or the bring-up budget ran out); left out of the arm rows. */
  skipped?: string;
  /** This machine's own sampling window: its pair starts when it is up, so windows differ by pair. */
  window?: { start: number; end: number };
};

export type ArmRow = {
  arm: string; machines: number; turn_end_advertised: string; awake_s: number; paused_s: number; awake_pct: number;
  resumes: number; mean_resume_ms: number | null; p50_resume_ms: number | null; p95_resume_ms: number | null;
  resume_failures: number; vm_unavailable: number; turns_ok: string;
};

/** Nearest-rank percentile of `values` (q in 0..1), null when empty. */
export function percentile(values: number[], q: number): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1))];
}

/** Turns on which the guest answered 502 vm_unavailable (cmux#58449): a turn, its report read or its listener read. */
export function vmUnavailableTurns(r: Pick<MachineResult, "turns">): number {
  return r.turns.filter((t) => [t.error, t.report, t.listeners].some((v) => typeof v === "string" && /vm_unavailable/.test(v))).length;
}

/** One row per arm: awake and paused seconds summed over its machines, resumes, and their mean latency. */
export function aggregate(results: MachineResult[], arms: string[]): ArmRow[] {
  return arms.map((arm) => {
    const ms = results.filter((r) => r.arm === arm && !r.skipped);
    const awake = ms.reduce((n, r) => n + (r.awake_s ?? 0), 0);
    const paused = ms.reduce((n, r) => n + (r.paused_s ?? 0), 0);
    const resumes = ms.flatMap((r) => r.turns.filter((t) => t.resumed));
    const timed = resumes.map((t) => t.resume_ms).filter((v): v is number => typeof v === "number");
    const p50 = percentile(timed, 0.5);
    const p95 = percentile(timed, 0.95);
    const adv = ms.filter((r) => r.turn_end_advertised === true).length;
    const turns = ms.reduce((n, r) => n + r.turns.length, 0);
    return {
      arm: ms[0]?.effective_policy && ms.every((r) => r.effective_policy === ms[0].effective_policy) && ms[0].effective_policy !== arm ? `${arm} (ran as ${ms[0].effective_policy})` : arm,
      machines: ms.length,
      turn_end_advertised: `${adv}/${ms.length}`,
      awake_s: Math.round(awake * 10) / 10,
      paused_s: Math.round(paused * 10) / 10,
      awake_pct: awake + paused > 0 ? Math.round((awake / (awake + paused)) * 1000) / 10 : 0,
      resumes: resumes.length,
      mean_resume_ms: timed.length ? Math.round(timed.reduce((a, b) => a + b, 0) / timed.length) : null,
      p50_resume_ms: p50,
      p95_resume_ms: p95,
      // A resume that never reached running (a start that did not take within 180 s).
      resume_failures: resumes.length - timed.length,
      vm_unavailable: ms.reduce((n, r) => n + vmUnavailableTurns(r), 0),
      turns_ok: `${ms.reduce((n, r) => n + r.turns_ok, 0)}/${turns}`,
    };
  });
}

export function markdownTable(rows: ArmRow[]): string {
  const head = "| arm | machines | activity-turn-end | awake s | paused s | awake % | resumes | mean resume ms | p50 resume ms | p95 resume ms | resume failures | 502 vm_unavailable turns | turns ok |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|";
  return [head, ...rows.map((r) => `| ${r.arm} | ${r.machines} | ${r.turn_end_advertised} | ${r.awake_s} | ${r.paused_s} | ${r.awake_pct} | ${r.resumes} | ${r.mean_resume_ms ?? "n/a"} | ${r.p50_resume_ms ?? "n/a"} | ${r.p95_resume_ms ?? "n/a"} | ${r.resume_failures} | ${r.vm_unavailable} | ${r.turns_ok} |`)].join("\n");
}

/** The pair numbers in order, each with its machines (one per arm): the drill brings pairs up one after another. */
/** The guest's `acp wait; acp last; @@werr` output: wait's exit code, the last reply, wait's stderr tail. */
export function parseWaitOutput(stdout: string): { code: string | undefined; text: string; werr: string } {
  const code = /@@wait (\d+)/.exec(stdout)?.[1];
  const werrAt = stdout.lastIndexOf("@@werr");
  const werr = werrAt >= 0 ? stdout.slice(werrAt + 6).trim() : "";
  const body = werrAt >= 0 ? stdout.slice(0, werrAt) : stdout;
  return { code, text: body.replace(/@@wait \d+\n?/, "").trim(), werr };
}

/** The status `acp --json history` lists for the turn whose prompt starts with MARKER, or null. */
export function historyTurnStatus(stdout: string, marker: string): string | null {
  try {
    const turns: any[] = JSON.parse(stdout.slice(stdout.indexOf("{"))).turns ?? [];
    const t = turns.find((x) => typeof x?.prompt === "string" && x.prompt.startsWith(marker));
    return typeof t?.status === "string" ? t.status : null;
  } catch {
    return null;
  }
}

/** Turn states that still owe a reply; any other listed status means the turn ended. */
const TURN_UNFINISHED = new Set(["running", "queued", "pending", "starting", "waiting"]);

/**
 * What one `acp wait` round means for a turn. Exit 0 with a reply is the reply. Exit 3 is wait's
 * own 20 s timeout: wait again. Any other exit (run 45869919450: exit 1 after a resume, with the
 * right reply already written) is a reply only when history lists this turn as ended and the
 * reply carries the stub nonce; else it is retried up to 3 times, then the turn fails with wait's stderr.
 */
export function waitVerdict(a: { code: string | undefined; text: string; werr: string; turnStatus: string | null; nonce: string; waitFails: number }):
  { kind: "reply"; note?: string } | { kind: "again" } | { kind: "retry" } | { kind: "fail"; error: string } {
  const hasNonce = a.text.includes(`Stub reply ${a.nonce}.`);
  if (a.code === "0" && a.text) return hasNonce ? { kind: "reply" } : { kind: "fail", error: `reply lacks the stub nonce: ${a.text.slice(-160)}` };
  if (!a.code || a.code === "0" || a.code === "3") return { kind: "again" };
  const why = `acp wait exit ${a.code}${a.werr ? `: ${a.werr.slice(-200)}` : ""}`;
  if (hasNonce && a.turnStatus && !TURN_UNFINISHED.has(a.turnStatus)) return { kind: "reply", note: `${why}; history lists the turn ${a.turnStatus}` };
  if (a.waitFails < 3) return { kind: "retry" };
  return { kind: "fail", error: `${why}; turn ${a.turnStatus ?? "not listed"}; last: ${a.text.slice(-160)}` };
}

export function pairsOf<T extends { pair: number }>(results: T[]): { pair: number; machines: T[] }[] {
  return [...new Set(results.map((r) => r.pair))].sort((a, b) => a - b).map((pair) => ({ pair, machines: results.filter((r) => r.pair === pair) }));
}

/** Run `fn` over `items` with at most `n` in flight (staging's VM API answers 503 under 20 concurrent mutations). */
export async function pool<T>(items: T[], n: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, Math.min(n, items.length)) }, async () => {
    while (next < items.length) await fn(items[next++]);
  }));
}

/** One row per pair: its seed and gaps, and each arm's paused seconds and resumes on that same schedule. */
export function pairTable(results: MachineResult[], arms: string[]): string {
  const pairs = [...new Set(results.map((r) => r.pair))].sort((a, b) => a - b);
  const head = `| pair | seed | gaps s | ${arms.map((a) => `${a} paused s / resumes`).join(" | ")} |\n|---|---|---|${arms.map(() => "---|").join("")}`;
  return [head, ...pairs.map((p) => {
    const ms = results.filter((r) => r.pair === p);
    const cell = (a: string) => {
      const r = ms.find((m) => m.arm === a);
      if (r?.skipped) return `skipped: ${r.skipped.replace(/\|/g, "\\|").slice(0, 120)}`;
      return r ? `${r.paused_s ?? "n/a"} / ${r.turns.filter((t) => t.resumed).length}${r.error ? " (error)" : ""}` : "n/a";
    };
    return `| ${p} | ${ms[0]?.seed ?? "?"} | ${(ms[0]?.gaps_s ?? []).join(",")} | ${arms.map(cell).join(" | ")} |`;
  })].join("\n");
}

/**
 * How old a pause-ab tag is before its machines count as left behind: the workflow's job stops at 80 minutes
 * (timeout-minutes in pause-ab.yml), so a tag 110 minutes old belongs to no live CI run. The cloud journey's 3 h
 * (STALE_JOURNEY_MS) let a killed run's machine (pause-ab-mwx9ibyh, 08:00Z) outlive the next run at 09:38Z.
 */
export const PAUSE_AB_STALE_MS = 110 * 60_000;

/** Machines an earlier pause-ab run left behind: our name shape, tag older than maxAgeMs, idle for an hour. */
export function stalePauseAbMachines(rows: any[], nowMs: number, maxAgeMs = PAUSE_AB_STALE_MS, kept?: string[]): { id: string; name: string; why: string }[] {
  const out: { id: string; name: string; why: string }[] = [];
  for (const r of rows) {
    const m = /^pause-ab-([0-9a-z]+)-[a-z_]+-\d+r?$/.exec(typeof r?.name === "string" ? r.name : "");
    if (!m) continue;
    const id = String(r.id ?? r.machine_id ?? "");
    const keep = (why: string) => kept?.push(`${id || "?"} ${r.name} ${why}`);
    if (r.status === "deleted" || r.status === "deleting") { keep(`status=${r.status}`); continue; }
    const started = parseInt(m[1], 36);
    if (!Number.isFinite(started) || started < Date.UTC(2020, 0, 1) || started > nowMs) { keep("tag is not a start time"); continue; }
    if (nowMs - started <= maxAgeMs) { keep(`started ${Math.round((nowMs - started) / 60_000)} min ago`); continue; }
    // No activity spare past the cutoff: a left-behind drill machine still runs the drill's own model stub, which
    // keeps it active for good (pause-ab-mwxbi2gl, 08:55Z, kept "active 0 min ago" by every sweep until 11:10Z).
    const active = typeof r.last_active_at === "number" ? `, active ${Math.round((nowMs - r.last_active_at) / 60_000)} min ago` : "";
    if (id) out.push({ id, name: r.name, why: `started ${Math.round((nowMs - started) / 60_000)} min ago${active}` });
    else keep("no id");
  }
  return out;
}

const STUB_DIR = "/home/cmux/.cmux";
const STUB_LINK = `${STUB_DIR}/cmux-tui-pab-stub`;
const STUB_PID = `${STUB_DIR}/pab-model-stub.pid`;

/**
 * Stops the model stub for an idle gap: its loopback listener is workload (comm `python3`) that holds the idle clock.
 * Only the pid its launch recorded, while that pid still runs pab-model-stub.py; prints `@@stopped PORT`.
 */
export function stubStop(dir = STUB_DIR): string {
  const d = `${dir}/pab-model-stub`;
  return (
    `p=$(cat ${d}.pid 2>/dev/null); ` +
    `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${d}.ready 2>/dev/null); ` +
    `{ [ -n "$p" ] && [ -n "$port" ] && grep -qa pab-model-stub.py "/proc/$p/cmdline" 2>/dev/null; } || { echo "@@nostub"; exit 1; }; ` +
    `kill "$p"; for i in $(seq 50); do [ -d "/proc/$p" ] || break; sleep 0.2; done; ` +
    `[ -d "/proc/$p" ] && { echo "@@stuck $p"; exit 1; }; echo "@@stopped $port"`
  );
}

/** The stub again on the port Claude Code's settings still name, as the front of the exec that sends the next message. */
export function stubRestart(port: number, nonce: string, dir = STUB_DIR): string {
  const d = `${dir}/pab-model-stub`;
  return (
    `rm -f ${d}.ready; (nohup ${dir}/cmux-tui-pab-stub ${d}.py --port ${port} --script ${d}.json --nonce ${shq(nonce)} --log ${d}.log --ready-file ${d}.ready >>${d}.log.out 2>&1 & echo $! >${d}.pid); ` +
    `for i in $(seq 50); do [ -s ${d}.ready ] && break; sleep 0.2; done; ` +
    `[ -s ${d}.ready ] || { echo "@@stub-down"; tail -5 ${d}.log.out; exit 1; }; `
  );
}

/** Starts the model stub (through the cmux-tui-named python3 link) and points Claude Code's settings at it. */
function stubStartCommand(nonce: string): string {
  const file = `${STUB_DIR}/pab-model-stub.py`;
  const script = `${STUB_DIR}/pab-model-stub.json`;
  const ready = `${STUB_DIR}/pab-model-stub.ready`;
  const log = `${STUB_DIR}/pab-model-stub.log`;
  return `mkdir -p ${STUB_DIR}; ln -sf "$(command -v python3)" ${STUB_LINK}; rm -f ${shq(ready)}; ` +
    `(nohup ${STUB_LINK} ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(log)} --ready-file ${shq(ready)} >${shq(log)}.out 2>&1 & echo $! >${STUB_PID}); ` +
    `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
    `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
    `[ -n "$port" ] && curl -fsS -m 2 "http://127.0.0.1:$port/__stub/info" | grep -q ${shq(nonce)} || { echo stub-down; tail -5 ${shq(log)}.out; exit 1; }; ` +
    `echo "@@port $port"; python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\np.parent.mkdir(parents=True, exist_ok=True)\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.write_text(json.dumps(c))\nprint('stub-ready')\nPY`;
}

// The guest updater's own status (cmux-host updater/role.rs `status --json`), as root: errors are kept, not hidden.
/** The guest's `cmux` (the `cmux host` surface of cmux-tui): the supervisor unit runs `/opt/cmux/current/bin/cmux host
 * run`, and sudo's secure_path has no `cmux` on it (run 45779107347: "sudo: cmux: command not found"). */
export const GUEST_CMUX = `cx=/opt/cmux/current/bin/cmux; [ -x "$cx" ] || cx=$(command -v cmux 2>/dev/null || echo /opt/cmux/current/bin/cmux); `;
const GUEST_UPDATE = `${GUEST_CMUX}out=$(sudo -n "$cx" host update status --json 2>&1); echo "@@exit $?"; printf '%s\n' "$out"`;

/** The guest's TCP listeners with their owners (comm, pid), for a gap the machine did not pause in: the workload rule
 * (cmux-host cloud/workload.rs) counts a LISTEN socket a non-system process owns, so this names which one held it. */
export const GUEST_LISTENERS = `{ sudo -n ss -ltnpH 2>/dev/null || ss -ltnpH; } | awk '{print $4, $6}' | head -n 20`;

/** The guest's resolver state and the journal of the units that rewrite it after a resume (cmux-dns-scope, #58163, and
 * systemd-resolved), DNS addresses and unit lines only, never a secret. Run 45836648280: on guest 011235083394 every
 * exec after a `starting` resume failed `cloud.provider.unavailable` for minutes (the provider powered it on in 710 ms;
 * hq#29284), where 67d01201 resumed 8/8. The provider's guest agent rewrites 61-freestyle-tls.conf and resolv.conf
 * after it resumes, and cmux-dns-scope.path reacts to both, so the drill reads them on the first exec that answers
 * after a failed one, and once more at the end. */
export const GUEST_RESOLVER_FACTS = [
  `echo "@@boot $(uptime -s 2>/dev/null)"`,
  `echo "@@edge"; ls -l --time-style=+%FT%T /etc/systemd/resolved.conf.d/ 2>&1 | tail -n +2; grep -h '^DNS' /etc/systemd/resolved.conf.d/61-freestyle-tls.conf 2>&1`,
  `echo "@@ours"; grep -h '^DNS' /run/systemd/resolved.conf.d/62-cmux-dns-scope.conf 2>&1`,
  `echo "@@resolv $(readlink /etc/resolv.conf || echo plain)"; grep -h '^nameserver' /etc/resolv.conf 2>&1 | head -n 3`,
  `echo "@@runs scope=$(sudo -n journalctl -b -q -u cmux-dns-scope.service 2>/dev/null | grep -c 'Started\\|Finished\\|Deactivated') resolved_starts=$(sudo -n journalctl -b -q -u systemd-resolved.service 2>/dev/null | grep -c 'Starting')"`,
  `echo "@@failed"; systemctl --failed --no-legend --plain 2>&1 | head -n 5`,
  `echo "@@journal"; sudo -n journalctl -b -q -o short-iso -u cmux-dns-scope.service -u cmux-dns-scope.path -u systemd-resolved.service 2>&1 | tail -n 40`,
].join("; ").replace(/^/, "{ ") + "; } 2>&1 | head -c 6000";

/** What the guest's cmux-host last reported (cmux-host cloud/role.rs write_state: `/run/cmux-vm-agent/state.json`, 0644,
 * never a secret) and the acpmux processes whose `acp_activity` lines it counts. Run 45821066460 read "activity-turn-end
 * 0/1" for both arms from `cloud.machine.connect_info`, the row's daemon block (bind time, possibly behind the report);
 * Pause.ts turnEndWindow reads the report's own block, so that is the one the drill names now. */
export const GUEST_REPORT_STATE = `cat /run/cmux-vm-agent/state.json 2>&1 | head -c 4000; echo; echo "@@acpmux"; ` +
  `for p in $(pgrep -x acpmux); do e=$(readlink /proc/$p/exe 2>/dev/null); echo "$p $e $(sha256sum "$e" 2>/dev/null | cut -c1-12) $("$e" --version 2>/dev/null | head -1)"; done`;

export type ReportState = { capabilities: string[] | null; version: string | null; last: string | null; acpmux: string[]; error: string | null };

/** Parse GUEST_REPORT_STATE's output; a missing or unreadable state file is kept as `error`. */
export function parseReportState(out: string): ReportState {
  const [head, tail = ""] = out.split("@@acpmux");
  const acpmux = tail.split("\n").map((l) => l.trim()).filter(Boolean);
  try {
    const j = JSON.parse(head.trim());
    const caps = j?.daemon?.capabilities;
    const lr = j?.last_report;
    return {
      capabilities: Array.isArray(caps) ? caps.map(String) : null,
      version: j?.daemon?.version != null ? String(j.daemon.version) : null,
      last: lr ? `${lr.reason ?? "?"} ok=${lr.ok} applied=${lr.applied} status=${lr.status ?? "none"}` : null,
      acpmux, error: null,
    };
  } catch {
    return { capabilities: null, version: null, last: null, acpmux, error: head.trim().slice(0, 200) || "empty" };
  }
}

export const reportLine = (r: ReportState): string => r.error !== null ? `report state unreadable: ${r.error}; acpmux ${r.acpmux.join(", ") || "none"}` :
  `reported caps ${r.capabilities?.join(",") ?? "none"}; daemon ${r.version ?? "?"}; last ${r.last ?? "none"}; acpmux ${r.acpmux.join(", ") || "none"}`;

/** One gap's line in the per-gap table. */
export function gapLine(name: string, t: MachineResult["turns"][number]): string {
  const cell = (v: string | null | undefined) => (v ?? "n/a").replace(/\|/g, "\\|").replace(/\n/g, "; ");
  return `| ${name} | ${t.turn} | ${t.gap_s} | ${cell(t.kept)} | ${cell(t.listeners)} | ${cell(t.report)} |`;
}

/** One reading of the guest updater, its parts kept apart: the binary running, what the updater applied, the
 * channel's published commit, and the updater's last outcome. `error` holds a failed read verbatim. */
export type GuestUpdate = {
  exit: number | null; error: string | null;
  cmux_tui: string | null; current_generation: unknown; applied_commit: string | null;
  last_outcome: string | null; last_at: number | null; off: unknown; pending: unknown;
  channel_url: string | null; channel_commit: string | null; channel_error: string | null;
};

export function parseGuestUpdate(stdout: string): GuestUpdate {
  const exit = Number(/@@exit (\d+)/.exec(stdout)?.[1] ?? NaN);
  const body = stdout.replace(/^[\s\S]*?@@exit \d+\n?/, "").trim();
  const g: GuestUpdate = {
    exit: Number.isFinite(exit) ? exit : null, error: null, cmux_tui: null, current_generation: null, applied_commit: null,
    last_outcome: null, last_at: null, off: null, pending: null, channel_url: null, channel_commit: null, channel_error: null,
  };
  const line = body.split("\n").find((l) => l.trim().startsWith("{"));
  let v: any = null;
  try { v = line ? JSON.parse(line) : null; } catch { v = null; }
  if (g.exit !== 0 || !v) { g.error = body.slice(0, 500) || `no output (exit ${g.exit})`; if (!v) return g; }
  g.cmux_tui = v.cmux_tui == null ? null : String(v.cmux_tui);
  g.current_generation = v.current ?? null;
  g.applied_commit = v.state?.applied_commit ?? null;
  g.last_outcome = v.state?.last ?? null;
  g.last_at = typeof v.state?.last_at === "number" ? v.state.last_at : null;
  g.off = v.off ?? null;
  g.pending = v.pending ?? null;
  g.channel_url = typeof v.channel === "string" ? v.channel : null;
  return g;
}

/** The channel's published commit, read by the runner from the URL the guest names (the signed envelope's payload). */
async function channelCommit(url: string): Promise<{ commit: string | null; error: string | null }> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) return { commit: null, error: `HTTP ${res.status}` };
    const env: any = await res.json();
    const payload = JSON.parse(Buffer.from(String(env?.payload ?? ""), "base64").toString("utf8"));
    const commit = payload?.commit ?? payload?.cmux_tui?.commit ?? payload?.build?.commit ?? null;
    return commit ? { commit: String(commit), error: null } : { commit: null, error: `no commit in payload keys ${Object.keys(payload ?? {}).join(",")}` };
  } catch (e) {
    return { commit: null, error: String(e).slice(0, 200) };
  }
}

async function readGuestUpdate(exec: Exec): Promise<GuestUpdate> {
  let g: GuestUpdate;
  try {
    g = parseGuestUpdate((await exec(GUEST_UPDATE, 60_000)).stdout);
  } catch (e) {
    g = parseGuestUpdate("");
    g.error = `exec: ${String(e).slice(0, 300)}`;
  }
  if (g.channel_url) {
    const c = await channelCommit(g.channel_url);
    g.channel_commit = c.commit;
    g.channel_error = c.error;
  }
  return g;
}

export const guestLine = (name: string, g: GuestUpdate | null): string => !g ? `${name}: not read` :
  `${name}: binary ${g.cmux_tui ?? "?"}; applied ${g.applied_commit ?? "none"}; channel ${g.channel_commit ?? `? (${g.channel_error ?? "no url"})`}; ` +
  `updater ${g.last_outcome ?? "no outcome"}${g.off ? `, off ${JSON.stringify(g.off)}` : ""}${g.pending ? ", pending" : ""}${g.error ? `; ERROR ${g.error.slice(0, 160)}` : ""}`;

export async function main(argv = process.argv.slice(2)): Promise<number> {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("*/")[0]);
    return 0;
  }
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging", argValue("--api", argv), argValue("--stack", argv));
  const outArg = argValue("--out", argv);
  const outDir = outArg ? path.resolve(outArg) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const credFile = argValue("--credentials", argv);
  const creds = credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {};
  const email = process.env.CMUX_STAGING_STACK_EMAIL ?? process.env.CMUX_DOGFOOD_STACK_EMAIL ?? creds.CMUX_STAGING_STACK_EMAIL ?? creds.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_STAGING_STACK_PASSWORD ?? process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? creds.CMUX_STAGING_STACK_PASSWORD ?? creds.CMUX_DOGFOOD_STACK_PASSWORD;
  const signIn = argValue("--sign-in", argv) ?? "password";
  const team = argValue("--team", argv);
  const arms = (argValue("--arms", argv) ?? "turn_end,aggressive").split(",").map((s) => s.trim()).filter(Boolean);
  const perArm = Math.max(1, Number(argValue("--per-arm", argv) ?? 2));
  const turnCount = Math.max(1, Number(argValue("--turns", argv) ?? 8));
  const seed = Number(argValue("--seed", argv) ?? 7);
  const gapChoices = (argValue("--gaps", argv) ?? "20,45,90,180").split(",").map(Number).filter((n) => n > 0);
  const tailS = Number(argValue("--tail", argv) ?? 120);
  const pollMs = Number(argValue("--poll", argv) ?? 5) * 1000;
  // No pair starts its bring-up after this many minutes, so the last pair's turns end inside the job's timeout.
  const bringupBudgetMs = Number(argValue("--bringup-budget", argv) ?? 25) * 60_000;
  // Pair i (machine i of every arm) draws its gaps with seed + i - 1; `gaps` is pair 1's.
  const pairGaps = Array.from({ length: perArm }, (_, i) => gapSchedule(seed + i, turnCount, gapChoices));
  const gaps = pairGaps[0];
  const tag = Date.now().toString(36);
  const nonce = randomBytes(6).toString("hex");
  const run = process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : "local";
  const J = new Journey(backend, outDir, { tag, arms: arms.join(","), per_arm: String(perArm), turns: String(turnCount), seed: String(seed), gaps: gaps.join(","), tail_s: String(tailS), run });
  if (password) J.secrets.push(password);
  const api = new Api(backend.api, team);
  const results: MachineResult[] = arms.flatMap((arm) => Array.from({ length: perArm }, (_, i) => ({
    arm, name: `${NAME_PREFIX}${tag}-${arm}-${i + 1}`, pair: i + 1, seed: seed + i, gaps_s: pairGaps[i], id: null, effective_policy: null, policy_refused: null, capabilities: null,
    turn_end_advertised: null, daemon_version: null, guest_update_start: null, guest_update_end: null, turns_ok: 0, turns: [], tail_kept: null, samples: [],
    awake_s: null, paused_s: null, pauses: null, error: null,
  } as MachineResult)));
  let usageBefore: number | null = null;
  let usageAfter: number | null = null;
  let windowStart = 0;
  let windowEnd = 0;

  const writeOut = () => {
    if (!outDir) return;
    const rows = aggregate(results, arms);
    const usage = usageBefore !== null && usageAfter !== null ? Math.round((usageAfter - usageBefore) * 3600) : null;
    writeFileSync(path.join(outDir, "pause-ab.json"), `${JSON.stringify({
      schema: 1, backend: backend.name, tag, arms, per_arm: perArm, seed, gaps_s: gaps, pair_gaps_s: pairGaps, tail_s: tailS, poll_ms: pollMs,
      window: windowStart ? { start: new Date(windowStart).toISOString(), end: windowEnd ? new Date(windowEnd).toISOString() : null } : null,
      measurement: "cloud.machine.get status sampled every poll_ms (awake = not paused); cross-check: cloud.plan.get usage.vm_hours_used_by_you delta (account-wide)",
      account_vm_seconds_delta: usage, rows, machines: results,
    }, null, 2)}\n`);
    const steps = J.steps.map((s) => `| ${s.status.toUpperCase()} | ${s.step} | ${s.ms} | ${s.detail.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 200)} |`).join("\n");
    writeFileSync(path.join(outDir, "summary.md"), `# Pause-policy A/B (${backend.name})\n\n` +
      `${perArm} machine(s) per arm, ${turnCount} stub turns, seeds ${seed}..${seed + perArm - 1} (one per pair), pair 1 gaps ${gaps.join(", ")} s, tail ${tailS} s. ` +
      `Awake/paused from \`cloud.machine.get\` status every ${pollMs / 1000} s. Account VM seconds over the run (all machines, cross-check): ${usage ?? "n/a"}.\n\n` +
      `${markdownTable(rows)}\n\n## Per pair (same seed and gaps in every arm)\n\n${pairTable(results, arms)}\n\n## Guest updater (\`sudo -n /opt/cmux/current/bin/cmux host update status --json\`)\n\n` +
      results.map((r) => `- start ${guestLine(r.name, r.guest_update_start)}\n- end ${guestLine(r.name, r.guest_update_end)}`).join("\n") +
      `\n\n## Idle decision per gap (\`cloud.machine.get\` at the gap's end; guest listeners when awake)\n\n` +
      `| machine | turn | gap s | idle decision | listeners (addr, owner) | guest report at turn end |\n|---|---|---|---|---|---|\n` +
      results.flatMap((r) => [...r.turns.map((t) => gapLine(r.name, t)), `| ${r.name} | tail | ${tailS} | ${(r.tail_kept ?? "n/a").replace(/\|/g, "\\|")} | n/a | n/a |`]).join("\n") +
      `\n\n## Steps\n\n| status | step | ms | detail |\n|---|---|---|---|\n${steps}\n`);
  };

  const cleanup = sharedCleanup(async () => {
    if (!api.bearer) return;
    const missing = results.filter((r) => !r.id);
    if (missing.length) {
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p)).catch(() => []);
      for (const r of missing) r.id = rows.find((m: any) => m?.name === r.name && m.status !== "deleted")?.id ?? null;
    }
    // Four at a time with a 10-minute budget each: run 45864237040's 20 concurrent deletes stayed
    // mutation.indeterminate past the default 180 s for 11 machines.
    await pool(results.filter((r) => r.id), 4, (r) => J.step(`delete ${r.name}`, async () => {
      await api.deleteMachine(r.id!, `pab-${tag}-delete-${r.name}`, 600_000);
      return { value: null, detail: r.id! };
    }).then(() => undefined, () => undefined));
  });
  const onSignal = (signal: string) => {
    void cleanup().finally(() => { writeOut(); J.flush(); process.exit(signal === "SIGINT" ? 130 : 143); });
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);

  const runMachine = async (r: MachineResult) => {
    const id = r.id!;
    const exec: Exec = directExec(api, id, J);
    const read = () => api.read("cloud.machine.get", { machine: id });
    const session = `pab-${tag}`;
    const login = `sk-ant-oat01-journeystub-${randomBytes(24).toString("hex")}`;
    J.secrets.push(login);
    const wakeIfNeeded = async (turn: MachineResult["turns"][number]) => {
      const m = await read();
      if (m?.status === "running") return;
      turn.resumed = true;
      const t0 = Date.now();
      if (m?.status !== "starting") await api.op("cloud.machine.start", { machine: id }, `pab-${tag}-${r.name}-start-${turn.turn}`).catch(() => undefined);
      while (Date.now() - t0 < 180_000) {
        const s = await read().catch(() => null);
        if (s?.status === "running") { turn.resume_ms = Date.now() - t0; return; }
        if (s?.status === "paused") await api.op("cloud.machine.start", { machine: id }, `pab-${tag}-${r.name}-start-${turn.turn}-${Date.now()}`).catch(() => undefined);
        await sleep(500);
      }
      throw new Error("did not resume within 180 s");
    };
    const awaitReply = async (marker: string, turn: MachineResult["turns"][number]) => {
      const t0 = Date.now();
      // The reply is read only once acp history lists this turn's prompt (send --no-wait returns before the turn starts).
      while (Date.now() - t0 < 180_000) {
        const h = await exec(`${GUEST}"$c" acp --json history ${shq(session)} --limit 5 2>&1`, 45_000);
        let listed: any[] = [];
        try { listed = JSON.parse(h.stdout.slice(h.stdout.indexOf("{"))).turns ?? []; } catch { /* not yet */ }
        if (listed.some((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker))) break;
        await sleep(1_000);
      }
      let waitFails = 0;
      while (Date.now() - t0 < 240_000) {
        // stderr of `acp wait` is kept (after @@werr) so a non-zero exit says why.
        const w = await exec(`${GUEST}we=$("$c" acp wait ${shq(session)} --timeout 20 2>&1 >/dev/null); echo "@@wait $?"; "$c" acp last ${shq(session)} 2>&1; printf '\\n@@werr %s\\n' "$(printf %s "$we" | tail -c 300 | tr '\\n' ' ')"`, 45_000);
        const { code, text, werr } = parseWaitOutput(w.stdout);
        let turnStatus: string | null = null;
        if (code && code !== "0" && code !== "3") {
          const h = await exec(`${GUEST}"$c" acp --json history ${shq(session)} --limit 5 2>&1`, 45_000).catch(() => null);
          turnStatus = h ? historyTurnStatus(h.stdout, marker) : null;
        }
        const v = waitVerdict({ code, text, werr, turnStatus, nonce, waitFails });
        if (v.kind === "reply") {
          if (v.note) turn.wait_note = v.note;
          return Date.now() - t0;
        }
        if (v.kind === "fail") throw new Error(v.error);
        if (v.kind === "retry") { waitFails++; await sleep(2_000); }
      }
      throw new Error("no reply within 240 s");
    };
    // The port of the model stub stopped for the last gap (stubStop), started again with the next message.
    let stubPort = 0;
    // An exec that failed (vm_unavailable) earlier in the run: the next one that answers reads GUEST_RESOLVER_FACTS.
    let sawExecFail = false;
    for (let i = 0; i < turnCount; i++) {
      const turn: MachineResult["turns"][number] = { turn: i + 1, gap_s: r.gaps_s[i], resumed: false, resume_ms: null, reply_ms: null };
      r.turns.push(turn);
      const marker = `[pab ${tag} turn ${i + 1}]`;
      const prompt = `${marker} Run the tool and report what it printed.`;
      try {
        await wakeIfNeeded(turn);
        if (i === 0) {
          const s = await exec(`${GUEST}${launchCredentialStartProgram(session, "claude", "CLAUDE_CODE_OAUTH_TOKEN", login, prompt)}`, 120_000);
          if (!/@@prompted/.test(s.stdout)) throw new Error(`session start: ${s.stdout.slice(-300)}`);
        } else {
          const pre = stubPort ? stubRestart(stubPort, nonce) : "";
          const s = await exec(`${pre}${GUEST}printf '%s' ${shq(prompt)} | "$c" acp send --no-wait ${shq(session)} - 2>&1; echo "@@exit $?"`, 60_000);
          stubPort = 0;
          if (!/@@exit 0/.test(s.stdout)) throw new Error(`send: ${s.stdout.slice(-300)}`);
        }
        turn.reply_ms = await awaitReply(marker, turn);
        r.turns_ok++;
      } catch (e) {
        turn.error = String((e as Error)?.message ?? e).slice(0, 300);
      }
      // What the guest reported once the turn ended (the report Pause.ts reads), before the gap starts.
      let reportFailed = false;
      const rs = parseReportState((await exec(GUEST_REPORT_STATE, 30_000).catch((e: Error) => { reportFailed = true; return { stdout: `read failed: ${e.message.slice(0, 120)}` }; })).stdout);
      turn.report = reportLine(rs);
      const execFailed = reportFailed || /vm_unavailable/.test(turn.error ?? "");
      if (execFailed) sawExecFail = true;
      else if (sawExecFail && r.resolver_recovered === undefined) {
        r.resolver_recovered = `after turn ${i + 1}: ${(await exec(GUEST_RESOLVER_FACTS, 30_000).catch((e: Error) => ({ stdout: `read failed: ${e.message.slice(0, 120)}` }))).stdout.trim()}`;
      }
      if (i === 0) {
        const info = await api.read("cloud.machine.connect_info", { machine: id }).catch(() => null);
        if (info?.daemon) r.bind_capabilities = Array.isArray(info.daemon.capabilities) ? info.daemon.capabilities : null;
        r.capabilities = rs.capabilities;
        r.turn_end_advertised = rs.capabilities ? rs.capabilities.includes(TURN_END_CAPABILITY) : null;
        r.daemon_version = rs.version ?? info?.daemon?.version ?? null;
      }
      // The stub's listener would hold the idle clock for the whole gap: stop it, restart it with the next message.
      const st = await exec(stubStop(), 30_000).catch((e: Error) => ({ stdout: `stop failed: ${e.message.slice(0, 120)}` }));
      stubPort = Number(/@@stopped (\d+)/.exec(st.stdout)?.[1] ?? 0);
      if (!stubPort) turn.error = `${turn.error ? `${turn.error}; ` : ""}model stub not stopped for the gap: ${st.stdout.slice(-160)}`;
      await sleep(r.gaps_s[i] * 1000);
      // The host's idle decision at the gap's end: paused, or why not (idle_kept: workload ports, sessions, clock).
      // The listener read execs on the guest, so it runs only when the machine is awake anyway and a turn follows.
      const m = await api.read("cloud.machine.get", { machine: id }).catch(() => null);
      if (m?.status === "paused") turn.kept = "paused";
      else {
        turn.kept = `status ${m?.status ?? "?"}; ${await idleHeldBy(api, id)}`;
        if (i < turnCount - 1) {
          const l = await exec(GUEST_LISTENERS, 30_000).catch((e: Error) => ({ stdout: `read failed: ${e.message.slice(0, 120)}` }));
          turn.listeners = l.stdout.trim().split("\n").join("; ").slice(0, 400) || "none";
        }
      }
    }
  };

  try {
    await J.step("health", async () => {
      const h = await http("GET", `${backend.api}/v1/health`, undefined, {});
      if (h.status !== 200) throw new Error(`HTTP ${h.status} ${short(h.body)}`);
      return { value: null, detail: `commit ${h.body.commit ?? h.body.version ?? "?"}` };
    });
    api.bearer = await J.step("sign in (agent test account)", async () => {
      if (signIn === "oidc") {
        const s = await oidcSignIn(backend.api, process.env, J.secrets);
        return { value: s.token, detail: "GitHub OIDC" };
      }
      if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
      const s = await passwordSignIn(STACK[backend.stack], email, password);
      J.secrets.push(s.access, s.refresh);
      return { value: s.access, detail: "password" };
    });
    await J.step("user.ensure", async () => ({ value: await api.op("user.ensure", {}, `pab-${tag}-ensure`), detail: "ok" }));
    {
      const t0 = Date.now();
      let census = "";
      try {
        const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
        const kept: string[] = [];
        const stale = stalePauseAbMachines(rows, Date.now(), PAUSE_AB_STALE_MS, kept);
        for (const k of kept) console.log(`sweep: kept ${k}`);
        census = accountCensus(rows, Date.now());
        console.log(`sweep: account ${rows.length} machines; ${census}`);
        for (const m of stale) {
          console.log(`sweep: deleting leaked ${m.id} (${m.name}, ${m.why})`);
          await api.deleteMachine(m.id, `pab-${tag}-sweep-${m.id}`).catch((e: Error) => console.log(`sweep: delete ${m.id} failed: ${String(e?.message ?? e).slice(0, 200)}`));
        }
        J.record({ step: "sweep leaked pause-ab machines", status: "pass", ms: Date.now() - t0, detail: `${stale.length} swept, ${kept.length} pause-ab kept, of ${rows.length}; ${census}` });
      } catch (e) {
        J.record({ step: "sweep leaked pause-ab machines", status: "skip", ms: Date.now() - t0, detail: String((e as Error)?.message ?? e).slice(0, 300) });
      }
    }
    usageBefore = await api.read("cloud.plan.get", {}).then((p) => Number(p?.usage?.vm_hours_used_by_you ?? NaN)).then((n) => (Number.isFinite(n) ? n : null)).catch(() => null);
    const took: string[] = [];
    // Each machine carries ttl_seconds, so the platform's own reaper deletes it at the stale cutoff even when this
    // job is killed before its delete step (the leaks of 08:00Z and 08:55Z waited for the next run's sweep).
    let ttlRefused: string | null = null;
    const createOne = async (r: MachineResult) => {
      const c0 = Date.now();
      const ask = (ttl: boolean) => api.op("cloud.machine.create", { name: r.name, size: CHAT_START_SIZE, ...(ttl ? { ttl_seconds: PAUSE_AB_STALE_MS / 1000 } : {}) }, `pab-${tag}-create-${r.name}${ttl ? "" : "-nottl"}`);
      let v: any;
      try {
        v = await ask(ttlRefused === null);
      } catch (e) {
        const msg = String((e as Error)?.message ?? e);
        if (ttlRefused !== null || !/ttl_seconds|validation/i.test(msg)) throw e;
        ttlRefused = msg.slice(0, 200);
        v = await ask(false);
      }
      r.id = String(v.machine?.id ?? v.machine ?? "") || null;
      took.push(`${r.name} ${Math.round((Date.now() - c0) / 1000)} s`);
      if (!r.id) throw new Error(`create ${r.name} answered no machine: ${short(v)}`);
    };
    // One pair at a time: a pair's creates go out once the previous pair runs, and it starts its turns at once, so
    // pairs overlap while staging's VM API never sees more than one pair's creates (run 45864237040: 20 concurrent
    // creates, 8 answered cloud.provider.unavailable "vm-provider.persistCreateIntent (no response)", and one
    // machine not running in 300 s failed the whole drill). A pair that cannot come up is skipped, with its reason.
    const bringUp = async (r: MachineResult) => {
      await createOne(r);
      for (;;) {
        const t0 = Date.now();
        let failed: any = null;
        let up = false;
        while (Date.now() - t0 < 300_000) {
          const m = await api.read("cloud.machine.get", { machine: r.id }).catch(() => null);
          if (m?.status === "running" && m?.host) { up = true; break; }
          if (m?.status === "failed") { failed = m; break; }
          await sleep(1000);
        }
        if (up) break;
        if (!failed) throw new Error(`${r.name} not running within 300 s`);
        const why = `${r.name} ${r.id} failed ${Math.round((Date.now() - t0) / 1000)} s after create answered: ${failureFacts(failed)}`;
        // A create the provider failed after the platform's own 5-minute retry window (staging 11:47Z,
        // cloud.provider.unavailable "VM API: HTTP 503") gets one replacement, recorded in the summary.
        if (failedCreateIsTransient(failed) && !r.replaced) {
          r.replaced = why;
          console.log(`running: replacing ${why}`);
          await api.op("cloud.machine.delete", { machine: r.id }, `pab-${tag}-delete-failed-${r.name}`).catch((e) => console.log(`running: delete of failed ${r.id}: ${String((e as Error)?.message ?? e).slice(0, 200)}`));
          r.name = `${r.name}r`;
          await createOne(r);
          continue;
        }
        throw new Error(r.replaced ? `${why}; the machine it replaced: ${r.replaced}` : why);
      }
      try {
        await api.op("cloud.machine.idle_policy.set", { machine: r.id, pause_policy: r.arm }, `pab-${tag}-policy-${r.name}`);
      } catch (e) {
        r.policy_refused = String((e as Error)?.message ?? e).slice(0, 300);
        await api.op("cloud.machine.idle_policy.set", { machine: r.id, pause_policy: "aggressive" }, `pab-${tag}-policy-fallback-${r.name}`);
      }
      r.effective_policy = (await api.read("cloud.machine.get", { machine: r.id }))?.pause_policy ?? null;
      for (const [p, data] of [[`${STUB_DIR}/pab-model-stub.py`, readFileSync(MODEL_STUB_PY)], [`${STUB_DIR}/pab-model-stub.json`, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
        const w = await api.raw("POST", `/v1/cloud/machines/${r.id}/fs/write`, { path: p, dataBase64: data.toString("base64"), mode: 0o644 });
        if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`${r.name} fs/write ${p}: HTTP ${w.status}`);
      }
      const exec = directExec(api, r.id!, J);
      const s = await exec(stubStartCommand(nonce), 60_000);
      if (!s.stdout.includes("stub-ready")) throw new Error(`${r.name} stub: ${s.stdout.slice(-200)} ${s.stderr.slice(-200)}`);
      r.guest_update_start = await readGuestUpdate(exec);
    };

    // Status sampler: one cloud.machine.get per driving machine every poll interval, inside that machine's window.
    let sampling = true;
    const sampler = (async () => {
      while (sampling) {
        const at = Date.now();
        await Promise.all(results.filter((r) => r.window && !r.window.end).map(async (r) => {
          const m = await api.read("cloud.machine.get", { machine: r.id }).catch(() => null);
          if (m?.status) r.samples.push({ at: Date.now(), status: String(m.status) });
        }));
        await sleep(Math.max(0, pollMs - (Date.now() - at)));
      }
    })();
    const drivePair = async (ms: MachineResult[]) => {
      const start = Date.now();
      for (const r of ms) r.window = { start, end: 0 };
      await Promise.all(ms.map((r) => runMachine(r).catch((e) => { r.error = String((e as Error)?.message ?? e).slice(0, 300); })));
      await sleep(tailS * 1000);
      await Promise.all(ms.map(async (r) => {
        const m = await api.read("cloud.machine.get", { machine: r.id }).catch(() => null);
        r.tail_kept = m?.status === "paused" ? "paused" : `status ${m?.status ?? "?"}; ${await idleHeldBy(api, r.id!)}`;
      }));
      const end = Date.now();
      for (const r of ms) r.window!.end = end;
    };
    const drives: Promise<void>[] = [];
    const bring0 = Date.now();
    windowStart = bring0;
    for (const { pair, machines: ms } of pairsOf(results)) {
      const t0 = Date.now();
      if (t0 - bring0 > bringupBudgetMs) {
        for (const r of ms) r.skipped = `bring-up budget ${bringupBudgetMs / 60_000} min spent before pair ${pair}`;
        J.record({ step: `pair ${pair} up`, status: "skip", ms: 0, detail: ms[0].skipped! });
        continue;
      }
      const up = await Promise.allSettled(ms.map(bringUp));
      const why = up.flatMap((u) => (u.status === "rejected" ? [String((u.reason as Error)?.message ?? u.reason).slice(0, 300)] : []));
      if (why.length) {
        for (const r of ms) r.skipped = why.join(" | ");
        console.log(`pair ${pair} skipped: ${why.join(" | ")}`);
        J.record({ step: `pair ${pair} up`, status: "skip", ms: Date.now() - t0, detail: why.join(" | ").slice(0, 1000) });
        continue;
      }
      J.record({
        step: `pair ${pair} up`, status: "pass", ms: Date.now() - t0,
        detail: ms.map((r) => `${r.name}=${r.id} ${r.effective_policy}${r.policy_refused ? " (asked policy refused)" : ""}${r.replaced ? ` [replaced: ${r.replaced}]` : ""}; ${guestLine(r.name, r.guest_update_start)}`).join(" | ").slice(0, 1000) + (ttlRefused ? `; ttl_seconds refused: ${ttlRefused}` : ""),
      });
      drives.push(drivePair(ms));
    }
    console.log(`created: ${took.join(", ")}`);
    const driven = results.filter((r) => !r.skipped);
    await J.step(`drive ${turnCount} turns per pair (${driven.length / arms.length} of ${perArm} pairs up)`, async () => {
      await Promise.all(drives);
      return { value: null, detail: driven.map((r) => `${r.name} ${r.turns_ok}/${r.turns.length} ok`).join("; ") };
    }).catch(() => undefined);
    windowEnd = Date.now();
    sampling = false;
    await sampler;
    for (const r of driven) if (r.window) Object.assign(r, integrate(r.samples, r.window.start, r.window.end));
    await Promise.all(driven.map(async (r) => {
      const info = await api.read("cloud.machine.connect_info", { machine: r.id }).catch(() => null);
      if (r.capabilities === null && Array.isArray(info?.daemon?.capabilities)) {
        r.capabilities = info.daemon.capabilities;
        r.turn_end_advertised = r.capabilities!.includes(TURN_END_CAPABILITY);
      }
    }));
    await J.step("guest resolver (end)", async () => {
      await Promise.all(driven.map(async (r) => {
        r.resolver_end = (await directExec(api, r.id!, J)(GUEST_RESOLVER_FACTS, 30_000).catch((e: Error) => ({ stdout: `read failed: ${e.message.slice(0, 120)}` }))).stdout.trim();
      }));
      return { value: null, detail: driven.map((r) => `${r.name}: ${r.resolver_recovered ? `[recovered ${r.resolver_recovered}] ` : ""}[end ${r.resolver_end}]`).join(" || ") };
    }).catch(() => undefined);
    await J.step("guest update status (end)", async () => {
      await Promise.all(driven.map(async (r) => { r.guest_update_end = await readGuestUpdate(directExec(api, r.id!, J)); }));
      return { value: null, detail: driven.map((r) => guestLine(r.name, r.guest_update_end)).join(" | ") };
    }).catch(() => undefined);
    usageAfter = await api.read("cloud.plan.get", {}).then((p) => Number(p?.usage?.vm_hours_used_by_you ?? NaN)).then((n) => (Number.isFinite(n) ? n : null)).catch(() => null);
    J.record({
      step: "idle decision per gap", status: "pass", ms: 0,
      detail: driven.map((r) => `${r.name}: ${r.turns.map((t) => `gap ${t.turn} (${t.gap_s} s) ${t.kept ?? "n/a"}${t.listeners ? ` [listeners ${t.listeners}]` : ""}${t.report ? ` [${t.report}]` : ""}`).join(" / ")} / tail ${r.tail_kept ?? "n/a"}`).join(" || "),
    });
    const missing = missingCapability(driven);
    const table = markdownTable(aggregate(results, arms)).split("\n").slice(2).join(" ");
    J.record({
      step: "result",
      // Pass: at least half the pairs drove, every driven turn answered, every arm ran under its policy.
      status: driven.length > 0 && driven.length * 2 >= results.length && driven.every((r) => r.turns_ok === r.turns.length) && missing.length === 0 ? "pass" : "fail",
      ms: windowEnd - windowStart,
      detail: missing.length ? `${table} :: arm not under its policy: ${missing.join(" | ")}` : table,
    });
  } catch {
    // The failed step is recorded; cleanup below.
  } finally {
    await cleanup();
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
    writeOut();
  }
  console.log(`\n${markdownTable(aggregate(results, arms))}`);
  for (const r of results) for (const t of r.turns) console.log(gapLine(r.name, t));
  const failed = J.steps.filter((s) => s.status === "fail");
  return failed.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
