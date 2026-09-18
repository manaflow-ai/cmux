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
// A request is never abandoned while the server may still be working on it:
// the client waits past the platform's own bound, so teardown's DELETE can
// never race an attach that is still healing the machine or writing its
// lease. Routes without a maxDuration of their own (attach-endpoint, pause,
// account) end at Vercel's Fluid compute default of 300 s (the project sets
// no other default); the Mac client itself waits 16 minutes on these calls.
const REQUEST_TIMEOUT_MS = 330_000;
// The create route keeps provisioning for up to its own maxDuration (600 s);
// aborting the client earlier would strand a machine this run never learns
// the id of. Wait at least that long, and reconcile through the fleet list
// at exit anyway (the throwaway user owns nothing else).
const CREATE_TIMEOUT_MS = 630_000;
// Bounds when a new attach attempt may start; it never cuts a request short.
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
const benchEmail = `cmux-${project.stackLabel}-bench+${suffix}@manaflow.dev`;
const liveVmIds = new Set();
// Creates whose response never arrived (idempotency key → request time): the
// server may still be making the machine, so teardown resolves them first.
const ambiguousCreates = new Map();
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

/**
 * The provider SDK polls a backgrounded request indefinitely while the
 * platform answers 202, so every cleanup call to it is raced against a
 * deadline; the request itself cannot be cancelled, and the sweep that
 * follows re-reads the inventory anyway.
 */
function boundedSdk(promise, ms, label) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms} ms`)), ms);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
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
    // The stage budget gates new attempts only: a request in flight runs
    // until the server answers or the platform ends it, so the client never
    // walks away from an attach that is still mutating the machine.
    if (performance.now() - startedAt >= ATTACH_BUDGET_MS || interrupted) {
      throw new Error(`${stage} attach for ${vmId} did not succeed within ${ATTACH_BUDGET_MS} ms (${attempts.length} attempts)`);
    }
    const response = await fetchTimed(vmUrl(vmId, "/attach-endpoint"), {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ transport: "cmux-remote", clientCapabilities: ["wireguard-hub", "direct-ws-user-agent"] }),
    });
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
  const idempotencyKey = `bench-${suffix}-${index}`;
  const createRequestedAt = Date.now();
  let create;
  try {
    create = await fetchTimed(`${targetUrl}/api/vm`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": idempotencyKey },
      body: "{}",
    }, CREATE_TIMEOUT_MS);
  } catch (error) {
    // No response at all (reset, abort): the server may still be creating
    // with nothing recorded yet, invisible to both sweeps until it finishes.
    ambiguousCreates.set(idempotencyKey, createRequestedAt);
    throw error;
  }
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
 * A create whose response never arrived may still be running on the server
 * (up to the route's maxDuration) with nothing recorded, so neither sweep
 * would see its machine yet. Re-POSTing the same idempotency key answers 200
 * with the machine once it exists, 409 while it is still being made, and
 * `vm_create_failed` when nothing will be; a key the server never received
 * simply creates a machine now, which is destroyed like any other. Past the
 * server deadline nothing can still be in progress, so the sweeps that
 * follow are authoritative either way. Returns the keys left unresolved.
 */
async function resolveAmbiguousCreates() {
  const unresolved = [];
  for (const [key, requestedAt] of ambiguousCreates) {
    const deadline = requestedAt + CREATE_TIMEOUT_MS;
    let outcome = null;
    while (outcome === null) {
      try {
        const response = await fetchTimed(`${targetUrl}/api/vm`, {
          method: "POST",
          headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": key },
          body: "{}",
        }, CREATE_TIMEOUT_MS);
        const body = json(response.text);
        if (response.status === 200 && typeof body.id === "string") {
          liveVmIds.add(body.id);
          outcome = `vm=${body.id}`;
        } else if (body.error === "vm_create_failed") {
          outcome = "failed";
        } else if (response.status < 500 && response.status !== 409) {
          // A 409 (in progress, or a limit the original create may already
          // hold) is not an answer about the original request; keep asking.
          outcome = `rejected status=${response.status}`;
        }
      } catch (error) {
        console.error(`cleanup_resolve_create_failed key=${key} error=${error instanceof Error ? error.message : String(error)}`);
      }
      if (outcome === null) {
        if (Date.now() >= deadline) {
          outcome = "past server deadline";
          unresolved.push(key);
        } else {
          await sleep(5_000);
        }
      }
    }
    console.error(`cleanup_resolve_create key=${key} ${outcome}`);
  }
  ambiguousCreates.clear();
  return unresolved;
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
    return await boundedSdk(providerSdk.vpc.get(ownerNetworkSlug(userId)), 30_000, "vpc get");
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
        page = await boundedSdk(providerSdk.vms.list({ limit: 200, offset }), 60_000, "vms list");
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
          await boundedSdk(providerSdk.vms.delete(id), 60_000, "vm delete");
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
      await boundedSdk(provider.vpc.delete(slug), 60_000, "vpc delete");
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
 * Outcomes: "deleted" (200); "cleanup_incomplete" (the route deleted the
 * Stack identity but its post-Stack cleanup stayed incomplete after the
 * resume path was retried, so an operator follow-up is needed);
 * "retryable_failure" (the route's own resumable state machine answered
 * `retryable: true` three times; its checkpoints stay valid for a later
 * retry with the identity kept); "failed" (an unclassified answer). A
 * `202 {deletionPending}` means another deletion of the same account is still
 * running and is waited on; a `202 {cleanupIncomplete}` is retried because a
 * later call resumes the post-Stack cleanup.
 */
async function deleteAccount() {
  let retryableFailures = 0;
  let incompleteAnswers = 0;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const response = await fetchTimed(`${targetUrl}/api/account`, { method: "DELETE", headers: authHeaders });
    const body = json(response.text);
    if (response.status === 200) return "deleted";
    if (response.status === 202 && body.deletionPending === true) {
      await sleep(5_000);
      continue;
    }
    if (response.status === 202 && body.cleanupIncomplete === true) {
      incompleteAnswers += 1;
      if (incompleteAnswers >= 3) return "cleanup_incomplete";
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

/**
 * A user whose creation response was lost is found by its generated email
 * with the server key. `verified` is false when the lookup itself failed
 * after retries: the caller then does not know whether an identity exists
 * and must not claim there is nothing to clean up.
 */
async function reconcileCreatedUser() {
  if (user) return { user, verified: true };
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const listed = await app.listUsers({ query: benchEmail, limit: 5 });
      const found = listed.find((candidate) => candidate.primaryEmail === benchEmail) ?? null;
      if (found) console.error(`cleanup_reconciled_user=${benchEmail}`);
      return { user: found, verified: true };
    } catch (error) {
      console.error(`cleanup_user_lookup_failed attempt=${attempt + 1} error=${error instanceof Error ? error.message : String(error)}`);
      if (attempt < 2) await sleep(2_000);
    }
  }
  return { user: null, verified: false };
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
  const cleanup = { machinesGone: false, providerClean: false, accountOutcome: null, accountDeleted: false, identityGone: false, identityUnknown: false, unresolvedCreates: [], leftoverVmIds: [], keptUser: null };
  if (!user && !authHeaders) {
    const lookup = await reconcileCreatedUser();
    user = lookup.user;
    if (!user && !lookup.verified) {
      // createUser threw after Stack may already have persisted the identity,
      // and the server-key lookup failed too: whether a user exists is
      // unknown, which is a cleanup failure for an operator, never a clean exit.
      cleanup.identityUnknown = true;
      cleanup.keptUser = benchEmail;
      cleanup.ok = false;
      console.error(`cleanup_needed_user=${benchEmail} (creation response lost and the Stack lookup failed; check for this identity with the Stack server key and delete it)`);
      return cleanup;
    }
  }
  if (user && !authHeaders) {
    // Setup failed before a session existed, so no API call and no machine
    // was ever made in this user's name; the provider sweep still runs by
    // the user's slug, then the identity is removed with the server key.
    cleanup.machinesGone = true;
    cleanup.providerClean = await reapOwnerVpcMachines(user.id);
    if (cleanup.providerClean && (await reapOwnerNetwork(user.id))) {
      try {
        await user.delete();
        cleanup.accountDeleted = true;
        cleanup.accountOutcome = "no_session";
      } catch (cleanupError) {
        console.error(`cleanup_delete_user_failed error=${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      }
    }
    if (!cleanup.accountDeleted) {
      cleanup.keptUser = user.primaryEmail ?? user.id;
      console.error(`cleanup_needed_user=${cleanup.keptUser} (session setup failed; delete this identity with the Stack server key)`);
    }
    cleanup.ok = cleanup.accountDeleted;
    return cleanup;
  }
  cleanup.unresolvedCreates = await resolveAmbiguousCreates();
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
      // The identity is gone and the route's resume path was retried; what
      // remains (tombstone, analytics cleanup) needs an operator, so this is
      // reported as a cleanup failure, not a success. The provider network is
      // still taken out so no billable resource is left behind.
      cleanup.identityGone = true;
      await reapOwnerNetwork(user.id);
      console.error(`cleanup_needed_account_followup=${user.id} (the account route deleted the identity but its post-Stack cleanup stayed incomplete after retries)`);
    }
    if (outcome === "retryable_failure" || outcome === "failed") {
      // The application's account deletion is the only path that removes its
      // own rows (machines, leases, usage, tombstones). It is resumable, so
      // the identity is kept for a later DELETE /api/account; only the
      // provider-side network is taken out here so nothing billable remains.
      await reapOwnerNetwork(user.id);
    }
  }
  if (user && !cleanup.accountDeleted && !cleanup.identityGone) {
    // The throwaway user is the only credential that still owns whatever is
    // left; deleting the identity now would strand the application's rows
    // behind an account its own deletion can no longer resume.
    cleanup.keptUser = user.primaryEmail ?? user.id;
    console.error(`cleanup_needed_user=${cleanup.keptUser} (kept so the application's own account deletion can be retried: mint a session for this user with the Stack server key and call DELETE ${targetUrl}/api/account)`);
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
    primaryEmail: benchEmail,
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
