#!/usr/bin/env node
// Cloud VM startup benchmark at the control-plane boundary: what a signed-in
// client pays for create, first attach, warm attach, exec, pause, resume and
// destroy against a deployed backend, with the create route's per-stage
// Server-Timing header captured per trial (issue #12905).
//
// Uses a throwaway Stack user on a paid plan like smoke-vm-api.mjs, so it
// never touches an existing user's machines; every machine it creates is
// destroyed before exit, including on failure.
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { elapsedMs, formatSummary, ownerNetworkSlug, parseServerTiming, summarizeFields, summarizeStages } from "./benchStats.mjs";
import { loadTargetEnv, optionValue, parseWebDirAndTarget, requireEnvKeys } from "./projects.mjs";

const usage = "Usage: bench-vm-startup.mjs [web-dir] <staging|production> [--trials N] [--concurrency K] [--url https://preview.example] [--skip-pause] [--skip-exec] [--edge-check] [--label <text>] [--out <file.json>]";
const { webDir, target, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const trials = positiveInteger(optionValue(rest, "--trials") ?? "3", "--trials");
const concurrency = Math.min(positiveInteger(optionValue(rest, "--concurrency") ?? "1", "--concurrency"), trials);
const targetUrl = optionValue(rest, "--url") ?? project.url;
const skipPause = rest.includes("--skip-pause");
const skipExec = rest.includes("--skip-exec");
// Full-feature readiness: poll the model-plane edge alias from inside the
// guest until the coderouter reflection route answers, so the report can
// separate "terminal usable" from "agents can reach their credentials".
const edgeCheck = rest.includes("--edge-check");
const EDGE_PROBE = "curl -s -o /dev/null -w '%{http_code}' --max-time 4 https://coderouter.cmux.internal/api/vm/reflection";
const EDGE_BUDGET_MS = 90_000;
const label = optionValue(rest, "--label") ?? "";
const outPath = optionValue(rest, "--out");
const REQUEST_TIMEOUT_MS = 120_000;
// The create route keeps provisioning for up to its own maxDuration (600 s);
// aborting the client earlier would strand a machine this run never learns
// the id of. Wait at least that long, and reconcile through the fleet list
// at exit anyway (the throwaway user owns nothing else).
const CREATE_TIMEOUT_MS = 630_000;
const ATTACH_BUDGET_MS = 180_000;

const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const { StackServerApp } = await import(pathToFileURL(requireFromWeb.resolve("@stackframe/js")).href);
// ESM-only package (no require entry): resolved from this script's own tree.
const { Freestyle, FreestyleApiError } = await import("freestyle");

const env = loadTargetEnv(project);
requireEnvKeys(env, ["NEXT_PUBLIC_STACK_PROJECT_ID", "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", "STACK_SECRET_SERVER_KEY"], `${project.projectName} bench`);
// Cleanup is verified against the provider's own inventory (a create can
// allocate a machine the control plane never records), so the deployment's
// provider key is required. A Vercel "sensitive" variable pulls as an empty
// string; the operator's own key (~/.secrets/cmux.env, the same account)
// covers that.
const providerApiKey = env.FREESTYLE_API_KEY?.trim() || process.env.FREESTYLE_API_KEY?.trim();
if (!providerApiKey) {
  console.error("bench-vm-startup: FREESTYLE_API_KEY is required (pulled target env or process env) so cleanup can verify provider inventory");
  process.exit(2);
}
const providerSdk = new Freestyle({ apiKey: providerApiKey });
const app = new StackServerApp({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
  secretServerKey: env.STACK_SECRET_SERVER_KEY,
});

const suffix = `${Date.now()}-${randomBytes(3).toString("hex")}`;
const liveVmIds = new Set();
let user;
let authHeaders;
// Fail closed: an interrupt stops scheduling, the current request finishes,
// and the `finally` below still destroys every machine and the user. Node's
// default signal handling would exit without running it.
let interrupted = false;
const interruptWaiters = new Set();
const interrupt = () => {
  interrupted = true;
  for (const wake of interruptWaiters) wake();
};
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);

/** A bounded wait that returns early on SIGINT/SIGTERM instead of holding teardown for the full delay. */
function sleep(ms) {
  return new Promise((resolve) => {
    const wake = () => {
      clearTimeout(timer);
      interruptWaiters.delete(wake);
      resolve();
    };
    const timer = setTimeout(wake, ms);
    interruptWaiters.add(wake);
  });
}

function requireStatus(stage, response, expected = 200) {
  if (response.status !== expected) {
    throw new Error(`${stage} expected ${expected}, got ${response.status}: ${response.text.slice(0, 300)}`);
  }
}

async function fetchTimed(url, init = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = performance.now();
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    const text = await response.text();
    return { status: response.status, text, headers: response.headers, ms: elapsedMs(startedAt) };
  } finally {
    clearTimeout(timer);
  }
}

function json(text) {
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

const vmUrl = (vmId, tail = "") => `${targetUrl}/api/vm/${encodeURIComponent(vmId)}${tail}`;

/** Attach until the daemon answers; a 502 with `retryable` is the documented not-ready contract. */
async function attachUntilReady(vmId, stage) {
  const startedAt = performance.now();
  const attempts = [];
  for (;;) {
    // The stage deadline bounds the request itself, not only the retry sleep.
    const budgetLeftMs = ATTACH_BUDGET_MS - (performance.now() - startedAt);
    if (budgetLeftMs <= 0 || interrupted) {
      throw new Error(`${stage} attach for ${vmId} did not succeed within ${ATTACH_BUDGET_MS} ms (${attempts.length} attempts)`);
    }
    const response = await fetchTimed(vmUrl(vmId, "/attach-endpoint"), {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ transport: "cmux-remote", clientCapabilities: ["wireguard-hub", "direct-ws-user-agent"] }),
    }, Math.min(REQUEST_TIMEOUT_MS, budgetLeftMs));
    const body = json(response.text);
    attempts.push({ status: response.status, ms: response.ms, error: body.error ?? null });
    if (response.status === 200) {
      // Only an endpoint the documented client path can dial counts as ready:
      // a trusted-carrier listener at a ws:// route. Anything else is a
      // failed attach for this benchmark, not a sample.
      if (body.trustedCarrier !== true || typeof body.route !== "string" || !/^wss?:\/\//.test(body.route)) {
        throw new Error(`${stage} attach for ${vmId} answered 200 without a trusted-carrier route: ${response.text.slice(0, 300)}`);
      }
      return {
        [`${stage}Ms`]: elapsedMs(startedAt),
        [`${stage}Attempts`]: attempts,
        [`${stage}TrustedCarrier`]: body.trustedCarrier === true,
        [`${stage}RouteFamily`]: typeof body.route === "string" ? (body.route.includes("[") ? "ipv6" : "ipv4") : null,
        [`${stage}DaemonCommit`]: body.daemonBuild?.commit ?? null,
      };
    }
    // The API may ask for a long Retry-After; the benchmark's own budget wins,
    // so one retry can never sleep past the deadline (and past teardown).
    const remainingMs = ATTACH_BUDGET_MS - (performance.now() - startedAt);
    if (response.status !== 502 || body.retryable !== true || remainingMs <= 0 || interrupted) {
      throw new Error(`${stage} attach for ${vmId} failed: ${response.status} ${response.text.slice(0, 300)}`);
    }
    await sleep(Math.min(remainingMs, Math.max(1, Number(body.retryAfterSeconds) || 2) * 1000));
  }
}

/** Time from the first probe until the edge alias answers with an HTTP status (any status proves injection). */
async function edgeReady(vmId) {
  const startedAt = performance.now();
  const probes = [];
  for (;;) {
    // The request itself is bounded by what is left of the stage budget.
    const remainingMs = Math.max(1_000, EDGE_BUDGET_MS - (performance.now() - startedAt));
    const exec = await fetchTimed(vmUrl(vmId, "/exec"), {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ command: EDGE_PROBE, timeoutMs: 10_000 }),
    }, remainingMs);
    const code = (json(exec.text).stdout ?? "").trim();
    probes.push({ status: exec.status, ms: exec.ms, code });
    // Only a 200 from the reflection route proves the edge injected the
    // machine's credential; 401/503 mean it is not ready yet, and 000 means
    // the alias is not routed yet.
    if (exec.status === 200 && json(exec.text).exitCode === 0 && code === "200") {
      return { edgeReadyMs: elapsedMs(startedAt), edgeProbes: probes, edgeHttpCode: code };
    }
    if (performance.now() - startedAt >= EDGE_BUDGET_MS || interrupted) {
      throw new Error(`edge alias did not answer within ${EDGE_BUDGET_MS} ms (last exec ${exec.status}, code ${code || "none"})`);
    }
    await sleep(1000);
  }
}

async function runTrial(index) {
  const trial = { index, startedAt: new Date().toISOString() };
  const create = await fetchTimed(`${targetUrl}/api/vm`, {
    method: "POST",
    headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": `bench-${suffix}-${index}` },
    body: "{}",
  }, CREATE_TIMEOUT_MS);
  trial.createMs = create.ms;
  trial.createStatus = create.status;
  trial.createTraceId = create.headers.get("x-cmux-trace-id");
  trial.createStages = parseServerTiming(create.headers.get("server-timing"));
  requireStatus("POST /api/vm", create);
  const created = json(create.text);
  const vmId = created.id;
  if (!vmId) throw new Error("create response missing id");
  liveVmIds.add(vmId);
  trial.vmId = vmId;
  trial.imageVersion = created.imageVersion ?? null;
  trial.size = created.size?.name ?? null;
  Object.assign(trial, await attachUntilReady(vmId, "attach"));
  trial.createToUsableMs = trial.createMs + trial.attachMs;
  Object.assign(trial, await attachUntilReady(vmId, "warmAttach"));
  if (!skipExec) {
    const exec = await fetchTimed(vmUrl(vmId, "/exec"), {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ command: "true", timeoutMs: 10_000 }),
    });
    trial.execMs = exec.ms;
    trial.execStatus = exec.status;
    requireStatus("POST exec", exec);
    // The HTTP status only says the API ran the command; the sample is the
    // guest's `true` exiting 0.
    const execExit = json(exec.text).exitCode;
    if (execExit !== 0) throw new Error(`POST exec: guest command exited ${execExit ?? "unknown"}`);
  }
  if (edgeCheck) Object.assign(trial, await edgeReady(vmId));
  if (!skipPause) {
    const pause = await fetchTimed(vmUrl(vmId, "/pause"), { method: "POST", headers: authHeaders });
    trial.pauseMs = pause.ms;
    trial.pauseStatus = pause.status;
    requireStatus("POST pause", pause);
    Object.assign(trial, await attachUntilReady(vmId, "resumeAttach"));
  }
  const destroy = await fetchTimed(vmUrl(vmId), { method: "DELETE", headers: authHeaders });
  trial.destroyMs = destroy.ms;
  trial.destroyStatus = destroy.status;
  // A failed destroy keeps the id in liveVmIds so the exit path retries it.
  requireStatus("DELETE /api/vm/{id}", destroy);
  liveVmIds.delete(vmId);
  return trial;
}

async function runBatches() {
  const results = [];
  let next = 0;
  const workers = Array.from({ length: concurrency }, async () => {
    for (;;) {
      const index = next;
      next += 1;
      if (index >= trials || interrupted) return;
      const startedAt = performance.now();
      try {
        results[index] = await runTrial(index);
      } catch (error) {
        results[index] = { index, ok: false, error: error instanceof Error ? error.message : String(error), failedAfterMs: elapsedMs(startedAt) };
      }
    }
  });
  await Promise.all(workers);
  return results;
}

/**
 * Reconcile before deleting: a create whose response was lost (timeout,
 * interrupt) still made a machine under this throwaway user, and the user
 * owns nothing else, so every listed machine is ours to destroy.
 */
async function reconcileOwnedVms() {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const list = await fetchTimed(`${targetUrl}/api/vm`, { headers: authHeaders });
      if (list.status === 200) {
        for (const vm of json(list.text).vms ?? []) {
          if (typeof vm.id === "string" && vm.status !== "destroyed") liveVmIds.add(vm.id);
        }
        return true;
      }
      console.error(`cleanup_list_failed status=${list.status}`);
    } catch (error) {
      console.error(`cleanup_list_failed error=${error instanceof Error ? error.message : String(error)}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  return false;
}

/** True only when an authoritative fleet listing was read and every machine on it is gone. */
async function destroyLeftovers() {
  if (!authHeaders) return true;
  const verified = await reconcileOwnedVms();
  for (const vmId of [...liveVmIds]) {
    // Three attempts: a transient DELETE failure must not strand a machine.
    for (let attempt = 0; attempt < 3 && liveVmIds.has(vmId); attempt += 1) {
      try {
        const destroy = await fetchTimed(vmUrl(vmId), { method: "DELETE", headers: authHeaders });
        if (destroy.status === 200 || destroy.status === 404) liveVmIds.delete(vmId);
        else console.error(`cleanup_delete_failed_vm=${vmId} status=${destroy.status}`);
      } catch (error) {
        console.error(`cleanup_delete_failed_vm=${vmId} error=${error instanceof Error ? error.message : String(error)}`);
      }
      if (liveVmIds.has(vmId)) await new Promise((resolve) => setTimeout(resolve, 2_000));
    }
  }
  return verified && liveVmIds.size === 0;
}

/** The provider's view of the throwaway user's owner network, or null when none exists. */
async function ownerVpc(userId) {
  try {
    return await providerSdk.vpc.get(ownerNetworkSlug(userId));
  } catch (error) {
    if (error instanceof FreestyleApiError && error.status === 404) return null;
    throw error;
  }
}

/**
 * Every provider machine attached to `vpcId`, paged through the account
 * inventory until the provider's own `totalCount` is covered. Ids found
 * before a failed page are still returned; `complete` is false when the
 * inventory could not be read to the end, which callers treat as unverified.
 */
async function machinesOnVpc(vpcId) {
  const ids = [];
  let offset = 0;
  let total = Number.POSITIVE_INFINITY;
  let complete = false;
  while (offset < total && offset < 100_000) {
    let page = null;
    for (let attempt = 0; attempt < 3 && page === null; attempt += 1) {
      try {
        page = await providerSdk.vms.list({ limit: 200, offset });
      } catch (error) {
        if (attempt === 2) console.error(`cleanup_provider_inventory_failed offset=${offset} error=${error instanceof Error ? error.message : String(error)}`);
        else await sleep(1_500);
      }
    }
    if (page === null) return { ids, complete };
    for (const vm of page.vms) {
      if ((vm.vpcs ?? vm.networks ?? []).some((network) => (network.vpcId ?? network.vpc) === vpcId)) ids.push(vm.id);
    }
    total = typeof page.totalCount === "number" ? page.totalCount : (page.vms.length < 200 ? offset + page.vms.length : total);
    if (page.vms.length === 0) break;
    offset += page.vms.length;
  }
  complete = offset >= total;
  if (!complete) console.error(`cleanup_provider_inventory_failed truncated at ${offset} of ${total}`);
  return { ids, complete };
}

/**
 * Provider-side reconciliation: the control plane's list only knows rows
 * with a persisted provider id, but a create can allocate a machine and lose
 * it before that write (seen during the #12905 runs). Every machine on the
 * throwaway user's own network is this run's, so delete them all and verify
 * the network is empty. Returns true only when verified.
 */
async function reapOwnerVpcMachines(userId) {
  try {
    const vpc = await ownerVpc(userId);
    if (!vpc) return true;
    const found = await machinesOnVpc(vpc.id);
    for (const id of found.ids) {
      console.error(`cleanup_reconcile_vm=${id}`);
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          await providerSdk.vms.delete(id);
          break;
        } catch (error) {
          if (error instanceof FreestyleApiError && error.status === 404) break;
          if (attempt === 2) console.error(`cleanup_delete_failed_vm=${id} error=${error instanceof Error ? error.message : String(error)}`);
          else await sleep(2_000);
        }
      }
    }
    const remaining = await machinesOnVpc(vpc.id);
    for (const id of remaining.ids) console.error(`cleanup_needed_vm=${id}`);
    return found.complete && remaining.complete && remaining.ids.length === 0;
  } catch (error) {
    console.error(`cleanup_provider_inventory_failed error=${error instanceof Error ? error.message : String(error)}`);
    return false;
  }
}

/**
 * Removes the throwaway user's owner network (the VPC its first create made)
 * straight at the provider, by the same slug the application derives. The
 * fallback for an account deletion that failed after its own data cleanup; a
 * 404 means the route (or nothing) already removed it.
 */
async function reapOwnerNetwork(userId) {
  const slug = ownerNetworkSlug(userId);
  const provider = providerSdk;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    try {
      await provider.vpc.delete(slug);
      console.error(`cleanup_network_deleted=${slug}`);
      return true;
    } catch (error) {
      if (error instanceof FreestyleApiError && error.status === 404) return true;
      // Addresses are released asynchronously after the last machine delete.
      if (!(error instanceof FreestyleApiError && error.status === 409)) {
        console.error(`cleanup_network_failed=${slug} error=${error instanceof Error ? error.message : String(error)}`);
        return false;
      }
      await sleep(2_500);
    }
  }
  console.error(`cleanup_network_failed=${slug} error=still reserved after retries`);
  return false;
}

/**
 * Deletes the throwaway account through the application's own account
 * deletion, which also removes the owner network the first create made
 * (`deletePrivateNetworkingForAccountDeletion`), tunnels, leases and usage
 * rows. Deleting only the Stack identity would leave that provider VPC behind.
 */
/**
 * Outcomes: "deleted" (200); "cleanup_incomplete" (202: the Stack identity is
 * gone but the route's post-Stack cleanup did not finish, so the network must
 * be verified separately); "retryable_failure" (the route's own resumable
 * state machine answered `retryable: true` three times, so its checkpoints
 * stay valid for a later retry); "failed" (an unclassified answer, after
 * which nothing about the account's state is known). A `202 {deletionPending}`
 * means another deletion of the same account is still running and is waited on.
 */
async function deleteAccount() {
  let retryableFailures = 0;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const response = await fetchTimed(`${targetUrl}/api/account`, { method: "DELETE", headers: authHeaders }, 300_000);
    const body = json(response.text);
    if (response.status === 200) return "deleted";
    if (response.status === 202 && body.cleanupIncomplete === true) return "cleanup_incomplete";
    if (response.status === 202 && body.deletionPending === true) {
      await sleep(5_000);
      continue;
    }
    console.error(`cleanup_delete_account_failed attempt=${attempt + 1} status=${response.status} body=${response.text.slice(0, 200)}`);
    if (body.retryable !== true) return "failed";
    retryableFailures += 1;
    if (retryableFailures >= 3) return "retryable_failure";
    await sleep(5_000);
  }
  return "failed";
}

function positiveInteger(raw, flag) {
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) {
    console.error(`${flag} must be a positive integer`);
    process.exit(2);
  }
  return value;
}

/** Everything teardown learned, so the report can say what really happened. */
async function runCleanup() {
  const cleanup = { machinesGone: false, providerClean: false, accountOutcome: null, accountDeleted: false, identityGone: false, leftoverVmIds: [], keptUser: null };
  cleanup.machinesGone = await destroyLeftovers();
  for (const vmId of liveVmIds) console.error(`cleanup_needed_vm=${vmId}`);
  cleanup.leftoverVmIds = [...liveVmIds];
  // The control plane's list is not the provider's inventory: sweep the
  // user's own network at the provider before any account cleanup.
  cleanup.providerClean = user ? await reapOwnerVpcMachines(user.id) : true;
  if (user && cleanup.machinesGone && cleanup.providerClean) {
    let outcome = "failed";
    try {
      outcome = await deleteAccount();
    } catch (cleanupError) {
      console.error(`cleanup_delete_account_failed error=${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
    }
    cleanup.accountOutcome = outcome;
    if (outcome === "deleted") cleanup.accountDeleted = true;
    if (outcome === "cleanup_incomplete") {
      // The identity is already gone; only the network can still be verified.
      cleanup.identityGone = true;
      cleanup.accountDeleted = await reapOwnerNetwork(user.id);
      if (!cleanup.accountDeleted) console.error(`cleanup_needed_network=${ownerNetworkSlug(user.id)} (the account route deleted the identity but its cleanup did not finish)`);
    }
    if (outcome === "retryable_failure") {
      // The route answered with its resumable contract (a checkpoint is
      // recorded; on staging it fails at the final Stack step after it has
      // already removed the cmux-owned data). Provider inventory is verified
      // empty above, so take the network out by its slug and drop the
      // identity with the server key: no billable resource outlives the
      // account, and at worst inert rows for a deleted user remain. An
      // unclassified failure ("failed") never reaches this branch: the user
      // is kept so the route can be retried with its state intact.
      try {
        if (await reapOwnerNetwork(user.id)) {
          await user.delete();
          cleanup.accountDeleted = true;
          console.error("cleanup_note=account deletion route failed; the owner network was removed at the provider and the Stack identity with the server key (a cloud_vm_networks row for the deleted user may remain)");
        }
      } catch (cleanupError) {
        console.error(`cleanup_delete_user_failed error=${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      }
    }
  }
  if (user && !cleanup.accountDeleted && !cleanup.identityGone) {
    // The throwaway user is the only credential that still owns whatever is
    // left (machines, or the owner network the app deletes with the account);
    // deleting the identity now would make them unreachable to any retry.
    cleanup.keptUser = user.primaryEmail ?? user.id;
    console.error(`cleanup_needed_user=${cleanup.keptUser} (kept so its resources can still be cleaned up: mint a session for this user with the Stack server key and call DELETE ${targetUrl}/api/account, which also removes its owner network)`);
  }
  cleanup.ok = !user || (cleanup.accountDeleted && cleanup.leftoverVmIds.length === 0);
  return cleanup;
}

/** The report is written once, after teardown, so a stored artifact never claims a success cleanup later denied. */
function emitReport({ results, listMs, startedAt, runError, cleanup }) {
  const ok = results.filter((trial) => trial && trial.ok !== false);
  const summary = {
    ok: !runError && !interrupted && cleanup.ok && ok.length === results.length && results.length === trials,
    interrupted,
    runError: runError ? (runError instanceof Error ? runError.message : String(runError)) : null,
    cleanup,
    target,
    url: targetUrl,
    label,
    trials,
    concurrency,
    listMs,
    totalMs: startedAt === null ? null : elapsedMs(startedAt),
    succeeded: ok.length,
    failed: results.length - ok.length,
    stages: summarizeFields(ok, ["createMs", "attachMs", "createToUsableMs", "warmAttachMs", "execMs", "edgeReadyMs", "pauseMs", "resumeAttachMs", "destroyMs"]),
    attachAttempts: summarizeFields(ok.map((trial) => ({ attempts: trial.attachAttempts?.length })), ["attempts"]).attempts,
    createServerTiming: summarizeStages(ok.map((trial) => trial.createStages)),
    results,
  };
  if (ok.length > 0) {
    console.error(formatSummary({ ...summary.stages, ...Object.fromEntries(Object.entries(summary.createServerTiming).map(([name, value]) => [`server:${name}`, value])) }));
  }
  const text = JSON.stringify(summary);
  if (outPath) writeFileSync(outPath, `${text}\n`);
  console.log(text);
  if (!summary.ok) process.exitCode = 1;
}

let results = [];
let listMs = null;
let startedAt = null;
let runError = null;
try {
  user = await app.createUser({
    primaryEmail: `cmux-${project.stackLabel}-bench+${suffix}@manaflow.dev`,
    primaryEmailVerified: true,
    primaryEmailAuthEnabled: true,
    password: randomBytes(24).toString("base64url"),
    displayName: `cmux ${project.stackLabel} startup bench`,
  });
  // Provisioning is paid-plan gated; the plan is metadata on the throwaway user only.
  await user.update({ clientReadOnlyMetadata: { cmuxVmPlan: "pro" } });
  // The session must outlive the whole run and its cleanup: budget the worst
  // case per trial (a 630 s create plus attach, resume and destroy budgets)
  // and cap at a day, past which the run fails closed and keeps the user.
  const sessionMs = Math.min(24 * 60 * 60 * 1000, 30 * 60 * 1000 + trials * 20 * 60 * 1000);
  const session = await user.createSession({ expiresInMillis: sessionMs, isImpersonation: true });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) throw new Error("Stack did not return bench session tokens");
  authHeaders = { authorization: `Bearer ${tokens.accessToken}`, "x-stack-refresh-token": tokens.refreshToken };

  const list = await fetchTimed(`${targetUrl}/api/vm`, { headers: authHeaders });
  if (list.status !== 200) throw new Error(`authenticated GET /api/vm expected 200, got ${list.status}: ${list.text.slice(0, 200)}`);
  listMs = list.ms;

  startedAt = performance.now();
  results = await runBatches();
} catch (error) {
  runError = error;
  console.error(error instanceof Error ? error.message : String(error));
} finally {
  const cleanup = await runCleanup();
  emitReport({ results, listMs, startedAt, runError, cleanup });
  process.off("SIGINT", interrupt);
  process.off("SIGTERM", interrupt);
}
