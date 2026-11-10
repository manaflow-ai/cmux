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
 * one after another, recording each create's answer and how many machines the account held before it. It stops at
 * the first refusal. Every machine it made is then deleted by its exact id, pass or fail (also on SIGTERM), and read
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
  const proof = creates.find((c) => c.ok && c.held_before >= OLD_PAID_MAX) ?? null;
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
  if (backend.name === "prod" || backend.stack === "prod") throw new Error("production is out of scope: its usage ledger is off, so the old paid counts apply there by design");
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

  let cleaned = false;
  const cleanup = async () => {
    if (cleaned) return;
    cleaned = true;
    // A create whose answer was lost still made a machine under its name: find those by exact name.
    const rows = await list().catch(() => [] as any[]);
    for (const m of rows) if (names.includes(m.name) && !made.includes(m.id)) made.push(m.id);
    for (const id of made) {
      const key = `${tag}-delete-${id}`;
      let a: Answer = { status: 0, body: {} };
      for (let attempt = 1; attempt <= 8; attempt++) {
        a = await op("cloud.machine.delete", { machine: id }, key);
        if (!retryable(a)) break;
        await sleep(Math.min(3000 * attempt, 15_000));
      }
      deletes.push({ id, status: a.status, ok: a.body?.ok === true, error: a.body?.ok === true ? null : a.body?.error?.code ?? null });
      say(JSON.stringify({ delete: id, status: a.status, ok: a.body?.ok === true, error: a.body?.ok === true ? null : a.body?.error ?? null }));
    }
    // Read back: gone when the live list no longer has it (deleted or deleting do not count), bounded at 5 minutes.
    const until = Date.now() + 300_000;
    let left = [...made];
    while (left.length && Date.now() < until) {
      const live = new Set((await list().catch(() => null))?.map((m) => m.id) ?? left);
      left = left.filter((id) => live.has(id));
      if (left.length) await sleep(5000);
    }
    report.not_gone = left;
    say(JSON.stringify({ deleted: made.length - left.length, not_gone: left }));
  };
  const write = () => {
    if (!outDir) return;
    writeFileSync(path.join(outDir, "probe.json"), scrub(JSON.stringify(report, null, 2), secrets));
    const v = report.verdict as { pass: boolean; why: string } | undefined;
    const rows = creates.map((c) => `| ${c.n} | ${c.held_before} | ${c.status} | ${c.ok ? "accepted" : "refused"} | ${c.machine ?? ""} | ${c.error ? `${c.error.code}: ${c.error.message}` : c.machine_status ?? ""} |`);
    writeFileSync(path.join(outDir, "summary.md"), scrub([
      `### Cloud machine-count probe (${backend.name}, personal scope)`,
      "",
      `Verdict: **${v?.pass && !(report.not_gone as string[] | undefined)?.length ? "PASS" : "FAIL"}**: ${v?.why ?? "did not finish"}`,
      "",
      `Held before: ${before.length}. Backend commit: ${String((report.health as any)?.commit ?? "?")}.`,
      "",
      "| create | held before | HTTP | answer | machine | detail |",
      "|---|---|---|---|---|---|",
      ...rows,
      "",
      `Deleted: ${deletes.filter((d) => d.ok).map((d) => d.id).join(", ") || "none"}; not gone: ${(report.not_gone as string[] | undefined)?.join(", ") || "none"}`,
      "",
    ].join("\n"), secrets));
  };
  process.on("SIGTERM", () => { void cleanup().finally(() => { write(); process.exit(143); }); });

  try {
    for (let n = 1; n <= count; n++) {
      const held = before.length + made.length;
      let a: Answer = { status: 0, body: {} };
      for (let attempt = 1; attempt <= 3; attempt++) {
        a = await op("cloud.machine.create", { name: names[n - 1], size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } }, `${tag}-create-${n}`);
        if (!retryable(a)) break;
        await sleep(2000 * attempt);
      }
      const ok = a.status === 200 && a.body?.ok === true;
      const id = ok ? String(a.body.value?.machine?.id ?? "") || null : null;
      if (id) made.push(id);
      const rec: CreateRecord = { n, held_before: held, status: a.status, ok, machine: id, machine_status: ok ? a.body.value?.machine?.status ?? null : null, error: ok ? null : { code: String(a.body?.error?.code ?? "?"), message: String(a.body?.error?.message ?? "").slice(0, 300) } };
      creates.push(rec);
      say(JSON.stringify({ create: rec, ...(ok ? {} : { details: a.body?.error?.details ?? null }) }));
      if (!ok) break;
    }
  } finally {
    report.verdict = countVerdict(creates);
    await cleanup();
    write();
  }
  const v = report.verdict as { pass: boolean; why: string };
  const notGone = report.not_gone as string[];
  say(`${v.pass && !notGone.length ? "PASS" : "FAIL"} ${v.why}; ${made.length - notGone.length} of ${made.length} made deleted`);
  return v.pass && !notGone.length ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
