#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  loadTargetEnv,
  optionValue,
  parseWebDirAndTarget,
  requireEnvKeys,
} from "./projects.mjs";

const usage = "Usage: smoke-vm-api.mjs [web-dir] <staging|production> [--create] [--provider e2b|freestyle] [--url https://preview.example] [--vercel-curl] [--skip-attach]";
const args = process.argv.slice(2);
const { webDir, target, project, rest } = parseWebDirAndTarget(args, usage);
const shouldCreate = rest.includes("--create");
const useVercelCurl = rest.includes("--vercel-curl");
const skipAttach = rest.includes("--skip-attach");
const provider = optionValue(rest, "--provider") ?? "e2b";
const targetUrl = optionValue(rest, "--url") ?? project.url;
const REQUEST_TIMEOUT_MS = 45_000;

if (shouldCreate && provider !== "e2b" && provider !== "freestyle") {
  console.error("--provider must be e2b or freestyle");
  process.exit(2);
}

const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const stackModule = await import(pathToFileURL(requireFromWeb.resolve("@stackframe/js")).href);
const { StackServerApp } = stackModule;

let user;
let vmId;
let authHeaders;

async function fetchWithTimeout(url, init = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
  if (useVercelCurl) return vercelCurlFetch(url, init, timeoutMs);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function vercelCurlFetch(url, init = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
  const parsed = new URL(url);
  const scratch = mkdtempSync(path.join(tmpdir(), "cmux-vercel-curl-"));
  const responsePath = path.join(scratch, "response.txt");
  const bodyPath = path.join(scratch, "body.txt");
  const configPath = path.join(scratch, "curl.conf");
  try {
    const headers = init.headers ?? {};
    const lines = [
      "silent",
      "show-error",
      "location",
      `output = ${JSON.stringify(responsePath)}`,
      'write-out = "%{http_code}"',
    ];
    const method = init.method?.toUpperCase();
    if (method) lines.push(`request = ${JSON.stringify(method)}`);
    for (const [name, value] of Object.entries(headers)) {
      lines.push(`header = ${JSON.stringify(`${name}: ${value}`)}`);
    }
    if (init.body !== undefined) {
      writeFileSync(bodyPath, init.body);
      lines.push(`data-binary = ${JSON.stringify(`@${bodyPath}`)}`);
    }
    writeFileSync(configPath, `${lines.join("\n")}\n`, { mode: 0o600 });

    const statusOutput = execFileSync("vercel", [
      "curl",
      `${parsed.pathname}${parsed.search}`,
      "--deployment",
      parsed.origin,
      "--scope",
      "manaflow",
      "--",
      "--config",
      configPath,
    ], {
      encoding: "utf8",
      timeout: timeoutMs + 10_000,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    const statusMatch = statusOutput.match(/(\d{3})$/);
    if (!statusMatch) throw new Error(`vercel curl did not return an HTTP status: ${statusOutput}`);
    const status = Number(statusMatch[1]);
    const responseText = readFileSync(responsePath, "utf8");
    return {
      status,
      text: async () => responseText,
    };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

try {
  const env = loadTargetEnv(project);
  requireEnvKeys(env, [
    "NEXT_PUBLIC_STACK_PROJECT_ID",
    "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
    "STACK_SECRET_SERVER_KEY",
  ], `${project.projectName} smoke`);
  const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
  const publishableClientKey = env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
  const secretServerKey = env.STACK_SECRET_SERVER_KEY;

  const app = new StackServerApp({ projectId, publishableClientKey, secretServerKey });
  const suffix = `${Date.now()}-${randomBytes(3).toString("hex")}`;
  user = await app.createUser({
    primaryEmail: `cmux-${project.stackLabel}-smoke+${suffix}@manaflow.dev`,
    primaryEmailVerified: true,
    primaryEmailAuthEnabled: true,
    password: randomBytes(24).toString("base64url"),
    displayName: `cmux ${project.stackLabel} smoke`,
  });

  const session = await user.createSession({ expiresInMillis: 20 * 60 * 1000, isImpersonation: true });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) throw new Error("Stack did not return smoke session tokens");
  authHeaders = {
    authorization: `Bearer ${tokens.accessToken}`,
    "x-stack-refresh-token": tokens.refreshToken,
  };

  const unauth = await fetchWithTimeout(`${targetUrl}/api/vm`);
  if (unauth.status !== 401) throw new Error(`unauthenticated GET /api/vm expected 401, got ${unauth.status}`);

  const authed = await fetchWithTimeout(`${targetUrl}/api/vm`, { headers: authHeaders });
  const authedText = await authed.text();
  if (authed.status !== 200) throw new Error(`authenticated GET /api/vm expected 200, got ${authed.status}: ${authedText}`);
  const authedJson = JSON.parse(authedText);

  const result = {
    ok: true,
    target,
    projectId,
    url: targetUrl,
    unauthStatus: unauth.status,
    authedListStatus: authed.status,
    beforeCount: Array.isArray(authedJson.vms) ? authedJson.vms.length : null,
  };

  if (shouldCreate) {
    const createStartedAt = performance.now();
    const create = await fetchWithTimeout(`${targetUrl}/api/vm`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": `smoke-${suffix}` },
      body: JSON.stringify({ provider }),
    });
    const createDurationMs = Math.round(performance.now() - createStartedAt);
    const createText = await create.text();
    if (create.status !== 200) throw new Error(`POST /api/vm expected 200, got ${create.status}: ${createText}`);
    const created = JSON.parse(createText);
    if (!created.id) throw new Error("create response missing id");
    if (created.provider !== provider) {
      throw new Error(`POST /api/vm returned provider ${created.provider}, expected ${provider}`);
    }
    vmId = created.id;

    let attachTransport;
    let attachDurationMs;
    if (!skipAttach) {
      const attachStartedAt = performance.now();
      const attach = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}/attach-endpoint`, {
        method: "POST",
        headers: { ...authHeaders, "content-type": "application/json" },
        body: JSON.stringify({ requireDaemon: true }),
      });
      attachDurationMs = Math.round(performance.now() - attachStartedAt);
      const attachText = await attach.text();
      if (attach.status !== 200) throw new Error(`POST attach-endpoint expected 200, got ${attach.status}: ${attachText}`);
      const attached = JSON.parse(attachText);
      if (attached.transport !== "websocket") throw new Error(`expected websocket attach, got ${attached.transport}`);
      attachTransport = attached.transport;
    }

    const destroyStartedAt = performance.now();
    const destroy = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}`, {
      method: "DELETE",
      headers: authHeaders,
    });
    const destroyDurationMs = Math.round(performance.now() - destroyStartedAt);
    const destroyText = await destroy.text();
    if (destroy.status !== 200) throw new Error(`DELETE /api/vm/${vmId} expected 200, got ${destroy.status}: ${destroyText}`);
    vmId = undefined;

    Object.assign(result, {
      createdProvider: created.provider,
      imageVersion: created.imageVersion,
      createDurationMs,
      ...(skipAttach
        ? { attachSkipped: true }
        : { attachTransport, attachDurationMs }),
      destroyed: true,
      destroyDurationMs,
    });
  }

  console.log(JSON.stringify(result));
} catch (error) {
  if (vmId && authHeaders) {
    try {
      const destroy = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}`, {
        method: "DELETE",
        headers: authHeaders,
      });
      if (destroy.status === 200) {
        console.error(`cleanup_destroyed_vm=${vmId}`);
        vmId = undefined;
      } else {
        const text = await destroy.text().catch(() => "");
        console.error(`cleanup_delete_failed_vm=${vmId} status=${destroy.status} body=${text}`);
      }
    } catch (cleanupError) {
      console.error(`cleanup_delete_failed_vm=${vmId} error=${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`);
    }
  }
  if (vmId) console.error(`cleanup_needed_vm=${vmId}`);
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  if (user) {
    try {
      await user.delete();
    } catch (cleanupError) {
      console.error(
        `cleanup_delete_user_failed error=${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`,
      );
      process.exitCode = 1;
    }
  }
}
