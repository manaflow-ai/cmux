/**
 * The start bench (cloud-journey.ts --start-bench N, with --preclaim): how long a fresh agent machine takes from the
 * create call to its first command, phase by phase, for each way a machine can start. Leo, 2026-11-16, on self-hosted
 * agent VMs that start in tens of seconds to minutes: "let's do all those" (fast start: measure create-to-first-command
 * from a snapshot and from a warm pool, set a target, fix the top cost, before/after from one harness).
 *
 * Paths, N samples each, one machine per sample, deleted by exact id right after it is timed:
 *   spare            the platform's create while the warm names a ready spare (the claim path: the warm pool)
 *   cold             the platform's create right after a claim emptied the pool (the answer's spare_fallback says so)
 *   snapshot         the platform's cloud.snapshot.restore of a snapshot taken once, before the samples
 *   vm-api-cold      the VM API's own POST /v1/vms from its base image (what an agent spawning VMs calls)
 *   vm-api-snapshot  the VM API's POST /v1/vms with snapshotId (a memory snapshot taken once, before the samples)
 *
 * Phases, each from the moment the create request is sent:
 *   answer     the create call answered with a machine id
 *   running    the machine reads running (with a host, on the platform)
 *   exec       the first command (`echo ok`) came back through the exec route: create-to-first-command
 *   daemon     the guest's agent daemon answers (`cmux-tui acp status`), what a chat start needs (platform paths)
 * A sample's class comes from the create's answer, never from what the bench asked for: a cold create that took a spare
 * is reported as a spare sample (and the other way round), so a pool that refilled early never skews a path.
 */

export const START_PATHS = ["spare", "cold", "snapshot", "vm-api-cold", "vm-api-snapshot"] as const;
export type StartPath = (typeof START_PATHS)[number];
export const START_PHASES = ["answer", "running", "exec", "daemon"] as const;
export type StartPhase = (typeof START_PHASES)[number];

export type StartExec = (command: string, timeoutMs?: number) => Promise<{ code: number; stdout: string; stderr: string }>;

/** One timed start. Phase values are ms since the create was sent; null when the phase was not reached or not checked. */
export type StartSample = {
  path: StartPath;
  /** The path the bench asked for; differs from `path` when the answer showed another (a cold create that took a spare). */
  asked: StartPath;
  run: number;
  ok: boolean;
  error: string | null;
  ms: Record<StartPhase, number | null>;
  /** exec attempts before the first that answered, and daemon checks before the first that passed. */
  exec_attempts: number;
  daemon_attempts: number;
  /** Public facts from the create's answer: spare fallback, skips, claimed one roll behind. */
  facts: Record<string, unknown>;
};

/** A `running` read that saw the machine fail: the sample ends at once. */
export class MachineFailed extends Error {}

/** What the bench needs of one path: the create, one status read, the exec route, the delete. */
export type StartTarget = {
  path: StartPath;
  /** Before the timed create, not timed: e.g. wait for the warm to name a ready spare. Its facts join the sample's. */
  prepare?: (run: number) => Promise<Record<string, unknown>>;
  create: (run: number) => Promise<{ machine: string; path?: StartPath; facts?: Record<string, unknown> }>;
  running: (machine: string) => Promise<boolean>;
  exec: (machine: string) => StartExec;
  /** The guest daemon check; absent when this path's image has no agent daemon to check (the VM API's base image). */
  daemon?: boolean;
  /** After the timed phases, before the remove, untimed: the platform's kept create trace (traceFacts). A failure is no failure. */
  trace?: (machine: string) => Promise<StartTrace | null>;
  remove: (machine: string) => Promise<void>;
};

export type StartClock = { now: () => number; sleep: (ms: number) => Promise<void> };

const realClock: StartClock = { now: () => performance.now(), sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };

/** The guest daemon check: exits 0 and prints daemon-ok once `acp status` answers. */
export const DAEMON_CHECK =
  'export HOME="${HOME:-/home/cmux}"; c=cmux-tui; [ -x "$HOME/.cmux/bin/cmux-tui" ] && c="$HOME/.cmux/bin/cmux-tui"; ' +
  'timeout 10 "$c" acp status --json >/dev/null 2>&1 && echo daemon-ok';

export const POLL_MS = 500;
export const SAMPLE_BUDGET_MS = 300_000;

/**
 * Times one start on `target`: create, then each phase in order, polling every POLL_MS within SAMPLE_BUDGET_MS. The
 * machine is removed at the end whatever happened, and a failed phase leaves the later ones null with the error.
 */
export async function timeStart(target: StartTarget, run: number, clock: StartClock = realClock, budgetMs = SAMPLE_BUDGET_MS): Promise<StartSample> {
  const sample: StartSample = { path: target.path, asked: target.path, run, ok: false, error: null, ms: { answer: null, running: null, exec: null, daemon: null }, exec_attempts: 0, daemon_attempts: 0, facts: {} };
  let machine: string | null = null;
  try {
    if (target.prepare) Object.assign(sample.facts, await target.prepare(run));
    const t0 = clock.now();
    const since = () => Math.round(clock.now() - t0);
    const left = () => budgetMs - (clock.now() - t0);
    const made = await target.create(run);
    machine = made.machine;
    sample.ms.answer = since();
    if (made.path) sample.path = made.path;
    Object.assign(sample.facts, made.facts ?? {});
    for (;;) {
      // A read that failed is read again; a machine that failed ends the sample now, not at the budget.
      const up = await target.running(machine).catch((e) => {
        if (e instanceof MachineFailed) throw e;
        return false;
      });
      if (up) break;
      if (left() <= 0) throw new Error(`not running within ${budgetMs} ms`);
      await clock.sleep(POLL_MS);
    }
    sample.ms.running = since();
    const exec = target.exec(machine);
    for (;;) {
      sample.exec_attempts++;
      const r = await exec("echo ok", 20_000).catch((e) => ({ code: -1, stdout: "", stderr: String((e as Error)?.message ?? e) }));
      if (r.code === 0 && r.stdout.includes("ok")) break;
      if (left() <= 0) throw new Error(`no exec answer within ${budgetMs} ms: ${r.stderr.slice(0, 200)}`);
      await clock.sleep(POLL_MS);
    }
    sample.ms.exec = since();
    if (target.daemon) {
      for (;;) {
        sample.daemon_attempts++;
        const r = await exec(DAEMON_CHECK, 30_000).catch((e) => ({ code: -1, stdout: "", stderr: String((e as Error)?.message ?? e) }));
        if (r.code === 0 && r.stdout.includes("daemon-ok")) break;
        if (left() <= 0) throw new Error(`guest daemon not answering within ${budgetMs} ms`);
        await clock.sleep(POLL_MS);
      }
      sample.ms.daemon = since();
    }
    sample.ok = true;
  } catch (error) {
    sample.error = String((error as Error)?.message ?? error).slice(0, 400);
  } finally {
    if (machine !== null && target.trace) {
      const trace = await target.trace(machine).catch(() => null);
      if (trace) sample.facts.trace = trace;
    }
    if (machine !== null) await target.remove(machine).catch(() => undefined);
  }
  return sample;
}

/** The value at quantile q of sorted values (nearest rank); null with none. */
export function quantile(values: number[], q: number): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * q) - 1))]!;
}

export type PathSummary = { path: StartPath; samples: number; failed: number; phases: Record<StartPhase, { p50: number | null; p90: number | null }> };

/** p50 and p90 per phase per path, over the samples that reached the phase. */
export function summarize(samples: StartSample[]): PathSummary[] {
  return START_PATHS.flatMap((path) => {
    const mine = samples.filter((s) => s.path === path);
    if (!mine.length) return [];
    const phases = Object.fromEntries(START_PHASES.map((phase) => {
      const values = mine.flatMap((s) => (s.ms[phase] === null ? [] : [s.ms[phase]!]));
      return [phase, { p50: quantile(values, 0.5), p90: quantile(values, 0.9) }];
    })) as PathSummary["phases"];
    return [{ path, samples: mine.length, failed: mine.filter((s) => !s.ok).length, phases }];
  });
}

const sec = (ms: number | null) => (ms === null ? "-" : `${(ms / 1000).toFixed(1)} s`);

/** The table for a job summary or an issue comment: p50 / p90 per phase per path, then every sample. */
export function startBenchMarkdown(samples: StartSample[], header = "Start bench"): string {
  const rows = summarize(samples).map((s) =>
    `| ${s.path} | ${s.samples} | ${s.failed} | ${START_PHASES.map((p) => `${sec(s.phases[p].p50)} / ${sec(s.phases[p].p90)}`).join(" | ")} |`);
  const each = samples.map((s) =>
    `| ${s.path}${s.asked !== s.path ? ` (asked ${s.asked})` : ""} | ${s.run} | ${s.ok ? "ok" : "fail"} | ${START_PHASES.map((p) => sec(s.ms[p])).join(" | ")} | ${s.exec_attempts}/${s.daemon_attempts} | ${(s.error ?? "").replace(/\|/g, "\\|").slice(0, 160)} |`);
  return [
    `### ${header}`,
    "",
    "Each phase is time since the create was sent, p50 / p90. exec = create-to-first-command (`echo ok`); daemon = the guest's agent daemon answers.",
    "",
    `| Path | Samples | Failed | ${START_PHASES.join(" | ")} |`,
    `|---|---:|---:|${START_PHASES.map(() => "---:").join("|")}|`,
    ...rows,
    "",
    "<details><summary>Every sample</summary>",
    "",
    `| Path | Run | Result | ${START_PHASES.join(" | ")} | Attempts (exec/daemon) | Error |`,
    `|---|---:|---|${START_PHASES.map(() => "---:").join("|")}|---|---|`,
    ...each,
    "",
    "</details>",
    "",
    ...traceStepMarkdown(samples),
  ].join("\n");
}

/**
 * Which path a platform create's answer shows: a claim object is a spare it took; a spare_fallback names why it took
 * none (a cold create). Neither: unknown, so the bench keeps the path it asked for.
 */
export function answeredPath(answer: unknown): "spare" | "cold" | null {
  const v = answer && typeof answer === "object" ? (answer as Record<string, unknown>) : {};
  if (v.claim && typeof v.claim === "object" && !Array.isArray(v.claim)) return "spare";
  if (typeof v.spare_fallback === "string" && v.spare_fallback !== "") return "cold";
  return null;
}

/**
 * A platform machine's kept create trace (cmux-platform GET /v1/machines/{id}?include=trace answers `createTrace`, a
 * PassTrace: attempt, outcome, steps as ms since the submit's entry, totalMs). For a claimed spare the steps are the
 * claim's (capability, budget, plan_read, ..., adopt). Only finite numbers are kept; no trace reads null.
 */
export type StartTrace = { outcome: string | null; attempt: number | null; totalMs: number | null; steps: Record<string, number> };
export function traceFacts(view: unknown): StartTrace | null {
  const t = view && typeof view === "object" ? (view as Record<string, unknown>).createTrace : undefined;
  if (!t || typeof t !== "object" || Array.isArray(t)) return null;
  const v = t as Record<string, unknown>;
  const raw = v.steps && typeof v.steps === "object" && !Array.isArray(v.steps) ? (v.steps as Record<string, unknown>) : {};
  const steps = Object.fromEntries(Object.entries(raw).filter((e): e is [string, number] => typeof e[1] === "number" && Number.isFinite(e[1])));
  const num = (x: unknown) => (typeof x === "number" && Number.isFinite(x) ? x : null);
  if (!Object.keys(steps).length && num(v.totalMs) === null) return null;
  return { outcome: typeof v.outcome === "string" ? v.outcome : null, attempt: num(v.attempt), totalMs: num(v.totalMs), steps };
}

/** p50 of each kept trace step per path (steps in the order the samples first show them), and of totalMs. */
export function traceStepSummary(samples: StartSample[]): Array<{ path: StartPath; traced: number; steps: Array<{ step: string; p50: number | null }> }> {
  return START_PATHS.flatMap((path) => {
    const traces = samples.flatMap((s) => {
      const t = s.path === path ? (s.facts.trace as StartTrace | undefined) : undefined;
      return t && typeof t === "object" && t.steps ? [t] : [];
    });
    if (!traces.length) return [];
    const names: string[] = [];
    for (const t of traces) for (const name of Object.keys(t.steps)) if (!names.includes(name)) names.push(name);
    const steps = names.map((step) => ({ step, p50: quantile(traces.flatMap((t) => (typeof t.steps[step] === "number" ? [t.steps[step]!] : [])), 0.5) }));
    steps.push({ step: "totalMs", p50: quantile(traces.flatMap((t) => (t.totalMs === null ? [] : [t.totalMs])), 0.5) });
    return [{ path, traced: traces.length, steps }];
  });
}

/** The extra table under the start bench: per path, the p50 of each create trace step (ms since the submit's entry). */
export function traceStepMarkdown(samples: StartSample[]): string[] {
  const rows = traceStepSummary(samples);
  if (!rows.length) return [];
  return [
    "Platform create trace, p50 per step in ms since the submit's entry (GET /v1/machines/{id}?include=trace; read after the timed phases):",
    "",
    "| Path | Traced | Step | p50 |",
    "|---|---:|---|---:|",
    ...rows.flatMap((r) => r.steps.map((s) => `| ${r.path} | ${r.traced} | ${s.step} | ${s.p50 === null ? "-" : `${Math.round(s.p50)} ms`} |`)),
    "",
  ];
}

/**
 * The VM API's tenant for a Stack session (workers/cmux-vm/src/auth/middleware.ts fromSession): a Stack team id in
 * X-Cmux-Team-Id that Stack lists the user in (credentials.ts makeStackTeamMembership). The platform's personal_team
 * (`team_<hex>`, backend domains/user.ts personalTeamIdFor) is never one, so the VM API answers 403 "You are not a
 * member of this team" to it. From the user's Stack teams (GET /api/v1/teams?user_id=me): the cmux VM personal tenant
 * the platform made for this user (client_read_only_metadata.cmuxVmPersonalTenant), else the Stack-selected team,
 * else the first. None: the VM API paths are skipped with the reason.
 */
export function pickVmApiTenant(teams: unknown, selected: unknown): { team: string; via: string } | { team: null; why: string } {
  const items = Array.isArray((teams as { items?: unknown } | null)?.items) ? ((teams as { items: unknown[] }).items) : null;
  if (!items) return { team: null, why: "Stack answered no team list for the session" };
  const ids = items.flatMap((t) => {
    const row = t && typeof t === "object" ? (t as Record<string, unknown>) : {};
    const id = row.id;
    if (typeof id !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(id)) return [];
    const meta = row.client_read_only_metadata;
    const personal = !!meta && typeof meta === "object" && (meta as Record<string, unknown>).cmuxVmPersonalTenant === true;
    return [{ id, personal }];
  });
  const personal = ids.find((t) => t.personal);
  if (personal) return { team: personal.id, via: "the user's cmux VM personal tenant" };
  const chosen = ids.find((t) => t.id === selected);
  if (chosen) return { team: chosen.id, via: "the user's selected Stack team" };
  if (ids[0]) return { team: ids[0].id, via: "the user's first Stack team" };
  return { team: null, why: "the account is in no Stack team, and the VM API takes a session only for a Stack team it is in (workers/cmux-vm/src/auth/middleware.ts fromSession)" };
}
