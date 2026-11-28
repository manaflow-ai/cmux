#!/usr/bin/env bun
/**
 * executor.sh on a cmux Cloud machine, end to end: one command checks that Executor (npm `executor@beta`,
 * github.com/UsefulSoftwareCo/executor) installs, starts and runs a real job inside a machine of the NEXT Cloud.
 *
 *   bun scripts/cmux-next/executor-journey.ts --backend staging --out /tmp/exj
 *   bun scripts/cmux-next/executor-journey.ts --backend staging --machine vm_...   (an existing machine, kept)
 *
 * It signs in as the agent test account the way cloud-journey.ts does (CMUX_DOGFOOD_STACK_EMAIL and
 * CMUX_DOGFOOD_STACK_PASSWORD from the environment or a KEY=value --credentials file, or --sign-in oidc in a GitHub
 * Actions job), then:
 *
 *   health -> sign in -> user.ensure -> sweep leaked cmux-test-exec machines -> create machine `cmux-test-exec-<tag>`
 *   -> running -> first exec -> Executor job (executor-journey-guest.sh over machine exec: install, start the
 *   background server, add DeepWiki's keyless MCP server as an app, deploy it, `executor execute` a program that
 *   calls tools.deepwiki.read_wiki_structure) -> result checked -> delete (always, by exact id)
 *
 * The result must be `status: completed`, `execution.ok: true`, one successful `deepwiki.read_wiki_structure` call
 * and a non-empty page list. Every guest phase becomes its own step with its time. Each step prints PASS/FAIL/SKIP;
 * --out DIR also gets journey.json and summary.md (cloud-journey.ts's format). Exit 0 only when no step failed.
 *
 * A run killed before its cleanup leaves its machine: before create, machines named `cmux-test-exec-<tag>` whose tag
 * (Date.now() in base 36) is more than 3 hours old and with no activity for an hour are deleted, each logged first.
 * Any other name is never touched. --executor-version V pins the Executor release (default: its newest beta).
 */
import { readFileSync } from "node:fs";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  Api, IDLE_JOURNEY_MS, Journey, STACK, STALE_JOURNEY_MS, directExec, http, listAllMachines, oidcSignIn, passwordSignIn,
  readEnvFile, resolveBackend, sharedCleanup,
} from "./cloud-journey.ts";

export const GUEST_SCRIPT = fileURLToPath(new URL("./executor-journey-guest.sh", import.meta.url));
export const MACHINE_PREFIX = "cmux-test-exec-";
const MACHINE_SIZE = Object.freeze({ cpu: 2, memory_mb: 4096, disk_mb: 16384 });
const GUEST_BUDGET_MS = 290_000;

const argValue = (flag: string, argv: string[]): string | undefined => {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
};
const short = (v: unknown) => JSON.stringify(v ?? null).slice(0, 300);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Machines an earlier executor journey left behind: our exact name shape, tag older than maxAgeMs, idle for an hour. */
export function staleExecutorMachines(rows: any[], nowMs: number, maxAgeMs = STALE_JOURNEY_MS): { id: string; name: string }[] {
  const out: { id: string; name: string }[] = [];
  for (const r of rows) {
    if (!r || r.status === "deleted" || r.status === "deleting") continue;
    const m = /^cmux-test-exec-([0-9a-z]+)$/.exec(typeof r.name === "string" ? r.name : "");
    if (!m) continue;
    const started = parseInt(m[1], 36);
    if (!Number.isFinite(started) || started < Date.UTC(2020, 0, 1) || started > nowMs || nowMs - started <= maxAgeMs) continue;
    if (typeof r.last_active_at === "number" && nowMs - r.last_active_at <= IDLE_JOURNEY_MS) continue;
    const id = String(r.id ?? r.machine_id ?? "");
    if (id) out.push({ id, name: r.name });
  }
  return out;
}

export type GuestPhase = { phase: string; ok: boolean; detail: string };

/** The guest script's `EXJ <phase> ok|fail <detail>` lines and its `EXJ result <json>` line. */
export function parseGuest(stdout: string): { phases: GuestPhase[]; result: any | null; host: string } {
  const phases: GuestPhase[] = [];
  let result: any | null = null;
  let host = "";
  for (const line of stdout.split("\n")) {
    const m = /^EXJ (\S+) (.*)$/.exec(line.trim());
    if (!m) continue;
    if (m[1] === "result") {
      try { result = JSON.parse(m[2]); } catch { result = { unparsed: m[2].slice(0, 300) }; }
    } else if (m[1] === "host") host = m[2];
    else {
      const s = /^(ok|fail) ?(.*)$/.exec(m[2]);
      if (s) phases.push({ phase: m[1], ok: s[1] === "ok", detail: s[2] });
    }
  }
  return { phases, result, host };
}

/** Why the job's answer is not the real job's result, or null when it is. */
export function resultProblem(result: any): string | null {
  if (!result) return "no `EXJ result` line";
  if (result.status !== "completed") return `status ${short(result.status)}: ${short(result)}`;
  const ex = result.execution;
  if (ex?.ok !== true) return `execution not ok: ${short(ex)}`;
  const call = (ex.toolCalls ?? []).find((c: any) => c?.name === "deepwiki.read_wiki_structure");
  if (!call || call.outcome !== "success") return `no successful deepwiki.read_wiki_structure call: ${short(ex.toolCalls)}`;
  if (!(Number(ex.value?.pages) > 0) || ex.value?.mentionsOverview !== true) return `empty wiki structure: ${short(ex.value)}`;
  return null;
}

/** The job result's verdict when a guest phase failed: a DeepWiki outage is named as the third party's, not Executor's. */
export function phaseProblem(p: GuestPhase): string {
  return p.phase === "deepwiki"
    ? `not run: DeepWiki (mcp.deepwiki.com, a third party) is down, not Executor: ${p.detail}`
    : `Executor phase ${p.phase} failed: ${p.detail}`;
}

/** The exec that runs the guest script: shipped inline (base64), in a fresh home of its own under /tmp. */
export function guestCommand(script: string, version?: string): string {
  const b64 = Buffer.from(script).toString("base64");
  const pin = version && /^[0-9A-Za-z.+-]{1,64}$/.test(version) ? `EXECUTOR_VERSION=${version} ` : "";
  return `d=$(mktemp -d /tmp/executor-journey.XXXXXX) && echo ${b64} | base64 -d > "$d/guest.sh" && ${pin}EXECUTOR_JOURNEY_HOME="$d/home" sh "$d/guest.sh" 2>&1`;
}

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
  const reuse = argValue("--machine", argv);
  const version = argValue("--executor-version", argv) ?? (process.env.EXECUTOR_VERSION || undefined);
  const tag = Date.now().toString(36);
  const name = `${MACHINE_PREFIX}${tag}`;
  const run = process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : "local";
  const J = new Journey(backend, outDir, { tag, machine: reuse ?? name, executor: version ?? "newest beta", run });
  if (password) J.secrets.push(password);
  const api = new Api(backend.api, team);
  let machine: string | null = reuse ?? null;

  const cleanup = sharedCleanup(async () => {
    if (reuse || !api.bearer) return;
    // A create whose answer was lost still made a machine under this run's exact name.
    let target = machine;
    if (!target) {
      const rows = await listAllMachines((p) => api.read("cloud.machine.list", p)).catch(() => []);
      target = rows.find((r: any) => r?.name === name && r.status !== "deleted")?.id ?? null;
    }
    if (!target) return;
    const id = target;
    await J.step("delete (cleanup)", async () => {
      await api.deleteMachine(id, `exj-${tag}-delete`);
      return { value: null, detail: id };
    }).catch(() => undefined);
  });
  const onSignal = (signal: string) => {
    void cleanup().finally(() => {
      J.flush();
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGINT", onSignal);
  try {
    await J.step("health", async () => {
      const r = await http("GET", `${backend.api}/v1/health`, undefined, {});
      if (r.status !== 200) throw new Error(`HTTP ${r.status} ${short(r.body)}`);
      return { value: null, detail: `commit ${r.body.commit ?? r.body.version ?? "?"}` };
    });
    api.bearer = await J.step("sign in (agent test account)", async () => {
      if (signIn === "oidc") {
        const s = await oidcSignIn(backend.api, process.env, J.secrets);
        return { value: s.token, detail: `GitHub OIDC, user ${s.user}` };
      }
      if (!email || !password) throw new Error("no agent test account: set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD, or --credentials FILE");
      const stack = STACK[backend.stack];
      const s = await passwordSignIn(stack, email, password);
      J.secrets.push(s.access, s.refresh);
      return { value: s.access, detail: `Stack project ${stack.project.slice(0, 8)}` };
    });
    await J.step("user.ensure", async () => {
      const v = await api.op("user.ensure", {}, `exj-${tag}-ensure`);
      return { value: v, detail: `user ${v.id ?? v.user?.id ?? "?"}` };
    });
    if (!reuse) {
      const t0 = Date.now();
      try {
        const rows = await listAllMachines((p) => api.read("cloud.machine.list", p));
        const stale = staleExecutorMachines(rows, Date.now());
        const failed: string[] = [];
        for (const m of stale) {
          console.log(`sweep: deleting leaked ${m.id} (${m.name})`);
          await api.deleteMachine(m.id, `exj-${tag}-sweep-${m.id}`).catch((e) => failed.push(`${m.id}: ${String((e as Error)?.message ?? e).slice(0, 200)}`));
        }
        J.record({ step: "sweep leaked cmux-test-exec machines", status: failed.length ? "skip" : "pass", ms: Date.now() - t0, detail: `${stale.length - failed.length} of ${stale.length} deleted (${rows.length} machines)${failed.length ? `; failed ${failed.join("; ")}` : ""}` });
      } catch (e) {
        J.record({ step: "sweep leaked cmux-test-exec machines", status: "skip", ms: Date.now() - t0, detail: `list failed: ${String((e as Error)?.message ?? e).slice(0, 300)}` });
      }
      await J.step("create machine", async () => {
        const v = await api.op("cloud.machine.create", { name, size: MACHINE_SIZE }, `exj-${tag}-create`);
        machine = String(v.machine?.id ?? v.machine ?? "");
        if (!machine) throw new Error(`create answered no machine: ${short(v)}`);
        return { value: null, detail: `${machine} (${name}) status ${v.machine?.status ?? "?"}` };
      });
    }
    const id = machine!;
    await J.step("running (status)", async () => {
      const t0 = Date.now();
      let last: any = null;
      while (Date.now() - t0 < 300_000) {
        last = await api.read("cloud.machine.get", { machine: id }).catch(() => last);
        if (last?.status === "paused" && reuse) await api.op("cloud.machine.start", { machine: id }, `exj-${tag}-wake`);
        if (last?.status === "running" && last?.host) return { value: last, detail: `host ${last.host}` };
        if (last?.status === "failed") throw new Error(`machine failed: ${short(last)}`);
        await sleep(1000);
      }
      throw new Error(`timed out; last status ${last?.status}`);
    });
    const exec = directExec(api, id, J);
    await J.step("first exec", async () => {
      const r = await exec("echo exj-ok; uname -m; id -un; command -v curl tar sh base64 | tr '\\n' ' '");
      if (r.code !== 0 || !r.stdout.includes("exj-ok")) throw new Error(`exit ${r.code} ${r.stdout.slice(-200)} ${r.stderr.slice(-200)}`);
      return { value: null, detail: r.stdout.replace(/\s+/g, " ").trim() };
    });
    // One exec runs the whole guest script; each of its phases is recorded as its own step after.
    const r = await J.step("Executor: guest script", async () => {
      const r = await exec(guestCommand(readFileSync(GUEST_SCRIPT, "utf8"), version), GUEST_BUDGET_MS);
      return { value: r, detail: `${parseGuest(r.stdout).host}; exit ${r.code}` };
    });
    const g = parseGuest(r.stdout);
    for (const p of g.phases) J.record({ step: `Executor: ${p.phase}`, status: p.ok ? "pass" : "fail", ms: 0, detail: p.detail });
    await J.step("Executor: job result", async () => {
      const failedPhase = g.phases.find((p) => !p.ok);
      const problem = failedPhase ? phaseProblem(failedPhase)
        : r.code !== 0 ? `guest exit ${r.code}: ${r.stdout.slice(-400)} ${r.stderr.slice(-200)}`
        : resultProblem(g.result);
      if (problem) throw new Error(problem);
      const call = g.result.execution.toolCalls.find((c: any) => c.name === "deepwiki.read_wiki_structure");
      return { value: null, detail: `deepwiki.read_wiki_structure ${call.durationMs} ms; ${g.result.execution.value.pages} pages of UsefulSoftwareCo/executor` };
    });
  } catch {
    // The failed step is recorded; cleanup below.
  } finally {
    await cleanup();
    process.off("SIGTERM", onSignal);
    process.off("SIGINT", onSignal);
  }
  const failed = J.steps.filter((s) => s.status === "fail");
  console.log(`\n${failed.length ? "FAIL" : "PASS"} executor journey on ${backend.name}: ${J.steps.length - failed.length} passed or skipped, ${failed.length} failed`);
  return failed.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
