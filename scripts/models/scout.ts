#!/usr/bin/env bun
// The model scout: keeps the live model catalog current and finds new models we should serve.
// User 2026-11-19 (chat 40603): "we need a live models backend that we control and an automation
// that will keep adding new models". It runs as the cmux automation `models-scout` (every 6 h, on a
// team Cloud machine; scripts/models/run-scout.sh) and by hand: `bun scripts/models/scout.ts [--dry-run]`.
//
// One run:
//  1. Reads models.dev (Anthropic, OpenAI, Google, opencode and ~300 more providers) and projects it
//     through web/services/model-catalog/overrides.ts into the catalog every client reads. New models a
//     harness's overrides already admit are added here, with no human step.
//  2. Publishes it to cloud-api (PUT /internal/v1/models/catalog) on staging, then production, only
//     when its content changed. Kills (the per-model kill switch) stay in force across publishes.
//  3. Smoke-tests every model the cmux Pro router serves on production with a real tool-call turn.
//  4. Lists Google's models on our Vertex AI. A chat model that is new since the last run gets a
//     tool-call smoke turn on Vertex (the first run: those released in the last 14 days): a pass opens a draft PR adding it to the router (a human decides
//     the price and production allowlist); a fail is a model "the provider added and we fail to serve":
//     a cmux notification, and the run fails.
//  5. Reports the run to cloud-api (POST /internal/v1/models/runs), so GET /v1/models/catalog/health
//     says when it last ran and what it found; exits 3 when anything failed (the runner then shows it).
//
// Secrets: environment variables first (a Cloud automation gets its per-automation secrets that way:
// `cmux automation secret set models-scout NAME --target cloud`), then ~/.secrets (mode 600) on a Mac:
//   MODELS_CATALOG_TOKEN_STAGING, MODELS_CATALOG_TOKEN_PRODUCTION  catalog publish and run reports
//   CMUX_E2E_EMAIL, CMUX_E2E_PASSWORD                             the production e2e account (router smoke)
//   VERTEX_RELAY_KEY                                              the console's keyless Vertex relay (smoke)
//   GH_TOKEN                                                      push a branch, open a draft PR
// Vertex: smoke turns go through the console's relay (Workload Identity, no Google key anywhere). The
// model list is Vertex's own when a gcloud login exists (a Mac), else models.dev's google-vertex list.
// State: $MODELS_SCOUT_STATE or ~/.local/state/cmux/models-scout/state.json.

import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { projectCatalog } from "../../web/services/model-catalog/project";
import { validateCatalog } from "../../web/services/model-catalog/schema";
import type { ModelCatalog } from "../../web/services/model-catalog/types";
import { fetchFeed } from "../../web/services/model-catalog/upstream";
import {
  addToStagingAllowlist,
  catalogContent,
  diffCatalogs,
  EMPTY_STATE,
  feedPrice,
  insertRouterEntry,
  isChatCandidate,
  judgeSmoke,
  killedHarnesses,
  newVertexModels,
  routerEntry,
  smokeBody,
  withoutServerAdditions,
  type ScoutState,
  type SmokeResult,
} from "./scout-lib";

type Env = "staging" | "production";
const ORIGIN: Record<Env, string> = { staging: "https://cloud-api-staging.cmux.dev", production: "https://cloud-api.cmux.dev" };
const E2E: Record<Env, { stack: string; account: string }> = {
  staging: { stack: "cmuxterm-dev.env", account: "cmux-next-e2e-cloudchief-staging.env" },
  production: { stack: "cmuxterm.env", account: "cmux-next-e2e-cloudchief-prod.env" },
};
const VERTEX_PROJECT = "cmux-489202";
/** The production console's Vertex relay (backend/apps/dashboard/src/lib/vertex-relay.ts): the router's own path to Vertex. */
const VERTEX_RELAY = "https://console.cmux.dev/api/vertex/chat/completions";
/** Production Stack Auth project and publishable client key: public values (the web app ships them). */
const STACK_PRODUCTION = { project: "9790718f-14cd-4f7e-824d-eaf527a82b82" };
const REPO = "manaflow-ai/cmux";
const BASE_BRANCH = "feat-cmux-next";

const args = new Set(process.argv.slice(2));
const dryRun = args.has("--dry-run");
const noPr = dryRun || args.has("--no-pr");
const statePath = process.env.MODELS_SCOUT_STATE ?? join(homedir(), ".local/state/cmux/models-scout/state.json");
const repoRoot = join(dirname(new URL(import.meta.url).pathname), "../..");
const runId = `scout-${new Date().toISOString().replace(/[:.]/g, "-")}`;

const log = (msg: string, extra?: Record<string, unknown>) => console.log(JSON.stringify({ at: new Date().toISOString(), msg, ...extra }));

function secretsFile(name: string): Record<string, string> {
  const out: Record<string, string> = {};
  let text = "";
  try {
    text = readFileSync(join(homedir(), ".secrets", name), "utf8");
  } catch {
    return out;
  }
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#") || !t.includes("=")) continue;
    const [k, ...v] = t.replace(/^export /, "").split("=");
    out[k!] = v.join("=").replace(/^"|"$/g, "");
  }
  return out;
}

/** An environment variable, else `key` of a ~/.secrets file; "" when neither has it. */
const secret = (name: string, file: string, key: string = name): string => process.env[name]?.trim() || secretsFile(file)[key] || "";

const adminToken = (env: Env) => secret(`MODELS_CATALOG_TOKEN_${env.toUpperCase()}`, `cmux-next-api-${env}.env`, "MODELS_CATALOG_TOKEN");

async function e2eToken(env: Env): Promise<string> {
  const stack = secretsFile(E2E[env].stack);
  const email = secret("CMUX_E2E_EMAIL", E2E[env].account, "CMUX_UITEST_STACK_EMAIL");
  const password = secret("CMUX_E2E_PASSWORD", E2E[env].account, "CMUX_UITEST_STACK_PASSWORD");
  const project = stack.NEXT_PUBLIC_STACK_PROJECT_ID || (env === "production" ? STACK_PRODUCTION.project : "");
  const clientKey = process.env.CMUX_STACK_PUBLISHABLE_KEY?.trim() || stack.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY || "";
  if (!email || !password || !project || !clientKey) throw new Error(`no e2e sign-in for ${env} (set CMUX_E2E_EMAIL, CMUX_E2E_PASSWORD, CMUX_STACK_PUBLISHABLE_KEY)`);
  const res = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-stack-project-id": project,
      "x-stack-publishable-client-key": clientKey,
      "x-stack-access-type": "client",
    },
    body: JSON.stringify({ email, password }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`e2e sign-in on ${env} answered ${res.status}`);
  return ((await res.json()) as { access_token: string }).access_token;
}

/** This machine's gcloud login, or null where there is none (a Cloud machine). */
const gcloudToken = (): string | null => {
  const out = spawnSync("gcloud", ["auth", "print-access-token"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 30_000 });
  return out.status === 0 && out.stdout.trim() ? out.stdout.trim() : null;
};

/** Google's models on Vertex: Vertex's own list with a gcloud login, else models.dev's google-vertex provider. */
async function vertexModelIds(feed: Record<string, any>): Promise<{ ids: Array<string>; source: "vertex" | "models.dev" }> {
  const token = gcloudToken();
  if (token) return { ids: await listVertexGoogleModels(token), source: "vertex" };
  return { ids: Object.keys(feed["google-vertex"]?.models ?? {}).filter((id) => id.startsWith("gemini-")), source: "models.dev" };
}

async function listVertexGoogleModels(token: string): Promise<Array<string>> {
  const ids: Array<string> = [];
  let page = "";
  for (let i = 0; i < 20; i++) {
    const url = `https://aiplatform.googleapis.com/v1beta1/publishers/google/models?pageSize=200${page ? `&pageToken=${encodeURIComponent(page)}` : ""}`;
    const res = await fetch(url, { headers: { authorization: `Bearer ${token}`, "x-goog-user-project": VERTEX_PROJECT }, signal: AbortSignal.timeout(30_000) });
    if (!res.ok) throw new Error(`Vertex model list answered ${res.status}`);
    const body = (await res.json()) as { publisherModels?: Array<{ name: string }>; nextPageToken?: string };
    for (const m of body.publisherModels ?? []) ids.push(m.name.split("/").pop()!);
    if (!body.nextPageToken) break;
    page = body.nextPageToken;
  }
  return ids;
}

/** One smoke turn, tried again once after 20 s when it fails: a single busy moment at the provider is not an outage. */
async function smoke(url: string, token: string, model: string, extra: Record<string, unknown> = {}, wantTool = true): Promise<SmokeResult & { firstError?: string }> {
  const first = await smokeOnce(url, token, model, extra, wantTool);
  if (first.ok) return first;
  await new Promise((resolve) => setTimeout(resolve, 20_000));
  const second = await smokeOnce(url, token, model, extra, wantTool);
  return { ...second, firstError: first.error };
}

async function smokeOnce(url: string, token: string, model: string, extra: Record<string, unknown> = {}, wantTool = true): Promise<SmokeResult> {
  const started = Date.now();
  try {
    const res = await fetch(url, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ ...smokeBody(model), ...extra }), signal: AbortSignal.timeout(120_000) });
    const text = await res.text();
    let body: unknown = null;
    try {
      body = JSON.parse(text);
    } catch {
      body = { error: text.slice(0, 200) };
    }
    return judgeSmoke(model, res.status, body, Date.now() - started, wantTool);
  } catch (error) {
    return { model, ok: false, toolCall: false, status: 0, ms: Date.now() - started, error: String(error).slice(0, 200) };
  }
}

async function served(env: Env): Promise<ModelCatalog | null> {
  const res = await fetch(`${ORIGIN[env]}/v1/models/catalog`, { headers: { "cache-control": "no-cache" }, signal: AbortSignal.timeout(20_000) });
  if (res.status === 503) return null;
  if (!res.ok) throw new Error(`GET catalog on ${env} answered ${res.status}`);
  return (await res.json()) as ModelCatalog;
}

async function internal(env: Env, method: string, path: string, body: unknown, note?: string): Promise<any> {
  const res = await fetch(`${ORIGIN[env]}${path}`, {
    method,
    headers: { authorization: `Bearer ${adminToken(env)}`, "content-type": "application/json", ...(note ? { "x-cmux-note": note.slice(0, 400) } : {}) },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} on ${env} answered ${res.status}: ${text.slice(0, 200)}`);
  return JSON.parse(text);
}

function readState(): ScoutState | null {
  try {
    return { ...EMPTY_STATE, ...(JSON.parse(readFileSync(statePath, "utf8")) as ScoutState) };
  } catch {
    return null;
  }
}

function writeState(state: ScoutState) {
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n");
}

function notify(title: string, body: string) {
  if (dryRun || process.env.CMUX_AUTOMATION_NOTIFY === "off") return log("notify (skipped)", { title, body });
  spawnSync("cmux", ["notification", "create", "--title", title, "--body", body.slice(0, 500), "--level", "warning"], { stdio: "ignore", timeout: 15_000 });
}

/** Opens a draft PR that adds `id` to the router (catalog entry + staging allowlist); returns its URL. */
function openRouterPr(id: string, price: NonNullable<ReturnType<typeof feedPrice>>, result: SmokeResult): string | null {
  const branch = `models-scout/google-${id}`;
  // GH_TOKEN (a Cloud automation secret): gh reads it itself; git gets it from a helper that reads the
  // environment, so the token never appears in a command line.
  const ghToken = process.env.GH_TOKEN?.trim();
  const auth = ghToken ? ["-c", "credential.helper=", "-c", 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'] : [];
  const existing = spawnSync("gh", ["pr", "list", "--repo", REPO, "--head", branch, "--state", "all", "--json", "url", "--jq", ".[0].url"], { encoding: "utf8" }).stdout.trim();
  if (existing) return existing;
  const dir = mkdtempSync(join(tmpdir(), "models-scout-"));
  const git = (...a: Array<string>) => execFileSync("git", a, { cwd: dir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  try {
    execFileSync("git", ["-C", repoRoot, "fetch", "-q", "origin", BASE_BRANCH], { stdio: "ignore" });
    execFileSync("git", ["-C", repoRoot, "worktree", "add", "-q", "-b", branch, dir, `origin/${BASE_BRANCH}`], { stdio: "ignore" });
    const catalogPath = join(dir, "backend/apps/api/src/inference/catalog.ts");
    const wranglerPath = join(dir, "backend/apps/api/wrangler.jsonc");
    const today = new Date().toISOString().slice(0, 10);
    const catalog = insertRouterEntry(readFileSync(catalogPath, "utf8"), id, routerEntry(id, price, today));
    const wrangler = addToStagingAllowlist(readFileSync(wranglerPath, "utf8"), `google/${id}`);
    if (!catalog || !wrangler) throw new Error("the router files lack the scout marker or already have the model");
    writeFileSync(catalogPath, catalog);
    writeFileSync(wranglerPath, wrangler);
    git("add", catalogPath, wranglerPath);
    git("-c", "user.name=cmux models-scout", "-c", "user.email=models-scout@users.noreply.github.com", "commit", "-q", "-m", `Model router: add ${price.name} from our Vertex AI (proposed by the model scout)`);
    git(...auth, "push", "-q", `https://github.com/${REPO}.git`, `HEAD:${branch}`);
    const body = [
      `The model scout found **${price.name}** (\`${id}\`) new on Google's Vertex AI and it passed a tool-call smoke turn on our project (${result.ms} ms).`,
      "",
      "This PR adds it to the cmux Pro router on **staging only**. A human decides:",
      `- the price: models.dev lists $${price.input} input / $${price.output} output per 1M tokens${price.cacheRead !== undefined ? ` (cache read $${price.cacheRead})` : ""}; the card in this PR charges that list price;`,
      "- whether it goes to production: add it to the production allowlist in wrangler.jsonc and to scripts/cmux-next/release/production-approvals.json.",
      "",
      `Run: \`${runId}\` (scripts/models/scout.ts).`,
    ].join("\n");
    const pr = spawnSync("gh", ["pr", "create", "--repo", REPO, "--base", BASE_BRANCH, "--head", branch, "--draft", "--title", `Model router: add ${price.name} from our Vertex AI`, "--body", body], { encoding: "utf8" });
    if (pr.status !== 0) throw new Error(`gh pr create failed: ${pr.stderr.slice(0, 300)}`);
    return pr.stdout.trim().split("\n").pop() ?? null;
  } finally {
    spawnSync("git", ["-C", repoRoot, "worktree", "remove", "--force", dir], { stdio: "ignore" });
    rmSync(dir, { recursive: true, force: true });
  }
}

async function main(): Promise<number> {
  const failures: Array<string> = [];
  const summary: Record<string, unknown> = { runId, dryRun };

  // 1. The catalog from models.dev and the overrides.
  const feed = (await fetchFeed()) as Record<string, any>;
  const doc = validateCatalog(projectCatalog(feed, new Date()));
  summary.harnessModels = Object.fromEntries(doc.harnesses.filter((h) => h.models.length > 0).map((h) => [h.id, h.models.length]));

  // 2. Publish where the content changed (staging first: a refused body stops before production).
  const published: Record<string, unknown> = {};
  let diff = { added: [] as Array<string>, removed: [] as Array<string> };
  for (const env of ["staging", "production"] as const) {
    try {
      const current = await served(env);
      const d = diffCatalogs(current, doc);
      if (env === "production") diff = d;
      const killed = killedHarnesses(current);
      if (current && catalogContent(withoutServerAdditions(current, doc), killed) === catalogContent(doc, killed)) {
        published[env] = { changed: false, version: current.version ?? null };
        continue;
      }
      const note = `${runId}: ${d.added.length} added, ${d.removed.length} removed${d.added.length ? ` (${d.added.slice(0, 8).join(", ")})` : ""}`;
      if (dryRun) {
        published[env] = { changed: true, dryRun: true, ...d };
        continue;
      }
      const r = await internal(env, "PUT", "/internal/v1/models/catalog", doc, note);
      published[env] = { changed: true, version: r.version, ...d };
    } catch (error) {
      failures.push(`publish ${env}: ${String(error).slice(0, 200)}`);
      if (env === "staging") break;
    }
  }
  summary.published = published;
  summary.added = diff.added;
  summary.removed = diff.removed;

  // 3. The router's models answer a real tool-call turn on production.
  const routerIds: Array<string> = [];
  try {
    const models = ((await (await fetch(`${ORIGIN.production}/v1/inference/models`, { signal: AbortSignal.timeout(20_000) })).json()) as { data: Array<{ id: string; tools: boolean }> }).data;
    for (const m of models) routerIds.push(m.id);
    const token = await e2eToken("production");
    const results: Array<SmokeResult> = [];
    for (const m of models) results.push(await smoke(`${ORIGIN.production}/v1/inference/chat/completions`, token, m.id, {}, m.tools));
    summary.routerSmoke = results;
    for (const r of results) if (!r.ok) failures.push(`router ${r.model}: ${r.error}`);
  } catch (error) {
    failures.push(`router smoke: ${String(error).slice(0, 200)}`);
  }

  // 4. New Google models on our Vertex AI.
  const state = readState();
  const unserved: Array<string> = [];
  const proposals: Array<{ id: string; pr: string | null }> = [];
  try {
    const relayKey = secret("VERTEX_RELAY_KEY", "cmux-inference-relay.env", "INFERENCE_VERCEL_RELAY_KEY_PRODUCTION");
    if (!relayKey) throw new Error("no VERTEX_RELAY_KEY for the console's Vertex relay");
    const { ids: vertexIds, source } = await vertexModelIds(feed);
    // Models the router catalog already has (staging-only ones too) are not new, even on a first run.
    const inCatalog = [...readFileSync(join(repoRoot, "backend/apps/api/src/inference/catalog.ts"), "utf8").matchAll(/id: "(google\/[^"]+)"/g)].map((m) => m[1]!);
    const fresh = newVertexModels(vertexIds, [...routerIds, ...inCatalog], state, (id) => feedPrice(feed, id)?.releaseDate);
    summary.vertex = { source, models: vertexIds.length, chatCandidates: vertexIds.filter(isChatCandidate).length, new: fresh, firstRun: state === null };
    const proposed = new Set(state?.proposed ?? []);
    for (const id of fresh) {
      const price = feedPrice(feed, id);
      const result = await smoke(VERTEX_RELAY, relayKey, `google/${id}`, { labels: { cmux_service: "models-scout", cmux_env: "production" } });
      if (!result.ok) {
        unserved.push(`${id} (${result.error})`);
        continue;
      }
      if (!price) {
        proposals.push({ id, pr: null });
        failures.push(`vertex ${id}: serves, but models.dev has no price yet; a human sets it`);
        continue;
      }
      if (proposed.has(id) || noPr) {
        proposals.push({ id, pr: null });
        continue;
      }
      try {
        proposals.push({ id, pr: openRouterPr(id, price, result) });
        proposed.add(id);
      } catch (error) {
        failures.push(`PR for ${id}: ${String(error).slice(0, 200)}`);
      }
    }
    if (!dryRun) writeState({ seenVertex: [...new Set([...(state?.seenVertex ?? []), ...vertexIds.filter((id) => !unserved.some((u) => u.startsWith(`${id} `)))])].sort(), proposed: [...proposed].sort() });
  } catch (error) {
    failures.push(`vertex: ${String(error).slice(0, 200)}`);
  }
  summary.proposals = proposals;
  summary.unserved = unserved;
  if (unserved.length > 0) {
    failures.push(...unserved.map((u) => `unserved ${u}`));
    notify("New model not served", `Google added ${unserved.length} model(s) on Vertex that failed our smoke turn: ${unserved.join("; ")}`);
  }

  // 5. Report.
  summary.failed = failures;
  const ok = failures.length === 0;
  if (!dryRun) {
    for (const env of ["staging", "production"] as const) {
      try {
        await internal(env, "POST", "/internal/v1/models/runs", { id: runId, ok, summary });
      } catch (error) {
        log("run report failed", { env, error: String(error).slice(0, 200) });
      }
    }
  }
  log(ok ? "scout run ok" : "scout run failed", summary);
  return ok ? 0 : 3;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    // `stack ?? error` logged "" for an error with an empty stack (a local run, 2026-11-20 10:03): name every part.
    const e = error as { name?: unknown; message?: unknown; stack?: unknown; cause?: unknown } | undefined;
    const text = [e?.name, e?.message, e?.cause && `cause: ${String((e.cause as { message?: unknown }).message ?? e.cause)}`, e?.stack].filter((x) => typeof x === "string" && x.length > 0);
    log("scout crashed", { error: (text.length ? [...new Set(text)].join(" | ") : String(error) || typeof error).slice(0, 1000) });
    process.exit(1);
  },
);
