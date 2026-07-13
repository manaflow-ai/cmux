#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import WebSocket from "ws";
import {
  loadTargetEnv,
  optionValue,
  parseWebDirAndTarget,
  requireEnvKeys,
} from "./projects.mjs";

const usage = "Usage: stress-vm-api.mjs [web-dir] <staging|production> [--count N] [--concurrency N] [--provider e2b|freestyle|daytona|default] [--url https://preview.example]";
const { webDir, target, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const count = positiveInteger(optionValue(rest, "--count") ?? "8", "--count");
const concurrency = Math.min(positiveInteger(optionValue(rest, "--concurrency") ?? "4", "--concurrency"), count);
const provider = optionValue(rest, "--provider") ?? "default";
const targetUrl = optionValue(rest, "--url") ?? project.url;
if (!["default", "e2b", "freestyle", "daytona"].includes(provider)) {
  console.error("--provider must be default, e2b, freestyle, or daytona");
  process.exit(2);
}

const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const stackModule = await import(pathToFileURL(requireFromWeb.resolve("@stackframe/js")).href);
const { StackServerApp } = stackModule;

const env = loadTargetEnv(project);
requireEnvKeys(env, [
  "NEXT_PUBLIC_STACK_PROJECT_ID",
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  "STACK_SECRET_SERVER_KEY",
], `${project.projectName} stress`);

const stack = new StackServerApp({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
  secretServerKey: env.STACK_SECRET_SERVER_KEY,
});

const startedAt = Date.now();
const results = [];
const inFlightCleanups = new Set();
let nextIndex = 0;
let interruptedSignal = "";

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    if (interruptedSignal) return;
    interruptedSignal = signal;
    console.error(`received ${signal}; waiting for ${inFlightCleanups.size} in-flight case(s) to clean up`);
  });
}

await Promise.all(Array.from({ length: concurrency }, async () => {
  while (true) {
    if (interruptedSignal) return;
    const index = nextIndex;
    nextIndex += 1;
    if (index >= count) return;
    results[index] = await runCase(index);
  }
}));
if (interruptedSignal) await drainInFlight(interruptedSignal);

const attempted = results.filter(Boolean);
const successes = attempted.filter((result) => result.ok);
const failures = attempted.filter((result) => !result.ok);
const providerCounts = countBy(successes.map((result) => result.provider ?? "unknown"));
const imageVersionCounts = countBy(successes.map((result) => result.imageVersion ?? "unknown"));
const cleanupSummary = {
  vmDeleted: results.filter((result) => result.cleanup?.vmDeleted).length,
  userDeleted: results.filter((result) => result.cleanup?.userDeleted).length,
  vmDeleteErrors: results.filter((result) => result.cleanup?.vmDeleteError).length,
  userDeleteErrors: results.filter((result) => result.cleanup?.userDeleteError).length,
};
console.log(JSON.stringify({
  ok: !interruptedSignal && failures.length === 0,
  target,
  project: project.projectName,
  url: targetUrl,
  provider,
  count,
  concurrency,
  attempted: attempted.length,
  interruptedSignal: interruptedSignal || undefined,
  durationMs: Date.now() - startedAt,
  createDurationMs: summarizeDurations(successes.map((result) => result.createDurationMs)),
  attachDurationMs: summarizeDurations(successes.map((result) => result.attachDurationMs)),
  rpcDurationMs: summarizeDurations(successes.map((result) => result.rpcDurationMs)),
  successes: successes.length,
  providerCounts,
  imageVersionCounts,
  cleanup: cleanupSummary,
  failures,
}, null, 2));
if (interruptedSignal) process.exit(130);
if (failures.length > 0) process.exit(1);

async function runCase(index) {
  const suffix = `${Date.now()}-${index}-${randomBytes(3).toString("hex")}`;
  let user;
  let vmId;
  let authHeaders;
  let createDurationMs;
  let attachDurationMs;
  let rpcDurationMs;
  const cleanup = { vmDeleted: false, userDeleted: false };
  let cleanupPromise;
  const cleanupCase = () => {
    cleanupPromise ??= cleanupRun({ getVmId: () => vmId, getAuthHeaders: () => authHeaders, getUser: () => user, cleanup });
    return cleanupPromise;
  };
  inFlightCleanups.add(cleanupCase);
  const started = Date.now();
  try {
    user = await stack.createUser({
      primaryEmail: `cmux-${project.stackLabel}-stress+${suffix}@manaflow.dev`,
      primaryEmailVerified: true,
      primaryEmailAuthEnabled: true,
      password: randomBytes(24).toString("base64url"),
      displayName: `cmux ${project.stackLabel} stress ${index}`,
    });
    throwIfInterrupted();
    const session = await user.createSession({ expiresInMillis: 20 * 60 * 1000, isImpersonation: true });
    throwIfInterrupted();
    const tokens = await session.getTokens();
    throwIfInterrupted();
    if (!tokens.accessToken || !tokens.refreshToken) {
      throw new Error("Stack did not return stress session tokens");
    }
    authHeaders = {
      authorization: `Bearer ${tokens.accessToken}`,
      "x-stack-refresh-token": tokens.refreshToken,
    };

    const createBody = provider === "default" ? {} : { provider };
    const createStartedAt = performance.now();
    const create = await fetchWithTimeout(`${targetUrl}/api/vm`, {
      method: "POST",
      headers: {
        ...authHeaders,
        "content-type": "application/json",
        "idempotency-key": `stress-${suffix}`,
      },
      body: JSON.stringify(createBody),
    }, 90_000);
    createDurationMs = Math.round(performance.now() - createStartedAt);
    const createText = await create.text();
    if (create.status !== 200) throw new Error(`POST /api/vm expected 200, got ${create.status}: ${createText}`);
    const created = JSON.parse(createText);
    if (!created.id) throw new Error("create response missing id");
    vmId = created.id;
    throwIfInterrupted();

    const attachStartedAt = performance.now();
    const attach = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}/attach-endpoint`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ requireDaemon: true }),
    }, 45_000);
    attachDurationMs = Math.round(performance.now() - attachStartedAt);
    const attachText = await attach.text();
    if (attach.status !== 200) throw new Error(`POST attach-endpoint expected 200, got ${attach.status}: ${attachText}`);
    const attached = JSON.parse(attachText);
    if (attached.transport !== "websocket") throw new Error(`expected websocket attach, got ${attached.transport}`);
    if (!attached.daemon?.url || !attached.daemon?.token || !attached.daemon?.sessionId) {
      throw new Error("attach response missing daemon RPC endpoint");
    }
    throwIfInterrupted();

    const rpcStartedAt = performance.now();
    const rpc = await rpcProxyHealthz(attached.daemon.url, attached.daemon.token, attached.daemon.sessionId);
    rpcDurationMs = Math.round(performance.now() - rpcStartedAt);
    throwIfInterrupted();
    return {
      ok: true,
      index,
      provider: created.provider,
      imageVersion: created.imageVersion,
      attachTransport: attached.transport,
      rpcCapabilities: rpc.capabilities,
      createDurationMs,
      attachDurationMs,
      rpcDurationMs,
      durationMs: Date.now() - started,
      cleanup,
    };
  } catch (error) {
    return {
      ok: false,
      index,
      message: error instanceof Error ? error.message : String(error),
      vmIdSet: !!vmId,
      createDurationMs,
      attachDurationMs,
      rpcDurationMs,
      durationMs: Date.now() - started,
      cleanup,
    };
  } finally {
    await cleanupCase();
    inFlightCleanups.delete(cleanupCase);
  }
}

async function cleanupRun({ getVmId, getAuthHeaders, getUser, cleanup }) {
  const vmId = getVmId();
  const authHeaders = getAuthHeaders();
  const user = getUser();

  if (vmId && authHeaders) {
    try {
      const destroy = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}`, {
        method: "DELETE",
        headers: authHeaders,
      }, 45_000);
      cleanup.vmDeleted = destroy.status === 200;
      if (!cleanup.vmDeleted) {
        const body = await destroy.text().catch(() => "");
        const detail = [destroy.status, destroy.statusText, body.slice(0, 200)].filter(Boolean).join(" ");
        cleanup.vmDeleteError = `DELETE /api/vm/${vmId} expected 200, got ${detail}`;
      }
    } catch (error) {
      cleanup.vmDeleteError = error instanceof Error ? error.message : String(error);
    }
  }

  if (user && (!vmId || cleanup.vmDeleted)) {
    try {
      await user.delete();
      cleanup.userDeleted = true;
    } catch (error) {
      cleanup.userDeleteError = error instanceof Error ? error.message : String(error);
    }
  } else if (user) {
    cleanup.userDeleteError ??= "skipped user deletion because VM cleanup did not succeed";
  }
}

async function drainInFlight(signal) {
  const cleanups = Array.from(inFlightCleanups);
  if (cleanups.length === 0) return;
  console.error(`received ${signal}; running ${cleanups.length} registered cleanup(s) before exit`);
  const settled = await Promise.allSettled(cleanups.map((cleanupCase) => cleanupCase()));
  const rejected = settled.filter((result) => result.status === "rejected");
  if (rejected.length > 0) {
    console.error(`${rejected.length} cleanup callback(s) failed during ${signal} shutdown`);
  }
}

function throwIfInterrupted() {
  if (interruptedSignal) throw new Error(`interrupted by ${interruptedSignal}`);
}

async function fetchWithTimeout(url, init, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function rpcProxyHealthz(url, token, sessionId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const chunks = [];
    let streamId = "";
    let capabilities = [];
    let settled = false;
    let timer;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    };
    const succeed = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    timer = setTimeout(() => {
      ws.terminate();
      fail(new Error("rpc proxy timeout"));
    }, 30_000);
    ws.on("error", (error) => {
      fail(error);
    });
    ws.on("close", () => {
      fail(new Error("rpc proxy connection closed unexpectedly"));
    });
    ws.on("open", () => {
      ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId }));
    });
    ws.on("message", (data, isBinary) => {
      try {
        if (isBinary) return;
        const msg = JSON.parse(data.toString());
        if (msg.error || msg.type === "error") {
          throw new Error(`rpc error message: ${describeRpcMessage(msg, streamId, chunks)}`);
        }
        if (msg.type === "ready") {
          ws.send(JSON.stringify({ id: 1, method: "hello", params: {} }));
          return;
        }
        if (msg.id === 1) {
          if (msg.ok !== true) throw new Error(`hello failed: ${JSON.stringify(msg)}`);
          capabilities = msg.result?.capabilities ?? [];
          ws.send(JSON.stringify({ id: 2, method: "proxy.open", params: { host: "127.0.0.1", port: 7777 } }));
          return;
        }
        if (msg.id === 2) {
          if (msg.ok !== true) throw new Error(`proxy.open failed: ${JSON.stringify(msg)}`);
          streamId = msg.result?.stream_id;
          if (!streamId) throw new Error(`proxy.open missing stream_id: ${JSON.stringify(msg)}`);
          ws.send(JSON.stringify({ id: 3, method: "proxy.stream.subscribe", params: { stream_id: streamId } }));
          return;
        }
        if (msg.id === 3) {
          if (msg.ok !== true) throw new Error(`proxy.stream.subscribe failed: ${JSON.stringify(msg)}`);
          const request = Buffer
            .from("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            .toString("base64");
          ws.send(JSON.stringify({
            id: 4,
            method: "proxy.write",
            params: { stream_id: streamId, data_base64: request },
          }));
          return;
        }
        if (msg.id === 4) {
          if (msg.ok !== true) throw new Error(`proxy.write failed: ${JSON.stringify(msg)}`);
          return;
        }
        if (msg.event === "proxy.stream.data" && msg.data_base64) {
          chunks.push(Buffer.from(msg.data_base64, "base64"));
          return;
        }
        if (msg.event === "proxy.stream.eof") {
          const response = Buffer.concat(chunks).toString();
          if (!response.includes("HTTP/1.1 200 OK") || !response.includes('"ok":true')) {
            fail(new Error(`unexpected proxied healthz response: ${response.slice(0, 200)}`));
          } else {
            succeed({ capabilities });
          }
          ws.close();
          return;
        }
        if (msg.event === "proxy.stream.error") throw new Error(`proxy.stream.error: ${JSON.stringify(msg)}`);
        throw new Error(`unexpected rpc message: ${describeRpcMessage(msg, streamId, chunks)}`);
      } catch (error) {
        ws.terminate();
        fail(error);
      }
    });
  });
}

function describeRpcMessage(msg, streamId, chunks) {
  const body = JSON.stringify(msg).slice(0, 500);
  const chunkBytes = chunks.reduce((total, chunk) => total + chunk.length, 0);
  return `${body} (streamId=${streamId || "unset"}, chunks=${chunks.length}, bytes=${chunkBytes})`;
}

function positiveInteger(raw, label) {
  const value = String(raw).trim();
  if (!/^\d+$/.test(value)) throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${label} must be a positive integer`);
  return parsed;
}

function countBy(values) {
  return values.reduce((acc, value) => {
    acc[value] = (acc[value] ?? 0) + 1;
    return acc;
  }, {});
}

function summarizeDurations(values) {
  const numbers = values
    .filter((value) => Number.isFinite(value))
    .sort((a, b) => a - b);
  if (numbers.length === 0) return null;
  const total = numbers.reduce((sum, value) => sum + value, 0);
  return {
    min: numbers[0],
    p50: percentile(numbers, 0.5),
    p95: percentile(numbers, 0.95),
    max: numbers[numbers.length - 1],
    avg: Math.round(total / numbers.length),
  };
}

function percentile(sortedNumbers, fraction) {
  if (sortedNumbers.length === 1) return sortedNumbers[0];
  const index = Math.max(0, Math.min(
    sortedNumbers.length - 1,
    Math.ceil(sortedNumbers.length * fraction) - 1,
  ));
  return sortedNumbers[index];
}
