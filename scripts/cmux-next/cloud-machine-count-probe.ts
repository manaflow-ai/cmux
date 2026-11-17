#!/usr/bin/env bun
/**
 * The Cloud machine-count probe: can a paid personal account hold a sixth machine?
 *
 *   bun scripts/cmux-next/cloud-machine-count-probe.ts --backend staging --count 6 --out DIR
 *
 * Before cmux-platform#1134, paid plans were refused past five machines with `cloud.quota.exceeded`. Now the counts
 * are unlimited wherever the spending cap holds machines and the usage ledger meters them (CLOUD_SPEND_CAP=on and
 * CLOUD_USAGE_LEDGER=on, staging today), and CLOUD_CREATE_PER_HOUR (default 20) is the create guard.
 *
 * It signs in as the staging agent test account (CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, whose
 * `pro` operator plan cloud-capture-provision.yml grants), acts in its personal scope (no team header), reads the
 * plan (`cloud.plan.get`) and the machines it already holds, then creates --count machines (default 6, at most 10)
 * one after another, recording each create's answer and how many machines the account held right before it. It
 * stops at the first refusal. First it deletes machines an earlier probe left behind (its exact name, over an hour
 * old). Every machine it made is then deleted by its exact id, pass or fail (also on SIGINT or SIGTERM), and read
 * back until the list no longer has it live.
 *
 * Pass: a create was accepted while the account already held five or more machines, and every machine this run made
 * is gone. Production is refused: its ledger is off, so the old counts apply there by design.
 *
 * --out DIR gets probe.json (plan, machines held before, each create's answer, each delete's read back) and
 * summary.md. Secrets are sent only in headers or bodies and scrubbed from every line printed.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { STACK, STACK_API, listAllMachines, resolveBackend, scrub } from "./cloud-journey.ts";

type Answer = { status: number; body: any };

/** The count the old paid caps refused past: a create accepted at this many held machines or more proves the lift. */
export const OLD_PAID_MAX = 5;
export const MAX_COUNT = 10;

export type CreateRecord = { n: number; held_before: number; status: number; ok: boolean; machine: string | null; machine_status: string | null; error: { code: string; message: string } | null };

/** The verdict over the creates: the first one accepted while OLD_PAID_MAX or more machines were held, or why not. */
export function countVerdict(creates: CreateRecord[]): { pass: boolean; why: string; proof: CreateRecord | null } {
  const proof = creates.find((c) => c.ok && c.machine && c.held_before >= OLD_PAID_MAX) ?? null;
  if (proof) return { pass: true, why: `create ${proof.n} accepted with ${proof.held_before} machines already held (${proof.machine})`, proof };
  const refused = creates.find((c) => !c.ok);
  if (refused) return { pass: false, why: `create ${refused.n} refused with ${refused.held_before} held: HTTP ${refused.status} ${refused.error?.code ?? "?"} ${refused.error?.message ?? ""}`.trim(), proof: null };
  const most = Math.max(0, ...creates.map((c) => c.held_before));
  return { pass: false, why: `no create ran with ${OLD_PAID_MAX} or more held (at most ${most}); raise --count`, proof: null };
}

/** Machines that count against a team's machine cap: every row the list shows that is not deleted or deleting. */
export const liveMachines = (rows: any[]) => rows.filter((m) => m && m.status !== "deleted" && m.status !== "deleting");

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
const retryable = (a: Answer) => a.status === 0 || (a.body?.ok !== true && a.body?.error?.code === "mutation.indeterminate" && a.body?.error?.retryable === true);
const argValue = (flag: string, argv: string[]) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : undefined; };

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const backend = resolveBackend(argValue("--backend", argv) ?? "staging", argValue("--api", argv), argValue("--stack", argv));
  if (backend.name === "prod" || backend.stack === "prod" || /^https:\/\/cloud-api\.cmux\.dev\b/.test(backend.api)) throw new Error("production is out of scope: its usage ledger is off, so the old paid counts apply there by design");
  const count = Number(argValue("--count", argv) ?? 6);
  if (!Number.isInteger(count) || count < 1 || count > MAX_COUNT) throw new Error(`--count ${count}: a whole number from 1 to ${MAX_COUNT}`);
  const outDir = argValue("--out", argv) ? path.resolve(argValue("--out", argv)!) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
  const secrets = [password];
  const say = (line: string) => console.log(scrub(line, secrets));
  const tag = `cp-${Date.now().toString(36)}`;
  const report: Record<string, unknown> = { backend: backend.name, api: backend.api, tag, scope: "personal", count };

  const health = await http("GET", `${backend.api}/v1/health`, undefined, {});
  report.health = { status: health.status, commit: health.body?.commit ?? health.body?.version ?? null };
  say(JSON.stringify({ health: report.health }));

  const stack = STACK[backend.stack];
  const signIn = await http("POST", `${STACK_API}/api/v1/auth/password/sign-in`, { email, password }, {
    "x-stack-access-type": "client",
    "x-stack-project-id": stack.project,
    ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
  });
  if (signIn.status !== 200 || typeof signIn.body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${signIn.status} ${String(signIn.body?.code ?? "")}`);
  secrets.push(signIn.body.access_token, String(signIn.body.refresh_token ?? ""));
  // Personal scope: no x-cmux-team, so every call acts on the account's own (personal) team.
  const auth = { authorization: `Bearer ${signIn.body.access_token}` };
  const op = (name: string, params: unknown, key?: string) => http("POST", `${backend.api}/v1/ops`, { op: name, params, ...(key ? { idempotency_key: key } : {}) }, auth);
  const read = async (name: string, params: unknown) => {
    const r = await http("POST", `${backend.api}/v1/read`, { op: name, params }, auth, 30_000);
    if (r.status !== 200 || r.body?.ok === false) throw new Error(`${name}: HTTP ${r.status} ${JSON.stringify(r.body?.error ?? r.body).slice(0, 300)}`);
    return r.body.value;
  };
  const list = async () => liveMachines(await listAllMachines((p) => read("cloud.machine.list", p)));

  const ensure = await op("user.ensure", {}, `${tag}-ensure`);
  say(JSON.stringify({ user_ensure: { status: ensure.status, ok: ensure.body?.ok === true, user: ensure.body?.value?.id ?? ensure.body?.value?.user?.id ?? null } }));
  const plan = await read("cloud.plan.get", {}).catch((e) => ({ error: String((e as Error).message) }));
  report.plan = plan;
  say(JSON.stringify({ plan }));

  const before = await list();
  report.held_before = before.map((m) => ({ id: m.id, name: m.name ?? null, status: m.status ?? null }));
  say(JSON.stringify({ held_before: before.length, machines: report.held_before }));

  const creates: CreateRecord[] = [];
  const made: string[] = [];
  const names = Array.from({ length: count }, (_, i) => `cloud count probe ${tag} ${i + 1}`);
  report.creates = creates;
  const deletes: Array<Record<string, unknown>> = [];
  report.deletes = deletes;
  let stopping = false;
  // A create whose outcome is unknown (cut off, or indeterminate after its retries) may still land a machine.
  let unsure = false;
  const removed = new Set<string>();

  // A machine this run made: an id a create answered, or (its answer lost) a live row under one of its exact names.
  const adopt = (rows: any[]) => { for (const m of rows) if (names.includes(m.name) && m.id && !made.includes(m.id)) made.push(m.id); };
  // Delete by id under one key, retrying any refusal but not-found within the budget: a machine still provisioning
  // may refuse its delete for a moment. 404 / not found is gone.
  const remove = async (id: string, budgetMs: number) => {
    removed.add(id);
    const key = `${tag}-delete-${id}`;
    const until = Date.now() + budgetMs;
    let a: Answer = { status: 0, body: {} };
    for (let attempt = 1; ; attempt++) {
      a = await op("cloud.machine.delete", { machine: id }, key);
      const gone = a.status === 404 || /not[_.-]?found/i.test(String(a.body?.error?.code ?? ""));
      // A 4xx other than conflict, locked or rate limited is a final refusal: retrying it only burns the job's time.
      const final = a.status >= 400 && a.status < 500 && ![409, 423, 429].includes(a.status);
      if ((a.status === 200 && a.body?.ok === true) || gone || final || Date.now() + 3000 > until) break;
      await sleep(Math.min(3000 * attempt, 15_000));
    }
    const rec = { id, status: a.status, ok: a.body?.ok === true, error: a.body?.ok === true ? null : a.body?.error?.code ?? null };
    deletes.push(rec);
    say(JSON.stringify({ delete: id, status: a.status, ok: rec.ok, error: a.body?.ok === true ? null : a.body?.error ?? null }));
  };

  // Earlier probe runs cut off before their cleanup (a cancelled job gets seconds): their `cloud count probe cp-<tag>`
  // machines, by that exact name, whose tag is more than an hour old. Never any other name.
  const stale = before.filter((m) => {
    const t = /^cloud count probe cp-([0-9a-z]+) \d+$/.exec(String(m.name ?? ""));
    const at = t ? parseInt(t[1], 36) : NaN;
    return Number.isFinite(at) && at > Date.UTC(2026, 0, 1) && Date.now() - at > 3_600_000;
  });
  for (const m of stale) {
    say(JSON.stringify({ sweep: m.id, name: m.name, status: m.status }));
    await remove(String(m.id), 60_000);
  }
  report.swept = stale.map((m) => m.id);

  let cleaning: Promise<void> | null = null;
  // One cleanup, awaited by both the end of the run and a signal. `fast` (a signal: the runner kills the job seconds
  // later) sends every delete at once and reads back for 20 s; otherwise up to 3 min per delete and 5 min of read back.
  const cleanup = (fast: boolean) => (cleaning ??= (async () => {
    stopping = true;
    // A signal leaves seconds: the known ids' deletes go out before any list read.
    if (fast) { await Promise.all(made.map((id) => remove(id, 10_000))); write(); }
    adopt(await list().catch(() => [] as any[]));
    if (fast) await Promise.all(made.filter((id) => !removed.has(id)).map((id) => remove(id, 5_000)));
    else for (const id of made) if (!removed.has(id)) await remove(id, 180_000);
    // Read back: gone when the live list no longer has it (deleted or deleting do not count). Each pass also adopts a
    // machine whose create answer was lost and whose row has only now appeared (or a create that answered after a
    // signal), and deletes it. With an unsure create it keeps looking for at least a minute.
    const until = Date.now() + (fast ? 20_000 : 300_000);
    const settle = Date.now() + (unsure && !fast ? 60_000 : 0);
    let left = [...made];
    while (Date.now() < until) {
      const rows = await list().catch(() => null);
      if (rows) {
        adopt(rows);
        for (const id of made) if (!removed.has(id)) await remove(id, fast ? 5_000 : 60_000);
        const live = new Set(rows.map((m) => m.id));
        left = made.filter((id) => live.has(id));
        if (!left.length && Date.now() >= settle) break;
      }
      await sleep(5000);
    }
    report.not_gone = left;
    say(JSON.stringify({ deleted: made.length - left.length, of: made.length, not_gone: left }));
  })());
  const write = () => {
    if (!outDir) return;
    writeFileSync(path.join(outDir, "probe.json"), scrub(JSON.stringify(report, null, 2), secrets));
    const v = report.verdict as { pass: boolean; why: string } | undefined;
    const notGone = (report.not_gone as string[] | undefined) ?? made;
    const rows = creates.map((c) => `| ${c.n} | ${c.held_before} | ${c.status} | ${c.ok ? "accepted" : "refused"} | ${c.machine ?? ""} | ${c.error ? `${c.error.code}: ${c.error.message}` : c.machine_status ?? ""} |`);
    writeFileSync(path.join(outDir, "summary.md"), scrub([
      `### Cloud machine-count probe (${backend.name}, personal scope)`,
      "",
      `Verdict: **${v?.pass && !notGone.length ? "PASS" : "FAIL"}**: ${v?.why ?? "did not finish"}`,
      "",
      `Held before: ${before.length}. Backend commit: ${String((report.health as any)?.commit ?? "?")}.`,
      "",
      "| create | held before | HTTP | answer | machine | detail |",
      "|---|---|---|---|---|---|",
      ...rows,
      "",
      `Made: ${made.join(", ") || "none"}. Not gone: ${notGone.join(", ") || "none"}.`,
      "",
    ].join("\n"), secrets));
  };
  // A cancelled or timed-out job gets SIGINT, then SIGTERM, then SIGKILL within seconds.
  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      stopping = true;
      report.verdict ??= countVerdict(creates);
      void cleanup(true).finally(() => { write(); process.exit(sig === "SIGINT" ? 130 : 143); });
    });
  }

  try {
    for (let n = 1; n <= count && !stopping; n++) {
      // The live count right before the create: the account is shared with other staging runs.
      const live = await list();
      adopt(live);
      const held = live.length;
      let a: Answer = { status: 0, body: {} };
      for (let attempt = 1; attempt <= 3; attempt++) {
        a = await op("cloud.machine.create", { name: names[n - 1], size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-create-${n}`);
        if (!retryable(a)) break;
        await sleep(2000 * attempt);
      }
      const ok = a.status === 200 && a.body?.ok === true;
      if (retryable(a)) unsure = true;
      const id = ok ? String(a.body.value?.machine?.id ?? "") || null : null;
      if (id && !made.includes(id)) made.push(id);
      const rec: CreateRecord = { n, held_before: held, status: a.status, ok, machine: id, machine_status: ok ? a.body.value?.machine?.status ?? null : null, error: ok ? null : { code: String(a.body?.error?.code ?? "?"), message: String(a.body?.error?.message ?? "").slice(0, 300) } };
      creates.push(rec);
      say(JSON.stringify({ create: rec, ...(ok ? {} : { details: a.body?.error?.details ?? null }) }));
      if (!ok) break;
    }
  } finally {
    report.verdict ??= countVerdict(creates);
    await cleanup(false);
    write();
  }
  const v = report.verdict as { pass: boolean; why: string };
  const notGone = (report.not_gone as string[] | undefined) ?? made;
  say(`${v.pass && !notGone.length ? "PASS" : "FAIL"} ${v.why}; ${made.length - notGone.length} of ${made.length} made deleted`);
  return v.pass && !notGone.length ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
