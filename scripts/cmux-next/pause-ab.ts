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
 * pause_policy}` and reads it back, and drives the same seeded chat on every machine at once: --turns Claude turns
 * against the journey's model stub on the machine's loopback (`--model stub`, no real model), each followed by an
 * idle gap drawn from --gaps with --seed (every machine gets the same gaps), then --tail seconds idle at the end.
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
 * (self-update state.json, start and end) and the effective pause policy (a refused `turn_end` falls back to
 * `aggressive` with policy_refused set).
 *
 * The model stub listens on loopback. cmux-host's workload probe (cloud/workload.rs) counts any listening socket as
 * work that keeps a machine awake unless its owner is a system process, so the stub runs through a symlink to python3
 * named `cmux-tui-pab-stub` (a `cmux-tui` prefix): it stands in for a remote model endpoint and both arms get it.
 *
 * Output (--out DIR): pause-ab.json (every machine's timeline, turns, resumes) and summary.md (one table row per arm:
 * awake s, paused s, resumes, mean resume ms), plus journey.json (steps). Every machine this run created is deleted
 * at the end, pass or fail; machines named `pause-ab-<tag>-...` whose tag is more than 3 hours old and idle for an
 * hour (a killed run's) are swept before create. Any other name is never touched. Exit 0 only when no step failed.
 */
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  Api, CHAT_START_SIZE, IDLE_JOURNEY_MS, JOURNEY_STUB_SCRIPT, Journey, MODEL_STUB_PY, STACK, STALE_JOURNEY_MS, directExec, http,
  launchCredentialStartProgram, listAllMachines, oidcSignIn, passwordSignIn, readEnvFile, resolveBackend, sharedCleanup,
  type Exec,
} from "./cloud-journey.ts";

const GUEST = 'export HOME="${HOME:-/home/cmux}"; cd "$HOME" 2>/dev/null || cd /; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ';
const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const argValue = (flag: string, argv: string[]): string | undefined => {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
};

export const TURN_END_CAPABILITY = "activity-turn-end";
export const NAME_PREFIX = "pause-ab-";

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
  id: string | null;
  effective_policy: string | null;
  policy_refused: string | null;
  capabilities: string[] | null;
  turn_end_advertised: boolean | null;
  daemon_version: string | null;
  build_commit_start: string | null;
  build_commit_end: string | null;
  turns_ok: number;
  turns: { turn: number; gap_s: number; resumed: boolean; resume_ms: number | null; reply_ms: number | null; error?: string }[];
  samples: Sample[];
  awake_s: number | null;
  paused_s: number | null;
  pauses: number | null;
  error: string | null;
};

export type ArmRow = { arm: string; machines: number; turn_end_advertised: string; awake_s: number; paused_s: number; awake_pct: number; resumes: number; mean_resume_ms: number | null; turns_ok: string };

/** One row per arm: awake and paused seconds summed over its machines, resumes, and their mean latency. */
export function aggregate(results: MachineResult[], arms: string[]): ArmRow[] {
  return arms.map((arm) => {
    const ms = results.filter((r) => r.arm === arm);
    const awake = ms.reduce((n, r) => n + (r.awake_s ?? 0), 0);
    const paused = ms.reduce((n, r) => n + (r.paused_s ?? 0), 0);
    const resumes = ms.flatMap((r) => r.turns.filter((t) => t.resumed));
    const timed = resumes.map((t) => t.resume_ms).filter((v): v is number => typeof v === "number");
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
      turns_ok: `${ms.reduce((n, r) => n + r.turns_ok, 0)}/${turns}`,
    };
  });
}

export function markdownTable(rows: ArmRow[]): string {
  const head = "| arm | machines | activity-turn-end | awake s | paused s | awake % | resumes | mean resume ms | turns ok |\n|---|---|---|---|---|---|---|---|---|";
  return [head, ...rows.map((r) => `| ${r.arm} | ${r.machines} | ${r.turn_end_advertised} | ${r.awake_s} | ${r.paused_s} | ${r.awake_pct} | ${r.resumes} | ${r.mean_resume_ms ?? "n/a"} | ${r.turns_ok} |`)].join("\n");
}

/** Machines an earlier pause-ab run left behind: our name shape, tag older than maxAgeMs, idle for an hour. */
export function stalePauseAbMachines(rows: any[], nowMs: number, maxAgeMs = STALE_JOURNEY_MS): { id: string; name: string }[] {
  const out: { id: string; name: string }[] = [];
  for (const r of rows) {
    if (!r || r.status === "deleted" || r.status === "deleting") continue;
    const m = /^pause-ab-([0-9a-z]+)-[a-z_]+-\d+$/.exec(typeof r.name === "string" ? r.name : "");
    if (!m) continue;
    const started = parseInt(m[1], 36);
    if (!Number.isFinite(started) || started < Date.UTC(2020, 0, 1) || started > nowMs || nowMs - started <= maxAgeMs) continue;
    if (typeof r.last_active_at === "number" && nowMs - r.last_active_at <= IDLE_JOURNEY_MS) continue;
    const id = String(r.id ?? r.machine_id ?? "");
    if (id) out.push({ id, name: r.name });
  }
  return out;
}

const STUB_DIR = "/home/cmux/.cmux";
const STUB_LINK = `${STUB_DIR}/cmux-tui-pab-stub`;

/** Starts the model stub (through the cmux-tui-named python3 link) and points Claude Code's settings at it. */
function stubStartCommand(nonce: string): string {
  const file = `${STUB_DIR}/pab-model-stub.py`;
  const script = `${STUB_DIR}/pab-model-stub.json`;
  const ready = `${STUB_DIR}/pab-model-stub.ready`;
  const log = `${STUB_DIR}/pab-model-stub.log`;
  return `mkdir -p ${STUB_DIR}; ln -sf "$(command -v python3)" ${STUB_LINK}; rm -f ${shq(ready)}; ` +
    `(nohup ${STUB_LINK} ${shq(file)} --port 0 --script ${shq(script)} --nonce ${shq(nonce)} --log ${shq(log)} --ready-file ${shq(ready)} >${shq(log)}.out 2>&1 &); ` +
    `for i in $(seq 50); do [ -s ${shq(ready)} ] && break; sleep 0.2; done; ` +
    `port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' ${shq(ready)} 2>/dev/null); ` +
    `[ -n "$port" ] && curl -fsS -m 2 "http://127.0.0.1:$port/__stub/info" | grep -q ${shq(nonce)} || { echo stub-down; tail -5 ${shq(log)}.out; exit 1; }; ` +
    `echo "@@port $port"; python3 - "$port" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\np.parent.mkdir(parents=True, exist_ok=True)\nc = json.loads(p.read_text()) if p.exists() else {}\nc.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\np.write_text(json.dumps(c))\nprint('stub-ready')\nPY`;
}

const BUILD_COMMIT = `python3 -c 'import json; d=json.load(open("/var/lib/cmux/self-update/state.json")); print("@@commit", d.get("applied_commit") or d.get("commit") or "?")' 2>/dev/null || echo "@@commit unknown"`;

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
  const gaps = gapSchedule(seed, turnCount, gapChoices);
  const tag = Date.now().toString(36);
  const nonce = randomBytes(6).toString("hex");
  const run = process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : "local";
  const J = new Journey(backend, outDir, { tag, arms: arms.join(","), per_arm: String(perArm), turns: String(turnCount), seed: String(seed), gaps: gaps.join(","), tail_s: String(tailS), run });
  if (password) J.secrets.push(password);
  const api = new Api(backend.api, team);
  const results: MachineResult[] = arms.flatMap((arm) => Array.from({ length: perArm }, (_, i) => ({
    arm, name: `${NAME_PREFIX}${tag}-${arm}-${i + 1}`, id: null, effective_policy: null, policy_refused: null, capabilities: null,
    turn_end_advertised: null, daemon_version: null, build_commit_start: null, build_commit_end: null, turns_ok: 0, turns: [], samples: [],
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
      schema: 1, backend: backend.name, tag, arms, per_arm: perArm, seed, gaps_s: gaps, tail_s: tailS, poll_ms: pollMs,
      window: windowStart ? { start: new Date(windowStart).toISOString(), end: windowEnd ? new Date(windowEnd).toISOString() : null } : null,
      measurement: "cloud.machine.get status sampled every poll_ms (awake = not paused); cross-check: cloud.plan.get usage.vm_hours_used_by_you delta (account-wide)",
      account_vm_seconds_delta: usage, rows, machines: results,
    }, null, 2)}\n`);
    const steps = J.steps.map((s) => `| ${s.status.toUpperCase()} | ${s.step} | ${s.ms} | ${s.detail.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 200)} |`).join("\n");
    writeFileSync(path.join(outDir, "summary.md"), `# Pause-policy A/B (${backend.name})\n\n` +
      `${perArm} machine(s) per arm, ${turnCount} stub turns, seed ${seed}, gaps ${gaps.join(", ")} s, tail ${tailS} s. ` +
      `Awake/paused from \`cloud.machine.get\` status every ${pollMs / 1000} s. Account VM seconds over the run (all machines, cross-check): ${usage ?? "n/a"}.\n\n` +
      `${markdownTable(rows)}\n\n## Steps\n\n| status | step | ms | detail |\n|---|---|---|---|\n${steps}\n`);
  };

  const cleanup = sharedCleanup(async () => {
    if (!api.bearer) return;
    const missing = results.filter((r) => !r.id);
    if (missing.length) {
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p)).catch(() => []);
      for (const r of missing) r.id = rows.find((m: any) => m?.name === r.name && m.status !== "deleted")?.id ?? null;
    }
    await Promise.all(results.filter((r) => r.id).map((r) => J.step(`delete ${r.name}`, async () => {
      await api.deleteMachine(r.id!, `pab-${tag}-delete-${r.name}`);
      return { value: null, detail: r.id! };
    }).catch(() => undefined)));
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
    const awaitReply = async (marker: string) => {
      const t0 = Date.now();
      // The reply is read only once acp history lists this turn's prompt (send --no-wait returns before the turn starts).
      while (Date.now() - t0 < 180_000) {
        const h = await exec(`${GUEST}"$c" acp --json history ${shq(session)} --limit 5 2>&1`, 45_000);
        let listed: any[] = [];
        try { listed = JSON.parse(h.stdout.slice(h.stdout.indexOf("{"))).turns ?? []; } catch { /* not yet */ }
        if (listed.some((t: any) => typeof t?.prompt === "string" && t.prompt.startsWith(marker))) break;
        await sleep(1_000);
      }
      while (Date.now() - t0 < 240_000) {
        const w = await exec(`${GUEST}"$c" acp wait ${shq(session)} --timeout 20 >/dev/null 2>&1; echo "@@wait $?"; "$c" acp last ${shq(session)} 2>&1`, 45_000);
        const code = /@@wait (\d+)/.exec(w.stdout)?.[1];
        const text = w.stdout.replace(/@@wait \d+\n?/, "").trim();
        if (code === "0" && text) {
          if (!text.includes(`Stub reply ${nonce}.`)) throw new Error(`reply lacks the stub nonce: ${text.slice(-160)}`);
          return Date.now() - t0;
        }
        if (code && code !== "0" && code !== "3") throw new Error(`acp wait exit ${code}: ${text.slice(-200)}`);
      }
      throw new Error("no reply within 240 s");
    };
    for (let i = 0; i < turnCount; i++) {
      const turn: MachineResult["turns"][number] = { turn: i + 1, gap_s: gaps[i], resumed: false, resume_ms: null, reply_ms: null };
      r.turns.push(turn);
      const marker = `[pab ${tag} turn ${i + 1}]`;
      const prompt = `${marker} Run the tool and report what it printed.`;
      try {
        await wakeIfNeeded(turn);
        if (i === 0) {
          const s = await exec(`${GUEST}${launchCredentialStartProgram(session, "claude", "CLAUDE_CODE_OAUTH_TOKEN", login, prompt)}`, 120_000);
          if (!/@@prompted/.test(s.stdout)) throw new Error(`session start: ${s.stdout.slice(-300)}`);
        } else {
          const s = await exec(`${GUEST}printf '%s' ${shq(prompt)} | "$c" acp send --no-wait ${shq(session)} - 2>&1; echo "@@exit $?"`, 60_000);
          if (!/@@exit 0/.test(s.stdout)) throw new Error(`send: ${s.stdout.slice(-300)}`);
        }
        turn.reply_ms = await awaitReply(marker);
        r.turns_ok++;
      } catch (e) {
        turn.error = String((e as Error)?.message ?? e).slice(0, 300);
      }
      if (i === 0) {
        const info = await api.read("cloud.machine.connect_info", { machine: id }).catch(() => null);
        if (info?.daemon) {
          r.capabilities = Array.isArray(info.daemon.capabilities) ? info.daemon.capabilities : null;
          r.turn_end_advertised = r.capabilities ? r.capabilities.includes(TURN_END_CAPABILITY) : null;
          r.daemon_version = info.daemon.version ?? null;
        }
      }
      await sleep(gaps[i] * 1000);
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
      try {
        const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
        const stale = stalePauseAbMachines(rows, Date.now());
        for (const m of stale) {
          console.log(`sweep: deleting leaked ${m.id} (${m.name})`);
          await api.deleteMachine(m.id, `pab-${tag}-sweep-${m.id}`).catch(() => undefined);
        }
        J.record({ step: "sweep leaked pause-ab machines", status: "pass", ms: Date.now() - t0, detail: `${stale.length} swept of ${rows.length}` });
      } catch (e) {
        J.record({ step: "sweep leaked pause-ab machines", status: "skip", ms: Date.now() - t0, detail: String((e as Error)?.message ?? e).slice(0, 300) });
      }
    }
    usageBefore = await api.read("cloud.plan.get", {}).then((p) => Number(p?.usage?.vm_hours_used_by_you ?? NaN)).then((n) => (Number.isFinite(n) ? n : null)).catch(() => null);
    await J.step(`create ${results.length} machines`, async () => {
      await Promise.all(results.map(async (r) => {
        const v = await api.op("cloud.machine.create", { name: r.name, size: CHAT_START_SIZE }, `pab-${tag}-create-${r.name}`);
        r.id = String(v.machine?.id ?? v.machine ?? "") || null;
        if (!r.id) throw new Error(`create ${r.name} answered no machine: ${short(v)}`);
      }));
      return { value: null, detail: results.map((r) => `${r.name}=${r.id}`).join(", ") };
    });
    await J.step("running", async () => {
      await Promise.all(results.map(async (r) => {
        const t0 = Date.now();
        while (Date.now() - t0 < 300_000) {
          const m = await api.read("cloud.machine.get", { machine: r.id }).catch(() => null);
          if (m?.status === "running" && m?.host) return;
          if (m?.status === "failed") throw new Error(`${r.name} failed: ${short(m)}`);
          await sleep(1000);
        }
        throw new Error(`${r.name} not running within 300 s`);
      }));
      return { value: null, detail: "all running" };
    });
    await J.step("set pause_policy per arm", async () => {
      await Promise.all(results.map(async (r) => {
        try {
          await api.op("cloud.machine.idle_policy.set", { machine: r.id, pause_policy: r.arm }, `pab-${tag}-policy-${r.name}`);
        } catch (e) {
          r.policy_refused = String((e as Error)?.message ?? e).slice(0, 300);
          await api.op("cloud.machine.idle_policy.set", { machine: r.id, pause_policy: "aggressive" }, `pab-${tag}-policy-fallback-${r.name}`);
        }
        const m = await api.read("cloud.machine.get", { machine: r.id });
        r.effective_policy = m?.pause_policy ?? null;
      }));
      return { value: null, detail: results.map((r) => `${r.name}: ${r.effective_policy}${r.policy_refused ? " (asked policy refused)" : ""}`).join("; ") };
    });
    await J.step("model stub and build commit", async () => {
      await Promise.all(results.map(async (r) => {
        for (const [p, data] of [[`${STUB_DIR}/pab-model-stub.py`, readFileSync(MODEL_STUB_PY)], [`${STUB_DIR}/pab-model-stub.json`, Buffer.from(JSON.stringify(JOURNEY_STUB_SCRIPT))]] as const) {
          const w = await api.raw("POST", `/v1/cloud/machines/${r.id}/fs/write`, { path: p, dataBase64: data.toString("base64"), mode: 0o644 });
          if (w.status < 200 || w.status >= 300 || w.body?.ok === false) throw new Error(`${r.name} fs/write ${p}: HTTP ${w.status}`);
        }
        const exec = directExec(api, r.id!, J);
        const s = await exec(stubStartCommand(nonce), 60_000);
        if (!s.stdout.includes("stub-ready")) throw new Error(`${r.name} stub: ${s.stdout.slice(-200)} ${s.stderr.slice(-200)}`);
        r.build_commit_start = /@@commit (\S+)/.exec((await exec(BUILD_COMMIT)).stdout)?.[1] ?? null;
      }));
      return { value: null, detail: results.map((r) => `${r.name} commit ${r.build_commit_start}`).join("; ") };
    });

    // Status sampler: one cloud.machine.get per machine every poll interval for the whole window.
    let sampling = true;
    const sampler = (async () => {
      while (sampling) {
        const at = Date.now();
        await Promise.all(results.map(async (r) => {
          const m = await api.read("cloud.machine.get", { machine: r.id }).catch(() => null);
          if (m?.status) r.samples.push({ at: Date.now(), status: String(m.status) });
        }));
        await sleep(Math.max(0, pollMs - (Date.now() - at)));
      }
    })();
    windowStart = Date.now();
    await J.step(`drive ${turnCount} turns on every machine`, async () => {
      await Promise.all(results.map((r) => runMachine(r).catch((e) => { r.error = String((e as Error)?.message ?? e).slice(0, 300); })));
      await sleep(tailS * 1000);
      return { value: null, detail: results.map((r) => `${r.name} ${r.turns_ok}/${r.turns.length} ok`).join("; ") };
    }).catch(() => undefined);
    windowEnd = Date.now();
    sampling = false;
    await sampler;
    for (const r of results) Object.assign(r, integrate(r.samples, windowStart, windowEnd));
    await Promise.all(results.map(async (r) => {
      const info = await api.read("cloud.machine.connect_info", { machine: r.id }).catch(() => null);
      if (r.capabilities === null && Array.isArray(info?.daemon?.capabilities)) {
        r.capabilities = info.daemon.capabilities;
        r.turn_end_advertised = r.capabilities!.includes(TURN_END_CAPABILITY);
      }
    }));
    usageAfter = await api.read("cloud.plan.get", {}).then((p) => Number(p?.usage?.vm_hours_used_by_you ?? NaN)).then((n) => (Number.isFinite(n) ? n : null)).catch(() => null);
    J.record({ step: "result", status: results.every((r) => r.turns_ok === r.turns.length) ? "pass" : "fail", ms: windowEnd - windowStart, detail: markdownTable(aggregate(results, arms)).split("\n").slice(2).join(" ") });
  } catch {
    // The failed step is recorded; cleanup below.
  } finally {
    await cleanup();
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
    writeOut();
  }
  console.log(`\n${markdownTable(aggregate(results, arms))}`);
  const failed = J.steps.filter((s) => s.status === "fail");
  return failed.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
