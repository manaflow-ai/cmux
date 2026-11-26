#!/usr/bin/env bun
// Runnable links on staging (cmuxterm-hq#23807, RFD 0168): a link that opens a working copy of a live
// project. Measures click-to-usable for the link against today's way (a fresh machine, clone, install,
// start), on real staging machines.
//
// Setup: one parent machine; clone a real project (PROJECT_REPO at PROJECT_REF), install its deps, start
// its service, start an agent session on acpmux whose launch credential is a canary value.
// Mint: POST {platform}/v1/runnable-links (cmux-platform, RUNNABLE_LINKS on), or, where that answers 404,
// the same thing from its parts (cloud.snapshot.create): the link's version is that snapshot.
// Open, --runs times: resolve the link (no compute), fork it (POST .../fork, or cloud.snapshot.restore),
// wait running, first exec, scrub (end every process that holds a model credential in its environment:
// the copy never runs on the sender's login; acpmux keeps the session and relaunches it on the opener's
// credential at the next prompt), then usable = the service answers 200 + the smoke test passes + acpmux
// lists the session. Each phase is timed. The canary is looked for in every process environment on the
// copy before and after the scrub.
// Baseline, --baseline times: a fresh machine, clone, install, start, smoke: the same "usable".
// Negative checks (link API only): a revoked link and an expired link refuse to fork.
// Prints one JSON verdict (and writes --out).
//
//   bun scripts/cmux-next/runnable-link.ts [--backend staging] [--runs N] [--baseline N] [--out FILE] [--keep]
//
// Credentials: CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account).

import { writeFileSync } from "node:fs";
import {
  Api,
  CHAT_START_SIZE,
  STACK,
  clientPlatformOrigin,
  directExec,
  http,
  launchCredentialStartProgram,
  listAllMachines,
  passwordSignIn,
  resolveBackend,
  scrub,
  sleep,
  waitMachine,
  type Exec,
} from "./cloud-journey.ts";
import { firstExec, mintInstallToken, p95 } from "./cloud-fork-placement.ts";

const arg = (name: string, fallback?: string) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
};

export const PROJECT_REPO = "https://github.com/expressjs/express.git";
export const PROJECT_REF = "4.21.2";
export const PROJECT_DIR = "/home/cmux/project";
export const SERVICE_PORT = 3000;
export const SESSION = "runnable-link-demo";

/** Clone, install, start the service detached. Prints head=, then service= once it answers. */
export function projectSetupCommand(): string {
  return [
    "set -e",
    `rm -rf ${PROJECT_DIR}`,
    `git clone -q --depth 1 --branch ${PROJECT_REF} ${PROJECT_REPO} ${PROJECT_DIR}`,
    `cd ${PROJECT_DIR}`,
    "NODE_ENV=development npm install --include=dev --no-audit --no-fund --loglevel=error >/tmp/rl-install.log 2>&1",
    `PORT=${SERVICE_PORT} setsid node examples/hello-world >/tmp/rl-service.log 2>&1 < /dev/null &`,
    `for i in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:${SERVICE_PORT}/ && break; sleep 0.1; done`,
    `echo "head=$(git rev-parse HEAD)"`,
    `echo "service=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${SERVICE_PORT}/)"`,
  ].join("\n");
}

/** The smoke runner, one line each: test/app.js through mocha's API, resolved from the project. */
export const SMOKE_RUNNER = [
  "const M = require(require.resolve('mocha', { paths: [process.cwd()] }))",
  "const m = new M({ reporter: 'dot' })",
  "m.addFile('test/app.js')",
  "m.run((f) => process.exit(f ? 1 : 0))",
];

/** Usable: the service answers 200, the project's smoke test passes, acpmux lists the session (when one is expected). */
export function usableCommand(session: string | null): string {
  return [
    `s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${SERVICE_PORT}/ || true); echo "service=$s"`,
    // Mocha through its API, not its CLI: the CLI's old yargs loads as an ES module under Node 26 and throws.
    `printf '%s\\n' ${SMOKE_RUNNER.map((l) => `"${l}"`).join(" ")} >/tmp/rl-smoke.cjs`,
    `cd ${PROJECT_DIR} && NODE_ENV=test node /tmp/rl-smoke.cjs >/tmp/rl-smoke.log 2>&1 && echo smoke=1 || { echo smoke=0; echo "smoke_err=$(grep -m2 -E 'Error|failing' /tmp/rl-smoke.log | tr '\\n' ' ' | cut -c1-300)"; echo "node=$(node -v 2>&1)"; }`,
    `echo "head=$(git -C ${PROJECT_DIR} rev-parse HEAD 2>/dev/null)"`,
    session ? `acpmux ls 2>/dev/null | grep -q '${session}' && echo session=1 || echo session=0` : "echo session=skip",
  ].join("\n");
}

/** How many process environments on this machine hold the canary (read as the machine's user). */
export function canaryCountCommand(canary: string): string {
  return `n=0; for d in /proc/[0-9]*; do [ -O "$d" ] || continue; grep -qaF '${canary}' "$d/environ" 2>/dev/null && n=$((n+1)); done; echo "canary=$n"`;
}

/** The scrub: end every process of this user holding a model credential in its environment. */
export const SCRUB_COMMAND =
  `n=0; for d in /proc/[0-9]*; do [ -O "$d" ] || continue; p=\${d#/proc/}; [ "$p" = "$$" ] && continue; ` +
  `tr '\\0' '\\n' < "$d/environ" 2>/dev/null | grep -qE '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|OPENAI_API_KEY|CODEX_API_KEY)=' || continue; ` +
  `kill -TERM "$p" 2>/dev/null && n=$((n+1)); done; sleep 0.3; echo "scrubbed=$n"`;

export function facts(stdout: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of stdout.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

export const usable = (f: Record<string, string>, head: string) =>
  f.service === "200" && f.smoke === "1" && f.head === head && (f.session === "1" || f.session === "skip");

export type OpenRow = {
  run: number;
  quota_wait_ms?: number;
  via: "link" | "snapshot";
  copy: string | null;
  resolve_ms: number | null;
  fork_call_ms: number | null;
  running_ms: number | null;
  first_exec_ms: number | null;
  scrub_ms: number | null;
  usable_ms: number | null;
  click_to_usable_ms: number | null;
  canary_before_scrub: number | null;
  canary_after_scrub: number | null;
  facts: Record<string, string> | null;
  error: string | null;
};
export type BaselineRow = { run: number; quota_wait_ms?: number; machine: string | null; create_ms: number | null; setup_ms: number | null; usable_ms: number | null; total_ms: number | null; facts: Record<string, string> | null; error: string | null };

const median = (xs: number[]) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) / 2)];
};
const stat = (xs: (number | null)[]) => {
  const v = xs.filter((x): x is number => typeof x === "number");
  return { median: median(v), p95: p95(v), all: v };
};

export function verdict(opens: OpenRow[], baseline: BaselineRow[], meta: Record<string, unknown>) {
  const ok = opens.filter((r) => r.click_to_usable_ms !== null && r.canary_after_scrub === 0);
  const click = stat(opens.map((r) => r.click_to_usable_ms));
  const base = stat(baseline.map((r) => r.total_ms));
  return {
    kind: "runnable-link",
    ...meta,
    opens: opens.length,
    opens_usable_and_clean: ok.length,
    click_to_usable_ms: click,
    baseline_ms: base,
    speedup_p50: click.median && base.median ? Number((base.median / click.median).toFixed(2)) : null,
    phases_ms: Object.fromEntries((["resolve_ms", "fork_call_ms", "running_ms", "first_exec_ms", "scrub_ms", "usable_ms"] as const).map((k) => [k, stat(opens.map((r) => r[k]))])),
    pass: opens.length > 0 && ok.length === opens.length,
    rows: opens,
    baseline_rows: baseline,
  };
}

/** Staging's test team sits near its machine cap; a create that hits it waits for room instead of
 * failing the row (25 min, or ROOM_WAIT_MS). Returns the value and the time spent waiting, which the caller leaves out of its phase timing. */
export async function withRoom<T>(fn: () => Promise<T>, budgetMs = Number(process.env.ROOM_WAIT_MS ?? 1_500_000)): Promise<[T, number]> {
  // Returns the time spent waiting for room only: a full team (cloud.quota.vm_limit) waits and is left out of
  // the timing. A call cut off at the client timeout is asked again, at most twice, under the same idempotency
  // key, so it cannot make a second machine (runs 45570177493 and 45571955695 stopped there); that time counts.
  const t0 = Date.now();
  let roomAt = t0;
  let timeouts = 0;
  for (;;) {
    try {
      return [await fn(), roomAt - t0];
    } catch (e) {
      const m = String((e as Error).message);
      if (m.includes("cloud.quota.vm_limit") && Date.now() - t0 <= budgetMs) {
        await sleep(15_000);
        roomAt = Date.now();
        continue;
      }
      if (m.includes("timed out") && ++timeouts <= 2) {
        await sleep(2_000);
        continue;
      }
      throw e;
    }
  }
}

/**
 * Machines this script made that no one deletes otherwise: this run's (a create cut off at the client timeout can
 * still make its machine, which the run never learns the id of: runs 45570177493, 45571955695 and 45573615938), and
 * any earlier run's left over two hours or more. Every machine here is named "runnable link rl-<tag> ...".
 */
export function strays(rows: any[], tag: string, now: number, deleted: Set<string>): string[] {
  return rows
    .filter((r) => typeof r?.name === "string" && r.name.startsWith("runnable link rl-") && r.status !== "deleted" && r.status !== "deleting")
    .filter((r) => r.name.startsWith(`runnable link ${tag} `) || (typeof r.created_at === "number" && now - r.created_at >= 2 * 3600_000))
    .map((r) => String(r.id ?? r.machine_id ?? ""))
    .filter((id) => id && !deleted.has(id));
}

async function waitUsable(exec: Exec, session: string | null, head: string, budgetMs: number): Promise<Record<string, string>> {
  const t0 = Date.now();
  let f: Record<string, string> = {};
  while (Date.now() - t0 < budgetMs) {
    f = facts((await exec(usableCommand(session), 90_000).catch((e) => ({ stdout: `error=${(e as Error).message}` }))).stdout);
    if (usable(f, head)) return f;
    await sleep(500);
  }
  throw new Error(`not usable in ${budgetMs} ms: ${JSON.stringify(f)}`);
}

async function main(): Promise<number> {
  const backend = resolveBackend(arg("--backend", "staging")!);
  const runs = Math.max(1, Math.min(10, Number(arg("--runs", "10"))));
  const baselineRuns = Math.max(0, Math.min(10, Number(arg("--baseline", "3"))));
  const keep = process.argv.includes("--keep");
  const team = arg("--team") || undefined;
  const secrets: string[] = [];
  const api = new Api(backend.api, team);
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL;
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD;
  if (!email || !password) throw new Error("set CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the staging agent test account)");
  secrets.push(password);
  // Each step names itself, so a bare "The operation timed out." says where (run 45570177493 did not).
  let stage = "sign-in";
  const s = await passwordSignIn(STACK[backend.stack], email, password);
  secrets.push(s.access, s.refresh);
  api.bearer = s.access;
  const say = (v: unknown) => console.log(scrub(typeof v === "string" ? v : JSON.stringify(v), secrets));
  stage = "client-config";
  const platform = clientPlatformOrigin((await api.raw("GET", "/v1/client-config", undefined, 30_000)).body);
  const tag = `rl-${Date.now().toString(36)}`;
  stage = "user.ensure";
  const user = await api.op("user.ensure", {}, `${tag}-ensure`);
  stage = "install token";
  const install = await mintInstallToken(api, backend.api, String(user?.id ?? user?.user?.id ?? ""), tag, team);
  secrets.push(install.token);
  let bearer = install.token;
  const renew = async () => { bearer = await install.renew(); secrets.push(bearer); };
  const ph = () => ({ authorization: `Bearer ${bearer}`, ...(team ? { "x-cmux-team": team } : {}) });
  const journey = { secrets };
  const canary = `sk-ant-canary-${tag}-${Math.random().toString(36).slice(2, 12)}`;
  const cleanup: string[] = [];
  const machines: string[] = [];
  const opens: OpenRow[] = [];
  const baseline: BaselineRow[] = [];
  const negative: Record<string, unknown> = {};
  const meta: Record<string, unknown> = { backend: backend.name, project: `${PROJECT_REPO}@${PROJECT_REF}`, tag };
  let snapshot: string | null = null;
  let link: any = null;
  let parent: string | null = null;
  try {
    // Parent: a real project, its service running, an agent session holding the canary as its launch credential.
    stage = "parent create";
    const t0 = Date.now();
    const [created] = await withRoom(() => api.op("cloud.machine.create", { name: `runnable link ${tag} parent`, size: CHAT_START_SIZE }, `${tag}-parent`));
    parent = String(created?.machine?.id ?? created?.machine ?? created?.id);
    machines.push(parent);
    await waitMachine(api, parent, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
    const pexec = directExec(api, parent, journey);
    await firstExec(pexec, 120_000);
    meta.parent_ready_ms = Date.now() - t0;
    stage = "parent setup";
    const s0 = Date.now();
    const setup = await pexec(projectSetupCommand(), 280_000);
    if (setup.code !== 0) throw new Error(`project setup: exit ${setup.code} ${setup.stderr.slice(-400)}`);
    meta.parent_setup_ms = Date.now() - s0;
    const head = facts(setup.stdout).head;
    meta.head = head;
    const started = await pexec(launchCredentialStartProgram(SESSION, "claude", "ANTHROPIC_API_KEY", canary), 120_000);
    const sessionUp = started.stdout.includes("@@session ");
    meta.session_started = sessionUp ? true : scrub(started.stdout.slice(-300), [...secrets, canary]);
    meta.parent_canary = facts((await pexec(canaryCountCommand(canary), 30_000)).stdout).canary;
    const session = sessionUp ? SESSION : null;

    // Mint.
    stage = "mint";
    const m0 = Date.now();
    const minted = await http("POST", `${platform}/v1/runnable-links`, {
      machine: parent, clientKey: `${tag}-mint`, ttlSeconds: 3600, note: "hq#23807 experiment",
      manifest: { repo: PROJECT_REPO, ref: PROJECT_REF, head, sessions: session ? [session] : [], smoke: "mocha test/app.js", service: { port: SERVICE_PORT, path: "/" } },
    }, ph(), 180_000, true);
    if (minted.status === 200 || minted.status === 201) {
      link = minted.body;
      snapshot = link.snapshotId;
      meta.via = "link";
      meta.disclosure = link.disclosure;
    } else {
      meta.via = "snapshot";
      // The code tells a flag that is off (link.not_found before auth) from a refusal of this machine.
      meta.link_api = `HTTP ${minted.status} ${String(minted.body?.code ?? minted.body?.error ?? "").slice(0, 80)}`.trim();
      const snap = await api.op("cloud.snapshot.create", { machine: parent, name: `runnable link ${tag}` }, `${tag}-snap`);
      snapshot = String(snap?.snapshot?.id ?? snap?.snapshot ?? snap?.id);
    }
    // Ready: listed ready (snapshot path) — a link's fork waits for it itself, but the mint is timed to ready either way.
    for (;;) {
      const list = await api.read("cloud.snapshot.list", {}).catch(() => null);
      const rows: any[] = Array.isArray(list) ? list : list?.snapshots ?? list?.items ?? [];
      const row = rows.find((r) => r?.id === snapshot);
      if (!row || row?.status === "ready" || row?.state === "ready") break;
      if (row?.status === "failed") throw new Error("snapshot failed");
      if (Date.now() - m0 > 360_000) throw new Error("snapshot not ready in 6 minutes");
      await sleep(500);
    }
    meta.mint_ms = Date.now() - m0;
    say({ phase: "minted", via: meta.via, mint_ms: meta.mint_ms, link: link?.id ?? null });

    // Opens.
    for (let run = 1; run <= runs; run++) {
      const r: OpenRow = { run, via: link ? "link" : "snapshot", copy: null, resolve_ms: null, fork_call_ms: null, running_ms: null, first_exec_ms: null, scrub_ms: null, usable_ms: null, click_to_usable_ms: null, canary_before_scrub: null, canary_after_scrub: null, facts: null, error: null };
      const c0 = Date.now();
      try {
        await renew();
        if (link) {
          const g = await http("GET", `${platform}/v1/runnable-links/${link.id}`, undefined, ph(), 15_000);
          if (g.status !== 200) throw new Error(`resolve: HTTP ${g.status}`);
        }
        r.resolve_ms = Date.now() - c0;
        let quotaWait = 0;
        let f0 = Date.now();
        if (link) {
          const [f, waited] = await withRoom(async () => {
            const f = await http("POST", `${platform}/v1/runnable-links/${link.id}/fork`, { clientKey: `${tag}-open-${run}` }, ph(), 180_000, true);
            if (f.status !== 200 && f.status !== 201) throw new Error(`fork: HTTP ${f.status} ${JSON.stringify(f.body).slice(0, 200)}`);
            return f;
          });
          quotaWait = waited;
          r.copy = String(f.body?.machine?.id);
        } else {
          const [a, waited] = await withRoom(() => api.op("cloud.snapshot.restore", { snapshot, name: `runnable link ${tag} open ${run}` }, `${tag}-open-${run}`));
          quotaWait = waited;
          r.copy = String(a?.machine?.id ?? a?.machine ?? a?.id);
        }
        machines.push(r.copy);
        f0 += quotaWait;
        r.quota_wait_ms = quotaWait;
        r.fork_call_ms = Date.now() - f0;
        await waitMachine(api, r.copy, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
        r.running_ms = Date.now() - f0;
        const exec = directExec(api, r.copy, journey);
        r.first_exec_ms = await firstExec(exec, 180_000);
        r.canary_before_scrub = Number(facts((await exec(canaryCountCommand(canary), 30_000)).stdout).canary);
        const k0 = Date.now();
        await exec(SCRUB_COMMAND, 30_000);
        r.scrub_ms = Date.now() - k0;
        r.canary_after_scrub = Number(facts((await exec(canaryCountCommand(canary), 30_000)).stdout).canary);
        const u0 = Date.now();
        r.facts = await waitUsable(exec, session, head, 120_000);
        r.usable_ms = Date.now() - u0;
        r.click_to_usable_ms = Date.now() - c0 - (r.quota_wait_ms ?? 0);
      } catch (e) {
        r.error = scrub(String((e as Error).message), [...secrets, canary]).slice(0, 400);
      } finally {
        if (r.copy && !keep) await api.deleteMachine(r.copy, `${tag}-del-open-${run}`).then(() => cleanup.push(`copy ${run} deleted`), () => cleanup.push(`copy ${run} NOT deleted (${r.copy})`));
      }
      opens.push(r);
      say({ phase: "open", run, click_to_usable_ms: r.click_to_usable_ms, canary_after_scrub: r.canary_after_scrub, error: r.error });
    }

    // Negative checks (link API only).
    if (link) {
      await renew();
      const short = await http("POST", `${platform}/v1/runnable-links`, { machine: parent, clientKey: `${tag}-mint-expiring`, ttlSeconds: 5 }, ph(), 180_000, true);
      if (short.status === 200 || short.status === 201) {
        await sleep(7_000);
        const e = await http("POST", `${platform}/v1/runnable-links/${short.body.id}/fork`, { clientKey: `${tag}-expired` }, ph(), 60_000, true);
        negative.expired = { status: e.status, code: e.body?.code ?? e.body?._tag ?? null, refused: e.status === 410 };
        await http("DELETE", `${platform}/v1/runnable-links/${short.body.id}`, undefined, ph(), 60_000, true);
      } else negative.expired = { mint_status: short.status };
      const d = await http("DELETE", `${platform}/v1/runnable-links/${link.id}`, undefined, ph(), 60_000, true);
      const v = await http("POST", `${platform}/v1/runnable-links/${link.id}/fork`, { clientKey: `${tag}-revoked` }, ph(), 60_000, true);
      negative.revoked = { delete_status: d.status, status: v.status, code: v.body?.code ?? v.body?._tag ?? null, refused: v.status === 410 };
      const noAuth = await http("GET", `${platform}/v1/runnable-links/${link.id}`, undefined, {}, 15_000);
      negative.unauthenticated = { status: noAuth.status, refused: noAuth.status === 401 || noAuth.status === 404 };
      snapshot = null; // the revoke deleted it
    }

    // Baseline: a fresh machine, clone, install, start, smoke.
    for (let run = 1; run <= baselineRuns; run++) {
      const b: BaselineRow = { run, machine: null, create_ms: null, setup_ms: null, usable_ms: null, total_ms: null, facts: null, error: null };
      let b0 = Date.now();
      try {
        await renew();
        const [c, waited] = await withRoom(() => api.op("cloud.machine.create", { name: `runnable link ${tag} baseline ${run}`, size: CHAT_START_SIZE }, `${tag}-base-${run}`));
        b.quota_wait_ms = waited;
        b0 += waited;
        b.machine = String(c?.machine?.id ?? c?.machine ?? c?.id);
        machines.push(b.machine);
        await waitMachine(api, b.machine, (m) => m?.status === "running" && Boolean(m?.host), 300_000);
        const exec = directExec(api, b.machine, journey);
        await firstExec(exec, 120_000);
        b.create_ms = Date.now() - b0;
        const s1 = Date.now();
        const st = await exec(projectSetupCommand(), 280_000);
        if (st.code !== 0) throw new Error(`setup: exit ${st.code} ${st.stderr.slice(-300)}`);
        b.setup_ms = Date.now() - s1;
        const u1 = Date.now();
        b.facts = await waitUsable(exec, null, head, 120_000);
        b.usable_ms = Date.now() - u1;
        b.total_ms = Date.now() - b0;
      } catch (e) {
        b.error = scrub(String((e as Error).message), secrets).slice(0, 400);
      } finally {
        if (b.machine && !keep) await api.deleteMachine(b.machine, `${tag}-del-base-${run}`).then(() => cleanup.push(`baseline ${run} deleted`), () => cleanup.push(`baseline ${run} NOT deleted (${b.machine})`));
      }
      baseline.push(b);
      say({ phase: "baseline", run, total_ms: b.total_ms, error: b.error });
    }
  } catch (e) {
    meta.error = scrub(`${stage}: ${String((e as Error).message)}`, [...secrets, canary]).slice(0, 600);
  } finally {
    if (snapshot && !keep) await api.op("cloud.snapshot.delete", { snapshot }, `${tag}-snap-del`).then(() => cleanup.push("snapshot deleted"), () => cleanup.push(`snapshot NOT deleted (${snapshot})`));
    if (parent && !keep) await api.deleteMachine(parent, `${tag}-del-parent`).then(() => cleanup.push("parent deleted"), () => cleanup.push(`parent NOT deleted (${parent})`));
    if (!keep) {
      const done = new Set(parent ? [parent] : []);
      const rows = await listAllMachines((q) => api.read("cloud.machine.list", q)).catch(() => null);
      if (!rows) cleanup.push("stray sweep: list failed");
      for (const id of rows ? strays(rows, tag, Date.now(), done) : []) {
        await api.deleteMachine(id, `${tag}-del-stray-${id}`).then(() => cleanup.push(`stray ${id} deleted`), () => cleanup.push(`stray ${id} NOT deleted`));
      }
    }
  }
  const out = { ...verdict(opens, baseline, meta), negative, cleanup, kept: keep ? machines : [] };
  const text = scrub(JSON.stringify(out), [...secrets, canary]);
  const file = arg("--out");
  if (file) writeFileSync(file, text);
  console.log(text);
  return out.pass ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
