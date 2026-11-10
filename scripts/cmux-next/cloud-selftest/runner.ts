/**
 * Runs scenarios: provisions each named actor once per run (its fixture identity, its cmux account, its team role),
 * then walks each scenario's steps through the action catalogue and records every step's outcome and latency.
 */
import { Actor } from "./actors";
import { ACTIONS, resolve, runAction, type ActionDef, type RunCtx } from "./actions";
import { judge, interpolate, pick, scenarioOutcome, type ActionResult, type ActorSpec, type Lane, type Need, type Scenario, type ScenarioRecord, type Step, type StepRecord } from "./engine";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Every actor name means one role in the whole catalogue (the run provisions it once). */
export function actorRoles(scenarios: Scenario[]): Map<string, ActorSpec["team_role"]> {
  const roles = new Map<string, ActorSpec["team_role"]>();
  const kinds = new Map<string, string>();
  for (const s of scenarios) {
    for (const a of s.actors) {
      const had = roles.get(a.name);
      if (roles.has(a.name) && had !== (a.team_role ?? null)) throw new Error(`actor ${a.name} is ${had ?? "no member"} in one scenario and ${a.team_role ?? "no member"} in ${s.name}`);
      const kind = a.kind ?? "fixture";
      if (kinds.has(a.name) && kinds.get(a.name) !== kind) throw new Error(`actor ${a.name} is a ${kinds.get(a.name)} actor in one scenario and a ${kind} actor in ${s.name}`);
      kinds.set(a.name, kind);
      roles.set(a.name, a.team_role ?? null);
    }
  }
  return roles;
}

/** Problems with a catalogue: unknown actions, steps by actors the scenario does not declare. */
export function lintScenarios(scenarios: Scenario[], actions: Record<string, ActionDef> = ACTIONS): string[] {
  const out: string[] = [];
  const names = new Set<string>();
  for (const s of scenarios) {
    if (names.has(s.name)) out.push(`${s.name}: named twice`);
    names.add(s.name);
    const actors = new Set(s.actors.map((a) => a.name));
    const kindOf = new Map(s.actors.map((a) => [a.name, a.kind ?? "fixture"]));
    for (const [i, st] of [...s.steps, ...(s.finally ?? [])].entries()) {
      const def = actions[st.action];
      if (!def) out.push(`${s.name} step ${i}: no action ${st.action}`);
      if (st.actor !== "harness" && !actors.has(st.actor)) out.push(`${s.name} step ${i}: actor ${st.actor} is not declared`);
      // An app verb answers as the app's signed-in person: no other actor can run it.
      if (def?.on === "app" && kindOf.get(st.actor) !== "app") out.push(`${s.name} step ${i}: ${st.action} needs the app actor (it runs in the tagged app)`);
      if (def?.on === "app" && !(s.needs ?? []).includes("app")) out.push(`${s.name}: runs ${st.action} but does not need app`);
    }
    for (const a of s.actors) if ((a.kind ?? "fixture") !== "fixture" && a.team_role) out.push(`${s.name}: ${a.kind} actor ${a.name} has no team role`);
    if (!s.covers.length) out.push(`${s.name}: covers nothing`);
    if (s.actors.some((a) => a.team_role && a.team_role !== "owner") && !s.actors.some((a) => a.team_role === "owner")) out.push(`${s.name}: has team members but no owner`);
  }
  try {
    actorRoles(scenarios);
  } catch (e) {
    out.push(String((e as Error).message));
  }
  return out;
}

/** The lanes a scenario waits on: the lanes of its actions that have no route today. */
export function pendingLanes(s: Scenario, actions: Record<string, ActionDef> = ACTIONS): Lane[] {
  const lanes = new Set<Lane>();
  for (const st of s.steps) {
    const d = actions[st.action];
    if (d && d.lane !== "base" && !d.api && !d.harness) lanes.add(d.lane);
  }
  return [...lanes].sort();
}

export type Abilities = { [K in Need]: boolean | string };

/** Provision one actor (once per run): fixture identity, cmux account, team role. */
export async function provision(ctx: RunCtx, spec: ActorSpec): Promise<Actor> {
  const existing = ctx.actors.get(spec.name);
  if (existing) return existing;
  const kind = spec.kind ?? "fixture";
  if (kind !== "fixture") {
    const actor = new Actor(spec, ctx.dir, ctx.api);
    if (kind === "app") {
      if (!ctx.app) throw new Error("app.unavailable: no tagged app for the app actor");
      actor.app = ctx.app;
    }
    ctx.actors.set(spec.name, actor);
    ctx.vars[spec.name] = {};
    return actor;
  }
  if (!ctx.fixtures) throw new Error("no fixtures provider");
  const actor = new Actor(spec, ctx.dir, ctx.api);
  const u = await ctx.fixtures.user(spec.name);
  ctx.users.set(spec.name, u);
  actor.identity = { email: u.email, stack_user: u.stack_user, access_token: u.access_token, refresh_token: u.refresh_token };
  const ensured = await actor.op("user.ensure", {}, `${ctx.run}-ensure-${spec.name}`, { team: null });
  if (!ensured.ok) throw new Error(`user.ensure for ${spec.name}: ${ensured.code} ${ensured.message ?? ""}`);
  actor.identity.user = String(ensured.json?.id ?? ensured.json?.user?.id ?? "");
  const role = spec.team_role ?? null;
  if (role === "owner") {
    if (ctx.team) throw new Error("one owner per run: the team exists already");
    ctx.team = await ctx.fixtures.team(u, `Self-test ${ctx.run}`);
    actor.team = ctx.team.team;
  } else if (role) {
    if (!ctx.team) throw new Error(`${spec.name} needs the team's owner provisioned first`);
    await ctx.fixtures.setRole(ctx.team, u, role);
    actor.team = ctx.team.team;
  }
  if (role && ctx.team) await waitTeamListed(actor, ctx.team.team, ctx.fixtures.synced ? 15_000 : 120_000);
  ctx.actors.set(spec.name, actor);
  ctx.vars[spec.name] = { user: actor.identity.user, email: u.email };
  if (ctx.team) ctx.vars.team = ctx.team.team;
  return actor;
}

/**
 * Until the actor's user.teams.list names the team (harness wait). Its first call is also what makes the API read the
 * person's teams from the sign-in service and sync one TeamDO never heard of (user-teams.ts heal) when no webhook came.
 */
export async function waitTeamListed(actor: Actor, team: string, budgetMs: number, every = 3_000): Promise<number> {
  const t0 = Date.now();
  let last = "";
  for (;;) {
    const r = await actor.read("user.teams.list", {}, { team: null });
    if (r.ok && (r.json?.teams ?? []).some((t: any) => t?.id === team)) return Date.now() - t0;
    last = r.ok ? `listed ${(r.json?.teams ?? []).map((t: any) => t.id).join(",")}` : `${r.code}`;
    if (Date.now() - t0 + every > budgetMs) throw new Error(`team.not_synced: ${actor.name}'s team list did not name ${team} within ${budgetMs} ms (${last})`);
    await sleep(every);
  }
}

/** Owner first: the team must exist before a member joins it. */
export const provisionOrder = (specs: ActorSpec[]) => [...specs].sort((a, b) => Number(b.team_role === "owner") - Number(a.team_role === "owner"));

const unavailable = new WeakMap<RunCtx, Map<string, string>>();

export async function runScenario(s: Scenario, ctx: RunCtx, can: Abilities, actions: Record<string, ActionDef> = ACTIONS): Promise<ScenarioRecord> {
  const t0 = Date.now();
  const steps: StepRecord[] = [];
  const lanes = pendingLanes(s, actions);
  const done = (reason: string): ScenarioRecord => {
    const outcome = scenarioOutcome(steps);
    return { name: s.name, outcome, ms: Date.now() - t0, reason: outcome === "pass" ? "" : reason, pending_lanes: lanes, covers: s.covers, steps };
  };
  const missing = (s.needs ?? []).filter((n) => can[n] !== true);
  if (missing.length) {
    steps.push({ scenario: s.name, index: -1, label: "needs", actor: "harness", action: "-", outcome: "skip", ms: 0, detail: missing.map((n) => `${n}: ${can[n] === false ? "not here" : can[n]}`).join("; ") });
    return done(steps[0]!.detail);
  }
  for (const spec of provisionOrder(s.actors)) {
    const p0 = Date.now();
    const known = unavailable.get(ctx)?.get(spec.name);
    try {
      if (known) throw new Error(known);
      await provision(ctx, spec);
    } catch (e) {
      const detail = String((e as Error).message).slice(0, 400);
      // The backend's sign-in project cannot express this role (no such team permission): a limit of where this runs,
      // not a product failure. Remembered, so later scenarios do not make another identity to learn it again.
      const limit = detail.startsWith("fixtures.role_unavailable");
      if (limit) unavailable.set(ctx, (unavailable.get(ctx) ?? new Map()).set(spec.name, detail));
      steps.push({ scenario: s.name, index: -1, label: `provision ${spec.name}`, actor: spec.name, action: "fixtures", outcome: limit ? "skip" : "fail", ms: Date.now() - p0, detail });
      return done(limit ? detail : `provisioning ${spec.name} failed`);
    }
  }
  // Per scenario: its own agent session name on any machine it makes.
  ctx.vars.session = `st-${ctx.run}-${s.name.replace(/[^a-z0-9]+/gi, "-")}`.slice(0, 60);
  ctx.vars.run = ctx.run;
  let stopped: string | null = null;
  let concurrent: Array<Promise<StepRecord>> = [];
  const flush = async () => {
    for (const rec of await Promise.all(concurrent)) {
      steps.push(rec);
      if (rec.outcome !== "pass" && !stopped) stopped = `step ${rec.index} (${rec.label}) ${rec.outcome}`;
    }
    concurrent = [];
  };
  for (const [i, st] of s.steps.entries()) {
    if (!st.concurrent) await flush();
    if (stopped) {
      steps.push(skipped(s, i, st, `after ${stopped}`));
      continue;
    }
    const p = runStep(s, i, st, ctx, actions);
    if (st.concurrent) {
      concurrent.push(p);
      continue;
    }
    const rec = await p;
    steps.push(rec);
    if (rec.outcome !== "pass") stopped = `step ${i} (${rec.label}) ${rec.outcome}`;
  }
  await flush();
  const main = done(stopped ?? "");
  const before = main.outcome;
  for (const [j, st] of (s.finally ?? []).entries()) {
    // A cleanup step runs pass or fail; one whose variables never got set (the machine was never made) is skipped.
    main.steps.push(await runStep(s, s.steps.length + j, st, ctx, actions, true));
  }
  // A failed cleanup fails a scenario that had passed; it never hides why one failed or waits.
  main.outcome = before === "pass" ? scenarioOutcome(main.steps.filter((x) => x.outcome !== "skip" || x.index < s.steps.length)) : before;
  main.ms = Date.now() - t0;
  if (main.outcome !== "pass" && !main.reason) main.reason = main.steps.find((x) => x.outcome !== "pass")?.detail ?? "";
  return main;
}

const label = (st: Step) => st.label ?? `${st.actor}: ${st.action}`;
const skipped = (s: Scenario, i: number, st: Step, why: string): StepRecord => ({ scenario: s.name, index: i, label: label(st), actor: st.actor, action: st.action, outcome: "skip", ms: 0, detail: why });

export async function runStep(s: Scenario, i: number, st: Step, ctx: RunCtx, actions: Record<string, ActionDef> = ACTIONS, cleanup = false): Promise<StepRecord> {
  const base = { scenario: s.name, index: i, label: label(st), actor: st.actor, action: st.action };
  const def = actions[st.action];
  if (!def) return { ...base, outcome: "fail", ms: 0, detail: `no action ${st.action}` };
  const actor = st.actor === "harness" ? harnessActor(ctx) : ctx.actors.get(st.actor);
  if (!actor) return { ...base, outcome: "fail", ms: 0, detail: `actor ${st.actor} was not provisioned` };
  // A step that cannot run here (its lane's verb is not in this cmux) is PENDING whatever its arguments would be.
  const pre = resolve(def, {}, ctx, actor);
  if (pre.kind === "pending") return { ...base, outcome: "pending", ms: 0, detail: `PENDING-${pre.lane}: ${pre.why}` };
  if (pre.kind === "skip") return { ...base, outcome: "skip", ms: 0, detail: pre.why };
  let args: Record<string, any>;
  let expect = st.expect;
  try {
    args = interpolate(st.args ?? {}, ctx.vars) as Record<string, any>;
    if (expect?.json !== undefined) expect = { ...expect, json: interpolate(expect.json, ctx.vars) as any };
  } catch (e) {
    return { ...base, outcome: cleanup ? "skip" : "fail", ms: 0, detail: String((e as Error).message) };
  }
  const how = resolve(def, args, ctx, actor);
  if (how.kind === "pending") return { ...base, outcome: "pending", ms: 0, detail: `PENDING-${how.lane}: ${how.why}` };
  if (how.kind === "skip") return { ...base, outcome: "skip", ms: 0, detail: how.why };
  const t0 = Date.now();
  const deadline = t0 + (expect?.within_ms ?? 0);
  let tries = 0;
  let result: ActionResult;
  let why: string | null;
  for (;;) {
    tries++;
    try {
      result = await runAction(def, args, ctx, actor, how);
    } catch (e) {
      result = { ok: false, code: "harness.error", message: String((e as Error).message), json: null, transport: how.kind === "cli" ? "cli" : how.kind === "api" ? "api" : "harness" };
    }
    why = judge(result, expect);
    // Harness-only bounded wait for converging state (CONTEXT: no product polling; this is the test's own wait).
    if (!why || Date.now() >= deadline) break;
    await sleep(expect?.every_ms ?? 2_000);
  }
  const ms = Date.now() - t0;
  if (!why && st.save) for (const [name, at] of Object.entries(st.save)) ctx.vars[name] = pick(result.json, at);
  const via = result.transport === "api" && def.cli ? ` (via the route; \`cmux ${def.verb?.join(" ")}\` PENDING-${def.lane})` : "";
  return {
    ...base,
    outcome: why ? "fail" : "pass",
    ms,
    transport: result.transport,
    ...(result.code ? { code: result.code } : {}),
    tries,
    detail: why ? `${why}${via}` : `${result.ok ? "ok" : `refused ${result.code}`}${via}`,
  };
}

/** "harness" steps (fixtures, local stub, local gateways) run as the run's owner identity when there is one. */
function harnessActor(ctx: RunCtx): Actor {
  return ctx.actors.get("owner") ?? [...ctx.actors.values()][0] ?? new Actor({ name: "harness" }, ctx.dir, ctx.api);
}
