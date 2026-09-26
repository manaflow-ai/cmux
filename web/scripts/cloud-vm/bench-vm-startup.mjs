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
import { writeFileSync, writeSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { CREATE_ADMISSION_BUDGET_MS, elapsedMs, formatSummary, ownerNetworkSlug, parseServerTiming, pollBoundedFetch, providerCredentialsFromEnv, summarizeCreateAdmission, summarizeFields, summarizeStages } from "./benchStats.mjs";
import { loadTargetEnv, optionValue, parseWebDirAndTarget, requireEnvKeys, runVercel } from "./projects.mjs";

const usage = "Usage: bench-vm-startup.mjs [web-dir] <staging|production> [--trials N] [--concurrency K] [--url https://preview.example] [--allow-preview] [--allow-any-url] [--skip-pause] [--skip-exec] [--edge-check] [--edge-alias <host>] [--label <text>] [--out <file.json>]";
const { webDir, target, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const trials = positiveInteger(optionValue(rest, "--trials") ?? "3", "--trials");
const concurrency = Math.min(positiveInteger(optionValue(rest, "--concurrency") ?? "1", "--concurrency"), trials);
const targetUrl = resolveTargetUrl(project, rest);
const skipPause = rest.includes("--skip-pause");
const skipExec = rest.includes("--skip-exec");
// Full-feature readiness: poll the model-plane edge alias from inside the
// guest until the coderouter reflection route answers, so the report can
// separate "terminal usable" from "agents can reach their credentials". The
// alias host is the one the target deployment configures for its guests
// (CMUX_VM_EDGE_ALIAS_DOMAIN in the pulled env, the runtime's default
// otherwise), or --edge-alias; it is resolved once the env is loaded.
const edgeCheck = rest.includes("--edge-check");
const edgeAliasOption = optionValue(rest, "--edge-alias");
const DEFAULT_EDGE_ALIAS_HOST = "coderouter.cmux.internal";
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
const { StackServerApp } = await import(pathToFileURL(requireFromWeb.resolve("@hexclave/js")).href);
// ESM-only package (no require entry): resolved from this script's own tree.
const { Freestyle, FreestyleApiError } = await import("freestyle");

const env = loadTargetEnv(project);
// A Vercel "sensitive" variable pulls as an empty string (projects.mjs); the
// operator's own copy of the same value fills it, and
// CMUX_CLOUD_VM_ENV_SOURCE=process skips the pull altogether.
for (const key of ["NEXT_PUBLIC_STACK_PROJECT_ID", "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", "STACK_SECRET_SERVER_KEY"]) {
  if (!env[key]?.trim() && process.env[key]?.trim()) env[key] = process.env[key].trim();
}
requireEnvKeys(env, ["NEXT_PUBLIC_STACK_PROJECT_ID", "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", "STACK_SECRET_SERVER_KEY"], `${project.projectName} bench (export the missing keys, or set CMUX_CLOUD_VM_ENV_SOURCE=process)`);
// Cleanup is verified against the provider's own inventory (a create can
// allocate a machine the control plane never records), so the deployment's
// provider credentials are required, in either form the runtime's client
// accepts (freestyleClient in services/vms/drivers/freestyle.ts): an API key,
// or a Stack access token with a team id. A sensitive value pulls empty; the
// operator's own copy (~/.secrets/cmux.env, the same account) covers that.
const edgeAliasHost = edgeAliasOption?.trim() || env.CMUX_VM_EDGE_ALIAS_DOMAIN?.trim() || DEFAULT_EDGE_ALIAS_HOST;
if (!/^[a-z0-9.-]+$/i.test(edgeAliasHost)) {
  console.error(`bench-vm-startup: the edge alias must be a bare host name, got ${JSON.stringify(edgeAliasHost)}`);
  process.exit(2);
}
const EDGE_PROBE = `curl -s -o /dev/null -w '%{http_code}' --max-time 4 https://${edgeAliasHost}/api/vm/reflection`;
// A complete credential form from the deployment's pulled env first (the
// account that allocates the benchmark machines), in either form the
// runtime accepts; the operator's own environment only when the pull holds
// none (a Vercel "sensitive" value pulls empty; ~/.secrets/cmux.env is the
// same account). The two are never mixed key by key, or a local API key
// could shadow the deployment's token pair and cleanup would inspect the
// wrong account.
const providerCredentials = providerCredentialsFromEnv(env) ?? providerCredentialsFromEnv(process.env);
if (!providerCredentials) {
  console.error("bench-vm-startup: FREESTYLE_API_KEY, or FREESTYLE_STACK_ACCESS_TOKEN with FREESTYLE_TEAM_ID, is required (pulled target env or process env) so cleanup can verify provider inventory");
  process.exit(2);
}
// Every provider fetch is bounded and the SDK's polling of a backgrounded
// request ends at a deadline (pollBoundedFetch), so teardown's wait for
// tracked requests is bounded by construction; a request abandoned at that
// deadline may still complete at the platform and is reported as unresolved.
const providerPolling = pollBoundedFetch({ fetchTimeoutMs: 60_000, pollDeadlineMs: 15 * 60 * 1000 });
const providerSdk = new Freestyle({ ...providerCredentials, fetch: providerPolling.fetch });
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

/**
 * A bounded wait that returns early on SIGINT/SIGTERM instead of holding
 * teardown for the full delay. Only the waits in flight when the signal
 * arrives are cut short; a wait started afterwards runs its full delay, so a
 * cleanup retry loop keeps its backoff after an interrupt instead of
 * spinning, and keeps running because every resource must still go.
 */
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
 * deadline. The request itself cannot be cancelled: it stays tracked until
 * it settles, and teardown waits for it (bounded) before the network and the
 * account go, and again before the process exits.
 */
const providerInFlight = new Set();
function boundedSdk(promise, ms, label) {
  providerInFlight.add(promise);
  promise.then(() => providerInFlight.delete(promise), () => providerInFlight.delete(promise));
  return withTimeout(promise, ms, label);
}

/**
 * Races a call against a deadline without tracking it: the Stack SDK offers
 * no cancellation either, but a slow identity service must not hold setup
 * or teardown indefinitely, and unlike a provider request its completion
 * never needs waiting for (a user created late is found by email).
 */
function withTimeout(promise, ms, label) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms} ms`)), ms);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}
const STACK_TIMEOUT_MS = 60_000;

/**
 * Blocks until every tracked provider request has settled, reporting every
 * ten minutes. A mutation the SDK cannot cancel must never be swept past or
 * abandoned: a delete that completed after the inventory was read, or after
 * the account went, would leave a resource behind. The wait is bounded by
 * construction: the client's fetch timeout and polling deadline
 * (pollBoundedFetch) settle every request within about the deadline.
 */
async function waitProviderSettled() {
  while (!(await settleProviderRequests(600_000))) console.error(`cleanup_still_in_flight=${providerInFlight.size} (waiting for them to settle)`);
}

/** Waits (bounded) for every timed-out provider request to settle; false when some are still running. */
async function settleProviderRequests(ms) {
  if (providerInFlight.size === 0) return true;
  console.error(`cleanup_waiting_for_in_flight=${providerInFlight.size}`);
  let timer;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(resolve, ms);
  });
  try {
    await Promise.race([Promise.allSettled([...providerInFlight]), deadline]);
  } finally {
    clearTimeout(timer);
  }
  return providerInFlight.size === 0;
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

async function runTrial(trial) {
  const { index } = trial;
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
  if (create.status >= 500) {
    // A 5xx (a gateway or function timeout above all) can end the invocation
    // while the provider create continues, with nothing recorded yet; the
    // key is resolved before teardown like a lost response.
    ambiguousCreates.set(idempotencyKey, createRequestedAt);
  }
  requireStatus("POST /api/vm", create);
  const created = json(create.text);
  const vmId = created.id;
  if (!vmId) throw new Error("create response missing id");
  liveVmIds.add(vmId);
  trial.vmId = vmId;
  trial.imageVersion = created.imageVersion ?? null;
  trial.size = created.size?.name ?? null;
  Object.assign(trial, await attachUntilReady(vmId, "attach"));
  // Create plus the attach-endpoint's own time: the route and lease exist,
  // but the link, the terminal and the shell prompt come after this point
  // (bench-private-link.ts measures those), so this is attach readiness,
  // not a usable terminal.
  trial.createToAttachReadyMs = trial.createMs + trial.attachMs;
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
      const trial = { index, startedAt: new Date().toISOString() };
      const startedAt = performance.now();
      try {
        results[index] = await runTrial(trial);
      } catch (error) {
        // The partial record keeps every stage that did complete, and the
        // create trace id, so a failure late in a trial still contributes
        // its earlier measurements and the evidence to investigate it.
        results[index] = { ...trial, ok: false, error: error instanceof Error ? error.message : String(error), failedAfterMs: elapsedMs(startedAt) };
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
      // The route's deadline bounds every attempt, the request included:
      // once it has passed nothing can still be in progress, and no further
      // request (which could itself start a create) is issued.
      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        outcome = "past server deadline";
        unresolved.push(key);
        break;
      }
      try {
        const response = await fetchTimed(`${targetUrl}/api/vm`, {
          method: "POST",
          headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": key },
          body: "{}",
        }, Math.min(CREATE_TIMEOUT_MS, remainingMs));
        const body = json(response.text);
        if (response.status === 200 && typeof body.id === "string") {
          liveVmIds.add(body.id);
          outcome = `vm=${body.id}`;
        } else if (body.error === "vm_create_failed") {
          outcome = "failed";
        }
        // Anything else (409 in progress, a rate limit, an auth hiccup, a
        // gateway error) answers about this replay, not about the original
        // request, which may still be provisioning under the key: keep
        // asking until the route's deadline, past which the key stays
        // unresolved and the account is kept.
      } catch (error) {
        console.error(`cleanup_resolve_create_failed key=${key} error=${error instanceof Error ? error.message : String(error)}`);
      }
      if (outcome === null) await sleep(Math.min(5_000, Math.max(1, deadline - Date.now())));
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
 * with the server key. The lookup is a search, so an empty answer can be
 * the index lagging a committed create: absence is retried and never taken
 * as proof. `verified` is true only when the user was found; otherwise the
 * caller does not know whether an identity exists and must not claim there
 * is nothing to clean up.
 */
async function reconcileCreatedUser() {
  if (user) return { user, verified: true };
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const listed = await withTimeout(app.listUsers({ query: benchEmail, limit: 5 }), STACK_TIMEOUT_MS, "Stack listUsers");
      const found = listed.find((candidate) => candidate.primaryEmail === benchEmail) ?? null;
      if (found) {
        console.error(`cleanup_reconciled_user=${benchEmail}`);
        return { user: found, verified: true };
      }
      console.error(`cleanup_user_lookup_empty attempt=${attempt + 1}`);
    } catch (error) {
      console.error(`cleanup_user_lookup_failed attempt=${attempt + 1} error=${error instanceof Error ? error.message : String(error)}`);
    }
    if (attempt < 4) await sleep(5_000);
  }
  return { user: null, verified: false };
}

/**
 * True only when Vercel itself says the host is a deployment of the selected
 * project in its team. A hostname pattern proves nothing (any tenant can name
 * a project `cmux-staging-…`), so ownership is read from the API; an error
 * or another project's deployment is a refusal.
 */
function deploymentBelongsToProject(host, project) {
  try {
    const output = runVercel(
      ["api", `/v13/deployments/${encodeURIComponent(host)}?teamId=${encodeURIComponent(project.orgId)}`],
      { stdio: ["ignore", "pipe", "ignore"] },
    );
    return JSON.parse(String(output))?.projectId === project.projectId;
  } catch {
    return false;
  }
}

/**
 * Every request carries the throwaway user's bearer and refresh tokens, so a
 * mistyped or untrusted --url must not receive them: only the selected
 * project's canonical https origin is accepted by default. A deployment that
 * Vercel attributes to the project is not thereby trusted (a preview can be
 * built from any branch), so it needs an explicit --allow-preview as well;
 * --allow-any-url records that the operator checked some other host. Plain
 * http is refused either way.
 */
function resolveTargetUrl(project, options) {
  const raw = optionValue(options, "--url");
  if (!raw) return project.url;
  let url;
  try {
    url = new URL(raw);
  } catch {
    console.error(`bench-vm-startup: --url is not a URL: ${raw}`);
    process.exit(2);
  }
  if (url.protocol !== "https:") {
    console.error(`bench-vm-startup: --url must be https, session tokens are sent with every request: ${raw}`);
    process.exit(2);
  }
  const canonicalHost = new URL(project.url).host;
  if (url.host !== canonicalHost && !options.includes("--allow-any-url")) {
    if (!options.includes("--allow-preview")) {
      console.error(`bench-vm-startup: --url host ${url.host} is not ${canonicalHost}; pass --allow-preview for a deployment of Vercel project ${project.projectName} that you trust, or --allow-any-url only for a host you control`);
      process.exit(2);
    }
    if (!deploymentBelongsToProject(url.host, project)) {
      console.error(`bench-vm-startup: --url host ${url.host} is not a deployment of Vercel project ${project.projectName}; pass --allow-any-url only for a host you control`);
      process.exit(2);
    }
  }
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

function positiveInteger(raw, flag) {
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) {
    console.error(`${flag} must be a positive integer`);
    process.exit(2);
  }
  return value;
}

/** The background requests abandoned at the polling deadline, each reported for an operator; their operations may still complete at the platform. */
function reportAbandonedProviderRequests() {
  for (const url of providerPolling.abandoned) console.error(`cleanup_unresolved_provider_request=${url}`);
  return [...providerPolling.abandoned];
}

/** A fresh session for the throwaway user; its tokens go only to the target origin. */
async function mintSessionHeaders(expiresInMillis) {
  const session = await withTimeout(user.createSession({ expiresInMillis, isImpersonation: true }), STACK_TIMEOUT_MS, "Stack createSession");
  const tokens = await withTimeout(session.getTokens(), STACK_TIMEOUT_MS, "Stack getTokens");
  if (!tokens.accessToken || !tokens.refreshToken) throw new Error("Stack did not return bench session tokens");
  return { authorization: `Bearer ${tokens.accessToken}`, "x-stack-refresh-token": tokens.refreshToken };
}

/** Everything teardown learned, so the report can say what really happened. */
async function runCleanup() {
  const cleanup = { machinesGone: false, providerClean: false, providerSettled: true, abandonedProviderRequests: [], accountOutcome: null, accountDeleted: false, identityGone: false, identityUnknown: false, unresolvedCreates: [], leftoverVmIds: [], keptUser: null };
  if (!user && !authHeaders) {
    const lookup = await reconcileCreatedUser();
    user = lookup.user;
    if (!user && !lookup.verified) {
      // createUser threw after Stack may already have persisted the identity,
      // and the server-key lookup did not find it (or failed): whether a
      // user exists is unknown, which is a cleanup failure for an operator,
      // never a clean exit.
      cleanup.identityUnknown = true;
      cleanup.keptUser = benchEmail;
      cleanup.ok = false;
      console.error(`cleanup_needed_user=${benchEmail} (creation response lost and no user with this email was found, or the lookup failed; absence cannot be proven, so check for this identity with the Stack server key and delete it if it exists)`);
      return cleanup;
    }
  }
  if (user && !authHeaders) {
    // Setup failed before a session existed, so no API call and no machine
    // was ever made in this user's name; the provider sweep still runs by
    // the user's slug, then the identity is removed with the server key.
    cleanup.machinesGone = true;
    cleanup.providerClean = await reapOwnerVpcMachines(user.id);
    await waitProviderSettled();
    // A delete that timed out may have completed while settling: read the
    // inventory once more before the network goes.
    if (!cleanup.providerClean) cleanup.providerClean = await reapOwnerVpcMachines(user.id);
    await waitProviderSettled();
    cleanup.providerSettled = true;
    cleanup.abandonedProviderRequests = reportAbandonedProviderRequests();
    if (cleanup.providerClean && cleanup.abandonedProviderRequests.length === 0 && (await reapOwnerNetwork(user.id))) {
      try {
        await withTimeout(user.delete(), STACK_TIMEOUT_MS, "Stack user delete");
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
  // Cleanup's own bounded waits can outlast the run's session, so it works
  // under a fresh one when Stack can mint it; the run's tokens remain the
  // fallback.
  try {
    authHeaders = await mintSessionHeaders(6 * 60 * 60 * 1000);
  } catch (error) {
    console.error(`cleanup_session_renewal_failed error=${error instanceof Error ? error.message : String(error)} (continuing with the run's session)`);
  }
  cleanup.unresolvedCreates = await resolveAmbiguousCreates();
  cleanup.machinesGone = await destroyLeftovers();
  for (const vmId of liveVmIds) console.error(`cleanup_needed_vm=${vmId}`);
  cleanup.leftoverVmIds = [...liveVmIds];
  // The control plane's list is not the provider's inventory: sweep the
  // user's own network at the provider before any account cleanup.
  cleanup.providerClean = user ? await reapOwnerVpcMachines(user.id) : true;
  // A timed-out provider request may still be mutating a machine; it must
  // settle before the network and the account are removed under it, and a
  // delete that completed while settling is seen by reading the inventory
  // once more.
  await waitProviderSettled();
  if (user && !cleanup.providerClean) cleanup.providerClean = await reapOwnerVpcMachines(user.id);
  await waitProviderSettled();
  cleanup.providerSettled = true;
  // A background request abandoned at the polling deadline settled here but
  // may still complete at the platform (a delete above all); the account
  // and its network stay until an operator has confirmed it.
  cleanup.abandonedProviderRequests = reportAbandonedProviderRequests();
  if (cleanup.unresolvedCreates.length > 0) {
    // A create whose outcome is still unknown could yet record a machine;
    // the account (and its network) stay until an operator reconciles it.
    console.error(`cleanup_unresolved_creates=${cleanup.unresolvedCreates.join(",")} (the account is kept until they are reconciled)`);
  }
  if (user && cleanup.machinesGone && cleanup.providerClean && cleanup.providerSettled && cleanup.unresolvedCreates.length === 0 && cleanup.abandonedProviderRequests.length === 0) {
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
  cleanup.ok = !user || (cleanup.accountDeleted && cleanup.leftoverVmIds.length === 0 && cleanup.unresolvedCreates.length === 0 && cleanup.providerSettled && cleanup.abandonedProviderRequests.length === 0);
  return cleanup;
}

/** The report is written once, after teardown, so a stored artifact never claims a success cleanup later denied. */
function emitReport({ results, listMs, startedAt, runError, cleanup }) {
  const ok = results.filter((trial) => trial && trial.ok !== false);
  // Every stage is summarized from the trials that completed it, a failed
  // trial's earlier stages included; `succeeded` counts whole trials.
  const measured = results.filter(Boolean);
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
    stages: summarizeFields(measured, ["createMs", "attachMs", "createToAttachReadyMs", "warmAttachMs", "execMs", "edgeReadyMs", "pauseMs", "resumeAttachMs", "destroyMs"]),
    // Admission is intentionally separate from createMs: it measures the
    // request's fast acknowledgement boundary, while createMs includes the
    // provider allocation and guest boot that follow it.
    createAdmission: summarizeCreateAdmission(measured.map((trial) => trial.createStages?.admission), CREATE_ADMISSION_BUDGET_MS),
    attachAttempts: summarizeFields(measured.map((trial) => ({ attempts: trial.attachAttempts?.length })), ["attempts"]).attempts,
    createServerTiming: summarizeStages(measured.map((trial) => trial.createStages)),
    results,
  };
  if (measured.length > 0) {
    writeSync(2, `${formatSummary({ ...summary.stages, ...Object.fromEntries(Object.entries(summary.createServerTiming).map(([name, value]) => [`server:${name}`, value])) })}\n`);
  }
  const text = JSON.stringify(summary);
  if (outPath) writeFileSync(outPath, `${text}\n`);
  writeSync(1, `${text}\n`);
  if (!summary.ok) process.exitCode = 1;
}

let results = [];
let listMs = null;
let startedAt = null;
let runError = null;
try {
  user = await withTimeout(app.createUser({
    primaryEmail: benchEmail,
    primaryEmailVerified: true,
    primaryEmailAuthEnabled: true,
    password: randomBytes(24).toString("base64url"),
    displayName: `cmux ${project.stackLabel} startup bench`,
  }), STACK_TIMEOUT_MS, "Stack createUser");
  // Provisioning is paid-plan gated; the plan is metadata on the throwaway user only.
  await withTimeout(user.update({ clientReadOnlyMetadata: { cmuxVmPlan: "pro" } }), STACK_TIMEOUT_MS, "Stack user update");
  // The session must outlive the trials at their bounds: per trial, the
  // create's deadline, three attach stages (each its budget plus one more
  // request), exec, pause and destroy requests and the edge probe, in
  // ceil(trials / concurrency) rounds; capped at a day. Cleanup mints its
  // own fresh session, so it does not depend on this one.
  const trialWorstMs = CREATE_TIMEOUT_MS + 3 * (ATTACH_BUDGET_MS + REQUEST_TIMEOUT_MS) + 3 * REQUEST_TIMEOUT_MS + EDGE_BUDGET_MS + REQUEST_TIMEOUT_MS;
  const sessionMs = Math.min(24 * 60 * 60 * 1000, 30 * 60 * 1000 + Math.ceil(trials / concurrency) * trialWorstMs);
  authHeaders = await mintSessionHeaders(sessionMs);

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
// A provider request that outlived its bound is at worst a delete still in
// progress. The SDK cannot cancel it and exiting would abandon it, so the
// process stays alive until every tracked request has settled (the run has
// already reported them and the exit code is set), then exits explicitly,
// because the SDK's 202 polling timer would otherwise keep an idle process
// alive after everything has settled. A signal during this wait is reported
// and ignored once; a second one ends the process the default way, which is
// the operator's explicit choice to abandon the requests. The report went out
// with synchronous writes, so the exit cannot truncate it.
const warnAbandon = (signal) => console.error(`${signal} during the final wait: ${providerInFlight.size} provider request(s) still in flight; a second ${signal} abandons them`);
process.once("SIGINT", () => warnAbandon("SIGINT"));
process.once("SIGTERM", () => warnAbandon("SIGTERM"));
await waitProviderSettled();
process.exit(process.exitCode ?? 0);
