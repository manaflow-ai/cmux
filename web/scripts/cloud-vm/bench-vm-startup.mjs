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
import { elapsedMs, formatSummary, parseServerTiming, summarizeFields, summarizeStages } from "./benchStats.mjs";
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
const ATTACH_BUDGET_MS = 180_000;

const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const { StackServerApp } = await import(pathToFileURL(requireFromWeb.resolve("@stackframe/js")).href);

const env = loadTargetEnv(project);
requireEnvKeys(env, ["NEXT_PUBLIC_STACK_PROJECT_ID", "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY", "STACK_SECRET_SERVER_KEY"], `${project.projectName} bench`);
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
const interrupt = () => { interrupted = true; };
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);

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
    const response = await fetchTimed(vmUrl(vmId, "/attach-endpoint"), {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ transport: "cmux-remote", clientCapabilities: ["wireguard-hub", "direct-ws-user-agent"] }),
    });
    const body = json(response.text);
    attempts.push({ status: response.status, ms: response.ms, error: body.error ?? null });
    if (response.status === 200) {
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
    await new Promise((resolve) => setTimeout(resolve, Math.min(remainingMs, Math.max(1, Number(body.retryAfterSeconds) || 2) * 1000)));
  }
}

/** Time from the first probe until the edge alias answers with an HTTP status (any status proves injection). */
async function edgeReady(vmId) {
  const startedAt = performance.now();
  const probes = [];
  for (;;) {
    const exec = await fetchTimed(vmUrl(vmId, "/exec"), {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ command: EDGE_PROBE, timeoutMs: 10_000 }),
    });
    const code = (json(exec.text).stdout ?? "").trim();
    probes.push({ status: exec.status, ms: exec.ms, code });
    if (exec.status === 200 && /^[1-5]\d\d$/.test(code)) {
      return { edgeReadyMs: elapsedMs(startedAt), edgeProbes: probes, edgeHttpCode: code };
    }
    if (performance.now() - startedAt >= EDGE_BUDGET_MS || interrupted) {
      throw new Error(`edge alias did not answer within ${EDGE_BUDGET_MS} ms (last exec ${exec.status}, code ${code || "none"})`);
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

async function runTrial(index) {
  const trial = { index, startedAt: new Date().toISOString() };
  const create = await fetchTimed(`${targetUrl}/api/vm`, {
    method: "POST",
    headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": `bench-${suffix}-${index}` },
    body: "{}",
  });
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

async function destroyLeftovers() {
  for (const vmId of [...liveVmIds]) {
    try {
      const destroy = await fetchTimed(vmUrl(vmId), { method: "DELETE", headers: authHeaders });
      if (destroy.status === 200) liveVmIds.delete(vmId);
      else console.error(`cleanup_delete_failed_vm=${vmId} status=${destroy.status}`);
    } catch (error) {
      console.error(`cleanup_delete_failed_vm=${vmId} error=${error instanceof Error ? error.message : String(error)}`);
    }
  }
}

function positiveInteger(raw, flag) {
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) {
    console.error(`${flag} must be a positive integer`);
    process.exit(2);
  }
  return value;
}

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
  const session = await user.createSession({ expiresInMillis: 60 * 60 * 1000, isImpersonation: true });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) throw new Error("Stack did not return bench session tokens");
  authHeaders = { authorization: `Bearer ${tokens.accessToken}`, "x-stack-refresh-token": tokens.refreshToken };

  const list = await fetchTimed(`${targetUrl}/api/vm`, { headers: authHeaders });
  if (list.status !== 200) throw new Error(`authenticated GET /api/vm expected 200, got ${list.status}: ${list.text.slice(0, 200)}`);

  const startedAt = performance.now();
  const results = await runBatches();
  const ok = results.filter((trial) => trial && trial.ok !== false);
  const summary = {
    ok: !interrupted && ok.length === results.length && results.length === trials,
    interrupted,
    target,
    url: targetUrl,
    label,
    trials,
    concurrency,
    listMs: list.ms,
    totalMs: elapsedMs(startedAt),
    succeeded: ok.length,
    failed: results.length - ok.length,
    stages: summarizeFields(ok, ["createMs", "attachMs", "createToUsableMs", "warmAttachMs", "execMs", "edgeReadyMs", "pauseMs", "resumeAttachMs", "destroyMs"]),
    attachAttempts: summarizeFields(ok.map((trial) => ({ attempts: trial.attachAttempts?.length })), ["attempts"]).attempts,
    createServerTiming: summarizeStages(ok.map((trial) => trial.createStages)),
    trials: results,
  };
  console.error(formatSummary({ ...summary.stages, ...Object.fromEntries(Object.entries(summary.createServerTiming).map(([name, value]) => [`server:${name}`, value])) }));
  const text = JSON.stringify(summary);
  if (outPath) writeFileSync(outPath, `${text}\n`);
  console.log(text);
  if (!summary.ok) process.exitCode = 1;
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  await destroyLeftovers();
  for (const vmId of liveVmIds) console.error(`cleanup_needed_vm=${vmId}`);
  if (liveVmIds.size > 0) process.exitCode = 1;
  if (user) {
    try {
      await user.delete();
    } catch (cleanupError) {
      console.error(`cleanup_delete_user_failed error=${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
      process.exitCode = 1;
    }
  }
  process.off("SIGINT", interrupt);
  process.off("SIGTERM", interrupt);
}
