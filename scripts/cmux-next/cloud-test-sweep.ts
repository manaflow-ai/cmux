#!/usr/bin/env bun
/**
 * The staging agent test account's leftover sweep: delete its machines that have sat paused or idle for a day.
 *
 *   bun scripts/cmux-next/cloud-test-sweep.ts --backend staging [--min-age-hours 24] [--dry-run] [--out DIR]
 *
 * Every Cloud check that signs in as the staging agent test account (CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD:
 * cloud-harness-matrix.yml, cloud-claude-matrix.yml, the count probe, start benches, hand runs with --keep) shares its
 * teams' 300-machine cap, and paused machines count toward it. On 2026-11-25 the cap was full (cloud.quota.vm_limit
 * "this team has its limit of 300 machines (paused ones count)", cloud-harness-matrix run 45529118600), which turned
 * start results into quota refusals. A journey run sweeps only its own `cloud journey auto jr-<tag>` names
 * (staleJourneyMachines), so any other name a run leaves behind stayed forever.
 *
 * This account belongs to tests only, so its machines are all test machines; age and state decide, not the name. A
 * machine is deleted when it was created more than --min-age-hours ago (default 24) and either is not running
 * (paused, stopped, failed, error) or is running with no activity (`last_active_at`) in that window. A row with no
 * created_at, a running machine with recent or unknown activity, and a deleting or deleted row are kept. It sweeps
 * the account's personal scope and every team user.teams.list returns; on a shared team, only machines whose `creator` is
 * the test account itself (another member's machine is never touched, and a shared team is skipped when the account's
 * own user id is unknown). Production is refused.
 *
 * It also takes the journey-owned leftovers younger than the window, by the journey's own sweep rule
 * (staleJourneyMachines: a name only a run that deletes its machine gives, past that run's bound, in any state), with
 * the same creator filter. A journey sweeps them too, but only once a journey gets that far: 2026-11-28 07:12Z the
 * staging test team held 102 machines, none a day old (this sweep picked 0), its owner object answered
 * cloud.machine.list "Durable Object exceeded its CPU time limit", and the relay deploy's journey-staging failed twice
 * on exec 503 vm_unavailable (overloaded) (run 46115218791).
 *
 * --out DIR gets sweep.json (every scope's counts, each deleted machine and its answer) and summary.md, the table of
 * what it deleted. Secrets are sent only in headers or bodies and scrubbed from every line printed. It fails when a
 * delete is refused (a leftover that cannot go is a red run, not a silent one).
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { STACK, STACK_API, listAllMachines, resolveBackend, scrub, staleJourneyMachines } from "./cloud-journey.ts";

type Answer = { status: number; body: any };

export const DEFAULT_MIN_AGE_HOURS = 24;
/** One run's ceiling: well above the 300 cap, so one run can clear a full team, and bounded if the list misreads. */
export const MAX_DELETES = 400;
/** Statuses that hold the cap without running: deleted at age alone. */
export const IDLE_STATUSES = new Set(["paused", "stopped", "failed", "error", "suspended", "hibernated"]);
export const RUNNING_STATUSES = new Set(["running", "starting", "provisioning", "creating", "resuming"]);

export interface SweepPick { id: string; name: string; status: string; created: string; last_active: string | null; why: string }

const iso = (ms: unknown) => (typeof ms === "number" && Number.isFinite(ms) ? new Date(ms).toISOString() : null);

/**
 * The rows to delete: created more than `minAgeMs` before `nowMs`, and paused (or otherwise not running), or running
 * with its last activity older than `minAgeMs`. Unknown statuses are kept, so a new state never gets swept by mistake.
 * With `creator`, only rows whose `creator` is that user id are picked (a shared team's other members' machines stay).
 */
export function stalePicks(rows: any[], nowMs: number, minAgeMs: number, creator: string | null = null): SweepPick[] {
  const out: SweepPick[] = [];
  for (const r of rows) {
    if (!r || typeof r !== "object") continue;
    // On a shared team only the test account's own machines go: a row another member created is never picked.
    if (creator !== null && String(r.creator ?? "") !== creator) continue;
    const status = String(r.status ?? "");
    if (status === "deleted" || status === "deleting") continue;
    const id = String(r.id ?? r.machine_id ?? "");
    if (!id) continue;
    if (typeof r.created_at !== "number" || !Number.isFinite(r.created_at) || nowMs - r.created_at <= minAgeMs) continue;
    const last = typeof r.last_active_at === "number" && Number.isFinite(r.last_active_at) ? r.last_active_at : null;
    let why: string | null = null;
    if (IDLE_STATUSES.has(status)) why = `${status}, created ${Math.floor((nowMs - r.created_at) / 3_600_000)} h ago`;
    else if (RUNNING_STATUSES.has(status) && last !== null && nowMs - last > minAgeMs) why = `${status} with no activity for ${Math.floor((nowMs - last) / 3_600_000)} h`;
    if (!why) continue;
    out.push({ id, name: String(r.name ?? ""), status, created: iso(r.created_at)!, last_active: iso(last), why });
  }
  return out;
}

/**
 * stalePicks, then the journey-owned rows staleJourneyMachines takes that stalePicks left (younger than the window),
 * under the same creator filter, so a journey's leaked machines go within its own bound instead of a day.
 */
export function sweepPicks(rows: any[], nowMs: number, minAgeMs: number, creator: string | null = null): SweepPick[] {
  const out = stalePicks(rows, nowMs, minAgeMs, creator);
  const have = new Set(out.map((p) => p.id));
  const mine = rows.filter((r) => r && typeof r === "object" && (creator === null || String(r.creator ?? "") === creator));
  const byId = new Map(mine.map((r) => [String(r.id ?? r.machine_id ?? ""), r]));
  for (const m of staleJourneyMachines(mine, nowMs)) {
    if (have.has(m.id)) continue;
    const r = byId.get(m.id);
    const last = typeof r?.last_active_at === "number" && Number.isFinite(r.last_active_at) ? r.last_active_at : null;
    out.push({ id: m.id, name: m.name, status: m.status, created: m.created, last_active: iso(last), why: `journey-owned ${m.status}, past its run's bound` });
    have.add(m.id);
  }
  return out;
}

/** Count rows by status, for the record of what each scope held before and after. */
export function statusCounts(rows: any[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of rows) {
    const s = String(r?.status ?? "?");
    out[s] = (out[s] ?? 0) + 1;
  }
  return out;
}

/** The summary table: one row per deleted (or, with --dry-run, picked) machine. */
export function summaryMarkdown(report: { backend: string; dry_run: boolean; min_age_hours: number; scopes: Array<{ scope: string; before: Record<string, number>; picks: Array<SweepPick & { ok?: boolean; error?: string | null }> }> }): string {
  const total = report.scopes.reduce((n, s) => n + s.picks.length, 0);
  const lines = [
    `### Staging test account sweep (${report.backend}${report.dry_run ? ", dry run" : ""})`,
    "",
    `Machines paused or idle for more than ${report.min_age_hours} h: ${total} ${report.dry_run ? "picked (none deleted)" : "deleted or tried"}.`,
    "",
    "| scope | held before (by status) | picked |",
    "|---|---|---:|",
    ...report.scopes.map((s) => `| ${s.scope} | ${Object.entries(s.before).map(([k, v]) => `${k} ${v}`).join(", ") || "none"} | ${s.picks.length} |`),
    "",
  ];
  if (total) {
    lines.push("| scope | machine | name | status | created | last active | result |", "|---|---|---|---|---|---|---|");
    for (const s of report.scopes) for (const p of s.picks) lines.push(`| ${s.scope} | ${p.id} | ${p.name.replace(/\|/g, "/")} | ${p.status} | ${p.created} | ${p.last_active ?? ""} | ${report.dry_run ? "picked" : p.ok ? "deleted" : `refused: ${p.error ?? "?"}`} |`);
    lines.push("");
  }
  return lines.join("\n");
}

async function http(method: string, url: string, body: unknown, headers: Record<string, string>, timeoutMs = 60_000): Promise<Answer> {
  try {
    const res = await fetch(url, {
      method,
      headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await res.text();
    try { return { status: res.status, body: text ? JSON.parse(text) : {} }; } catch { return { status: res.status, body: { raw: text.slice(0, 300) } }; }
  } catch (e) {
    return { status: 0, body: { ok: false, error: { code: "transport", message: String((e as Error).message).slice(0, 200), retryable: true } } };
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Tries of one /v1/read before the sweep gives up on it. */
export const READ_TRIES = 3;

/** A read answer worth sending again: no answer (transport), a 429 or 5xx, or one the API marks retryable. */
export function retryableRead(r: Answer): boolean {
  return r.status === 0 || r.status === 429 || r.status >= 500 || r.body?.error?.retryable === true;
}

/**
 * One /v1/read, sent up to `tries` times while its answer is retryable (reads change nothing, so a resend is safe).
 * Run 46130928568 (2026-11-28 09:32Z) went red on one cloud.machine.list that timed out at 30 s, answered as
 * {"code":"transport","retryable":true}: the staging test team's owner object was CPU-bound (see the header), and
 * the sweep read it once. A refusal that is not retryable, or the last try's answer, still throws.
 */
export async function readWithRetry(send: () => Promise<Answer>, name: string, tries = READ_TRIES, backoffMs = 5_000, wait: (ms: number) => Promise<unknown> = sleep): Promise<any> {
  let r: Answer = { status: 0, body: {} };
  for (let attempt = 1; attempt <= tries; attempt++) {
    r = await send();
    if (r.status === 200 && r.body?.ok !== false) return r.body.value;
    if (!retryableRead(r) || attempt === tries) break;
    await wait(backoffMs * attempt);
  }
  throw new Error(`${name}: HTTP ${r.status} ${JSON.stringify(r.body?.error ?? r.body).slice(0, 300)}${tries > 1 && retryableRead(r) ? ` (after ${tries} tries)` : ""}`);
}
/** Tries of one cloud.machine.delete (same idempotency key each time) before the sweep reads where the machine stands. */
export const DELETE_TRIES = 3;

/**
 * One cloud.machine.delete, resent under its idempotency key while its answer can still change (5xx, 409, 423, 429,
 * no answer). A machine already gone (404, not_found) counts as deleted. If the last answer is
 * `mutation.indeterminate` (the provider call was cut off and may have acted; cloud-machine-ops.ts PROVIDER) or a
 * transport failure, the machine is read again: deleting, deleted or no longer listed counts as deleted, anything
 * else stays refused, naming the status read. Run 46140030779 (2026-11-28 11:28Z) went red on one failed journey
 * machine whose three deletes all answered mutation.indeterminate, with no read of where the machine stood after.
 */
export async function deleteMachine(send: () => Promise<Answer>, recheck: () => Promise<string | null>, tries = DELETE_TRIES, wait: (ms: number) => Promise<unknown> = sleep): Promise<{ ok: boolean; error: string | null }> {
  let error = "";
  for (let attempt = 1; attempt <= tries; attempt++) {
    const a = await send();
    const code = String(a.body?.error?.code ?? "");
    if ((a.status === 200 && a.body?.ok === true) || a.status === 404 || /not[_.-]?found/i.test(code)) return { ok: true, error: null };
    error = code || `HTTP ${a.status}`;
    if (a.status >= 400 && a.status < 500 && ![409, 423, 429].includes(a.status)) return { ok: false, error };
    if (attempt < tries) await wait(2000 * attempt);
  }
  if (error !== "mutation.indeterminate" && error !== "transport") return { ok: false, error };
  const status = await recheck().catch(() => "unread");
  if (status === null || status === "deleting" || status === "deleted") return { ok: true, error: null };
  return { ok: false, error: `${error} (still ${status || "?"})` };
}
const argValue = (flag: string, argv: string[]) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : undefined; };

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging", argValue("--api", argv), argValue("--stack", argv));
  if (backend.name === "prod" || backend.stack === "prod" || /^https:\/\/cloud-api\.cmux\.dev\b/.test(backend.api)) throw new Error("production is out of scope: this sweeps the staging agent test account only");
  const hours = Number(argValue("--min-age-hours", argv) ?? DEFAULT_MIN_AGE_HOURS);
  if (!Number.isFinite(hours) || hours < 6) throw new Error(`--min-age-hours ${hours}: at least 6, so a running check never loses its machine`);
  const dryRun = argv.includes("--dry-run");
  const outDir = argValue("--out", argv) ? path.resolve(argValue("--out", argv)!) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
  const secrets = [password, email];
  const say = (line: string) => console.log(scrub(line, secrets));
  const tag = `ts-${Date.now().toString(36)}`;

  const stack = STACK[backend.stack];
  const signIn = await http("POST", `${STACK_API}/api/v1/auth/password/sign-in`, { email, password }, {
    "x-stack-access-type": "client",
    "x-stack-project-id": stack.project,
    ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
  });
  if (signIn.status !== 200 || typeof signIn.body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${signIn.status} ${String(signIn.body?.code ?? "")}`);
  secrets.push(signIn.body.access_token, String(signIn.body.refresh_token ?? ""));
  const bearer = { authorization: `Bearer ${signIn.body.access_token}` };
  const headers = (team: string | null) => ({ ...bearer, ...(team ? { "x-cmux-team": team } : {}) });
  const read = (team: string | null, name: string, params: unknown) =>
    readWithRetry(() => http("POST", `${backend.api}/v1/read`, { op: name, params }, headers(team), 30_000), name);
  const op = (team: string | null, name: string, params: unknown, key: string) => http("POST", `${backend.api}/v1/ops`, { op: name, params, idempotency_key: key }, headers(team));

  const ensure = await op(null, "user.ensure", {}, `${tag}-ensure`);
  const v = ensure.body?.value;
  const me: string | null = typeof v?.id === "string" ? v.id : typeof v?.user?.id === "string" ? v.user.id : typeof v?.user_id === "string" ? v.user_id : null;
  say(JSON.stringify({ user_ensure: ensure.status, user_known: me !== null }));
  const teams: Array<{ scope: string; team: string | null }> = [{ scope: "personal", team: null }];
  const listed = await read(null, "user.teams.list", {}).catch((e) => { say(`user.teams.list failed, personal scope only: ${(e as Error).message}`); return null; });
  for (const t of Array.isArray(listed?.teams) ? listed.teams : []) {
    if (t?.kind === "personal" || typeof t?.id !== "string") continue;
    if (me === null) { say(`skipping shared team ${t.id}: the account's user id is unknown, so its own machines cannot be told apart`); continue; }
    teams.push({ scope: t.id, team: t.id });
  }

  const now = Date.now();
  const minAgeMs = hours * 3_600_000;
  const report = { backend: backend.name, api: backend.api, tag, dry_run: dryRun, min_age_hours: hours, scopes: [] as Array<{ scope: string; before: Record<string, number>; picks: Array<SweepPick & { ok?: boolean; error?: string | null }> }> };
  let budget = MAX_DELETES;
  let refused = 0;
  for (const { scope, team } of teams) {
    const rows = await listAllMachines((p) => read(team, "cloud.machine.list", p), 40, { partial: true });
    const picks = sweepPicks(rows, now, minAgeMs, team === null ? null : me).slice(0, budget);
    budget -= picks.length;
    const entry = { scope, before: statusCounts(rows), picks: picks as Array<SweepPick & { ok?: boolean; error?: string | null }> };
    report.scopes.push(entry);
    say(JSON.stringify({ scope, held: rows.length, by_status: entry.before, picked: picks.length }));
    if (dryRun) continue;
    for (const p of entry.picks) {
      const recheck = async () => {
        const now = await listAllMachines((q) => read(team, "cloud.machine.list", q), 40, { partial: true });
        const r = now.find((x: any) => String(x?.id ?? x?.machine_id ?? "") === p.id);
        return r ? String(r.status ?? "") : null;
      };
      Object.assign(p, await deleteMachine(() => op(team, "cloud.machine.delete", { machine: p.id }, `${tag}-delete-${p.id}`), recheck));
      if (!p.ok) refused++;
      say(JSON.stringify({ delete: p.id, name: p.name, status: p.status, created: p.created, ok: p.ok, error: p.error }));
    }
  }
  if (outDir) {
    writeFileSync(path.join(outDir, "sweep.json"), scrub(JSON.stringify(report, null, 2), secrets));
    writeFileSync(path.join(outDir, "summary.md"), scrub(summaryMarkdown(report), secrets));
  }
  const picked = report.scopes.reduce((n, s) => n + s.picks.length, 0);
  say(`${refused ? "FAIL" : "PASS"} ${dryRun ? "picked" : "deleted"} ${picked - refused} of ${picked} paused or idle past ${hours} h${refused ? `; ${refused} refused` : ""}`);
  return refused ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
