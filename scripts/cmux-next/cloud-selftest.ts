#!/usr/bin/env bun
/**
 * The Cloud self-test: one command that drives and checks Cloud multiplayer end to end, with no GUI, as several
 * people at once (plans/cmux-next/cloud-selftest-DESIGN.md).
 *
 *   bun scripts/cmux-next/cloud-selftest.ts list [--json]
 *   bun scripts/cmux-next/cloud-selftest.ts run --backend dev --fixtures stack --credentials ~/.secrets/cmuxterm-dev.env \
 *       --cmux "$(command -v cmux)" [--scenario team.list,team.role_matrix | --tag fast | all] [--out DIR] [--json]
 *   CMUX_TAG=<tag> bun scripts/cmux-next/cloud-selftest.ts run --cmux <tag's bin/cmux> --tag app [--app-session KEY]
 *       [--app-tab TAB] [--link-host ID] ...
 *   bun scripts/cmux-next/cloud-selftest.ts run --backend preview-36050 --fixtures worker   # DEV_FIXTURES_TOKEN
 *   bun scripts/cmux-next/cloud-selftest.ts run --backend local --fixtures worker           # wrangler dev, ENVIRONMENT=local
 *
 * Actors (owner, admin, member, member2, leaver, guest, outsider) are separate signed-in identities, each with its own
 * HOME, XDG folders and control-socket path; none sees the caller's cmux. Each step is (actor, action, args, expect);
 * an action is a `cmux` verb with --json where this cmux has it, else the backend route that verb calls (recorded as
 * such), else PENDING on the lane that adds it. The model is the shared stub (tests/fixtures/model-stub) on the
 * machine's loopback or, for gateway scenarios, on this computer behind `cmux inference gateway`, with injected
 * rate limits, auth errors, overloads and delays.
 *
 * Fixtures (--fixtures): `worker` the Worker's dev-only POST /v1/dev/fixtures (DEV_FIXTURES_TOKEN), `stack` the
 * sign-in service's server API for the dev project (STACK_SECRET_SERVER_KEY), `accounts` pre-made accounts
 * (CMUX_SELFTEST_ACCOUNTS: a JSON file {actor: {email, password}}, read-only). Secrets come from the environment or a
 * KEY=value --credentials file and are never printed.
 *
 * App verbs (team sessions, follow, reassign, copy link, groups, transfer to this Mac) answer through a tagged app's
 * socket as the person signed in to it: CMUX_TAG=<tag> (or --app-socket PATH) with --cmux that app's bin/cmux. Their
 * scenarios SKIP with the reason when no app answers `cmux app ping`. --app-session KEY names a team session the run may
 * follow, archive and reassign (each change undone); --app-tab TAB a Cloud chat tab to transfer to this Mac;
 * --link-host ID a Cloud machine this computer's link reaches (`cmux link chat`, as the app's person).
 *
 * --no-machines skips every scenario that makes a Cloud machine. --driver cli|api forces one transport (auto: the CLI
 * verb when present). --out DIR writes journey.json (every step, its transport, code and latency) and summary.md.
 * Exit 0 when no scenario failed (PENDING and SKIP do not fail; --fail-on-pending makes PENDING fail).
 * Production is refused.
 */
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { readEnvFile, resolveBackend, scrub } from "./cloud-journey";
import { ACTIONS, type Driver, type RunCtx } from "./cloud-selftest/actions";
import { findApp, verbExists } from "./cloud-selftest/actors";
import { writeReport, type Report, type Scenario } from "./cloud-selftest/engine";
import { startLocalStub } from "./cloud-selftest/faults";
import { accountFixtures, stackFixtures, workerFixtures, type Fixtures } from "./cloud-selftest/fixtures";
import { lintScenarios, pendingLanes, runScenario, type Abilities } from "./cloud-selftest/runner";
import { SCENARIOS } from "./cloud-selftest/scenarios";

function arg(argv: string[], flag: string): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

/** The scenarios a --scenario / --tag selection names (all when neither); an unknown name throws. */
export function select(all: Scenario[], names?: string, tag?: string): Scenario[] {
  if (names && names !== "all") {
    const want = names.split(",").filter(Boolean);
    const unknown = want.filter((n) => !all.some((s) => s.name === n));
    if (unknown.length) throw new Error(`no scenario ${unknown.join(", ")} (run \`list\`)`);
    return all.filter((s) => want.includes(s.name));
  }
  return tag ? all.filter((s) => s.tags.includes(tag)) : all;
}

/** The local gateway's stub answers with the prompt's marker, so a reply names the turn it belongs to. */
export const GATEWAY_STUB_SCRIPT = { version: 1, steps: [{ text: "Stub reply {{nonce}}: {{prompt~(\\[st-[^\\]]+\\])}}" }] };

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const verb = argv[0];
  if (!verb || verb === "--help" || verb === "-h" || verb === "help") {
    console.log(readFileSync(new URL(import.meta.url), "utf8").split("*/")[0]);
    return verb ? 0 : 2;
  }
  const problems = lintScenarios(SCENARIOS);
  if (problems.length) {
    for (const p of problems) console.error(`catalogue: ${p}`);
    return 2;
  }
  if (verb === "list") {
    const rows = SCENARIOS.map((s) => ({ name: s.name, summary: s.summary, tags: s.tags, needs: s.needs ?? [], waits_on: pendingLanes(s), covers: s.covers, actors: s.actors.map((a) => a.name) }));
    if (argv.includes("--json")) console.log(JSON.stringify({ scenarios: rows, actions: Object.fromEntries(Object.entries(ACTIONS).map(([k, d]) => [k, { lane: d.lane, summary: d.summary, verb: d.verb ? `cmux ${d.verb.join(" ")}` : null, route_today: !!d.api, harness: !!d.harness }])) }, null, 2));
    else for (const r of rows) console.log(`${r.name.padEnd(34)} ${(r.waits_on.join(",") || "base").padEnd(6)} ${r.summary}`);
    return 0;
  }
  if (verb !== "run") {
    console.error(`unknown verb ${verb}: list or run`);
    return 2;
  }
  const backend = resolveBackend(arg(argv, "--backend") ?? (arg(argv, "--api") ? "custom" : "dev"), arg(argv, "--api"), arg(argv, "--stack"), Number(arg(argv, "--local-port") ?? 8787));
  if (backend.name === "prod" || /cloud-api\.cmux\.dev|\/\/cmux-api\.debussy/.test(backend.api)) {
    console.error("refused: the self-test makes accounts and teams; never run it against production");
    return 2;
  }
  const credFile = arg(argv, "--credentials");
  const creds: Record<string, string | undefined> = { ...(credFile ? readEnvFile(readFileSync(credFile, "utf8")) : {}), ...process.env };
  const run = `${Date.now().toString(36)}${randomBytes(2).toString("hex")}`;
  const secrets: string[] = [];
  const dir = mkdtempSync(path.join(tmpdir(), `cmux-selftest-${run}-`));
  const outDir = arg(argv, "--out") ? path.resolve(arg(argv, "--out")!) : null;
  if (outDir) mkdirSync(outDir, { recursive: true });
  const kind = arg(argv, "--fixtures") ?? "worker";
  let fixtures: Fixtures;
  try {
    fixtures =
      kind === "stack"
        ? stackFixtures(run, creds.STACK_SECRET_SERVER_KEY ?? "", secrets)
        : kind === "accounts"
          ? accountFixtures(JSON.parse(readFileSync(creds.CMUX_SELFTEST_ACCOUNTS ?? "", "utf8")), secrets)
          : workerFixtures(run, backend.api, creds.DEV_FIXTURES_TOKEN ?? "", secrets);
  } catch (e) {
    console.error(String((e as Error).message));
    return 2;
  }
  const cmux = arg(argv, "--cmux") ?? null;
  const driver = (arg(argv, "--driver") ?? "auto") as Driver;
  // The tagged app: its socket answers `cmux app ping` (the CLI's own route to the app), else the reason.
  const app = !cmux
    ? "no --cmux (a tagged app's bin/cmux)"
    : findApp(arg(argv, "--app-tag") ?? process.env.CMUX_TAG, arg(argv, "--app-socket"), process.env.HOME ?? homedir(), (t) =>
        spawnSync(cmux, ["--json", "app", "ping"], { env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? homedir(), ...t.env }, encoding: "utf8", timeout: 15_000 }).status === 0,
      );
  const ctx: RunCtx = { cmux, driver, api: backend.api, run, dir, actors: new Map(), vars: { run }, fixtures, users: new Map(), team: null, stub: null, gateways: new Map(), secrets, machines: new Set(), app: typeof app === "string" ? null : app };
  const given = (flag: string, name: string) => {
    const v = arg(argv, flag);
    if (v) ctx.vars[name] = v;
    return v;
  };
  const appSession = given("--app-session", "app_session");
  const appTab = given("--app-tab", "app_tab");
  const linkHost = given("--link-host", "link_host");
  ctx.vars.transfer_dir = path.join(dir, `transfer-${run}`);
  const keyfile = path.join(dir, "team-key");
  writeFileSync(keyfile, `sk-ant-api03-selftest-${randomBytes(12).toString("hex")}`, { mode: 0o600 });
  secrets.push(readFileSync(keyfile, "utf8"));
  ctx.vars.keyfile = keyfile;
  const python = spawnSync("python3", ["-c", "print(1)"], { encoding: "utf8" }).status === 0;
  const can: Abilities = {
    "fixtures.mutate": fixtures.mutable || `the ${fixtures.kind} provider cannot change teams`,
    machine: argv.includes("--no-machines") ? "--no-machines" : true,
    gateway: !cmux ? "no --cmux" : verbExists(cmux, ["inference", "gateway"]) || "this cmux has no `inference gateway`",
    stub: python || "no python3 for the model stub",
    cmux: !!cmux || "no --cmux",
    app: typeof app === "string" ? app : true,
    "app.session": !!appSession || "no --app-session KEY (a team session this run may follow, archive and reassign back)",
    "app.tab": !!appTab || "no --app-tab TAB (a Cloud chat tab in the tagged app to transfer to this Mac)",
    link: !linkHost ? "no --link-host ID (a Cloud machine this computer's link reaches)" : typeof app === "string" ? `the link is the app's person's: ${app}` : true,
    "link.actors": "each actor needs its own signed-in cmux link (a member's or guest's Mac); this runner provisions headless accounts only",
  };
  let chosen: Scenario[];
  try {
    chosen = select(SCENARIOS, arg(argv, "--scenario"), arg(argv, "--tag"));
  } catch (e) {
    console.error(String((e as Error).message));
    return 2;
  }
  const report: Report = { backend: { name: backend.name, api: backend.api }, started_at: new Date().toISOString(), meta: { run, fixtures: fixtures.kind, driver, cmux: cmux ?? "(none)", app: ctx.app ? ctx.app.tag : String(app) }, scenarios: [] };
  const cleanup = async () => {
    for (const g of ctx.gateways.values()) await g.stop().catch(() => undefined);
    ctx.gateways.clear();
    await ctx.stub?.stop().catch(() => undefined);
    const owner = ctx.actors.get("owner");
    for (const m of [...ctx.machines]) {
      // Only machines this run made, by their exact ids.
      await owner?.op("cloud.machine.delete", { machine: m }, `${run}-final-delete-${m}`).catch(() => undefined);
      ctx.machines.delete(m);
    }
    const c = await fixtures.cleanup().catch((e) => ({ error: String((e as Error).message) }));
    console.log(`cleanup: ${scrub(JSON.stringify(c), secrets)}`);
    rmSync(dir, { recursive: true, force: true });
  };
  const onSignal = () => void cleanup().finally(() => process.exit(130));
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
  try {
    if (chosen.some((s) => (s.needs ?? []).includes("stub")) && can.stub === true) {
      ctx.stub = await startLocalStub(dir, GATEWAY_STUB_SCRIPT, run);
    }
    for (const s of chosen) {
      const rec = await runScenario(s, ctx, can);
      report.scenarios.push(rec);
      for (const st of rec.steps) console.log(scrub(`  ${st.outcome.toUpperCase().padEnd(7)} ${st.label} ${st.ms} ms${st.transport ? ` [${st.transport}]` : ""} :: ${st.detail}`, secrets));
      console.log(scrub(`${rec.outcome.toUpperCase().padEnd(7)} ${rec.name} ${rec.ms} ms${rec.reason ? ` :: ${rec.reason.slice(0, 300)}` : ""}`, secrets));
      if (outDir) writeReport(outDir, report, secrets);
    }
  } finally {
    await cleanup();
  }
  const n = (o: string) => report.scenarios.filter((s) => s.outcome === o).length;
  console.log(`\n${n("fail") ? "FAIL" : "PASS"} Cloud self-test on ${backend.name}: ${n("pass")} pass, ${n("fail")} fail, ${n("pending")} pending, ${n("skip")} skip`);
  if (argv.includes("--json")) console.log(scrub(JSON.stringify(report), secrets));
  return n("fail") || (argv.includes("--fail-on-pending") && n("pending")) ? 1 : 0;
}

if (import.meta.main) process.exit(await main());
