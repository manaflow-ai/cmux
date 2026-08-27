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

const usage = "Usage: smoke-vm-api.mjs [web-dir] <staging|production> [--create] [--provider e2b|freestyle|daytona] [--url https://preview.example] [--vercel-curl] [--skip-attach]";
const args = process.argv.slice(2);
const { webDir, target, project, rest } = parseWebDirAndTarget(args, usage);
const shouldCreate = rest.includes("--create");
const useVercelCurl = rest.includes("--vercel-curl");
const skipAttach = rest.includes("--skip-attach");
const provider = optionValue(rest, "--provider") ?? "e2b";
const targetUrl = optionValue(rest, "--url") ?? project.url;
const REQUEST_TIMEOUT_MS = 45_000;
// The provider contracts allow 15 minutes for create and 5 minutes for delete.
// Keep the smoke client alive for the full provider operation plus route overhead.
const CREATE_REQUEST_TIMEOUT_MS = 16 * 60 * 1000;
const DELETE_REQUEST_TIMEOUT_MS = 6 * 60 * 1000;
const CLEANUP_DELETE_ATTEMPTS = 2;

if (shouldCreate && provider !== "e2b" && provider !== "freestyle" && provider !== "daytona") {
  console.error("--provider must be e2b, freestyle, or daytona");
  process.exit(2);
}

const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const stackModule = await import(pathToFileURL(requireFromWeb.resolve("@stackframe/js")).href);
const { StackServerApp } = stackModule;

let user;
let vmId;
let authHeaders;
let result;
let beforeCount = 0;
let operationError;
let vmCleanupError;
let userCleanupError;
let vmCleanupRequired = false;

class SmokeCleanupError extends Error {
  constructor(kind, message, options) {
    super(message, options);
    this.name = "SmokeCleanupError";
    this.kind = kind;
  }
}

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

async function destroyAndVerifyVm(cleanupVmId) {
  const destroyStartedAt = performance.now();
  let lastDeleteError;
  let deleted = false;
  for (let attempt = 1; attempt <= CLEANUP_DELETE_ATTEMPTS; attempt += 1) {
    try {
      const destroy = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(cleanupVmId)}`, {
        method: "DELETE",
        headers: authHeaders,
      }, DELETE_REQUEST_TIMEOUT_MS);
      const destroyText = await destroy.text();
      if (destroy.status === 200) {
        deleted = true;
        break;
      }
      if (destroy.status === 404 && attempt > 1) {
        // A prior delete may have completed even if its response was lost. The
        // authenticated list check below confirms that the VM is absent.
        deleted = true;
        break;
      }
      lastDeleteError = new SmokeCleanupError(
        "delete",
        `DELETE /api/vm/${cleanupVmId} expected 200, got ${destroy.status}: ${destroyText} (attempt ${attempt}/${CLEANUP_DELETE_ATTEMPTS})`,
      );
    } catch (error) {
      lastDeleteError = new SmokeCleanupError(
        "delete",
        `DELETE /api/vm/${cleanupVmId} failed (attempt ${attempt}/${CLEANUP_DELETE_ATTEMPTS}): ${error instanceof Error ? error.message : String(error)}`,
        { cause: error },
      );
    }
  }
  if (!deleted) throw lastDeleteError ?? new SmokeCleanupError("delete", `DELETE /api/vm/${cleanupVmId} failed`);
  const destroyDurationMs = Math.round(performance.now() - destroyStartedAt);

  let verify;
  try {
    verify = await fetchWithTimeout(`${targetUrl}/api/vm`, { headers: authHeaders });
  } catch (error) {
    throw new SmokeCleanupError(
      "verify",
      `post-delete GET /api/vm failed: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    );
  }
  const verifyText = await verify.text();
  if (verify.status !== 200) {
    throw new SmokeCleanupError(
      "verify",
      `post-delete GET /api/vm expected 200, got ${verify.status}: ${verifyText}`,
    );
  }

  let afterJson;
  try {
    afterJson = JSON.parse(verifyText);
  } catch (error) {
    throw new SmokeCleanupError("verify", "post-delete GET /api/vm returned invalid JSON", { cause: error });
  }
  if (!Array.isArray(afterJson.vms)) {
    throw new SmokeCleanupError("verify", "post-delete GET /api/vm response missing vms array");
  }
  if (afterJson.vms.some((vm) => vm?.id === cleanupVmId)) {
    throw new SmokeCleanupError("leak", `post-delete GET /api/vm still includes ${cleanupVmId}`);
  }
  if (afterJson.vms.length !== beforeCount) {
    throw new SmokeCleanupError(
      "leak",
      `post-delete GET /api/vm returned ${afterJson.vms.length} VMs, expected ${beforeCount}`,
    );
  }

  return {
    destroyed: true,
    destroyDurationMs,
    leakVerified: true,
    afterCount: afterJson.vms.length,
  };
}

function cleanupFailurePrefix(error) {
  if (!(error instanceof SmokeCleanupError)) return "cleanup_verify_failed_vm";
  if (error.kind === "delete") return "cleanup_delete_failed_vm";
  if (error.kind === "leak") return "cleanup_leaked_vm";
  return "cleanup_verify_failed_vm";
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
  if (!Array.isArray(authedJson.vms)) throw new Error("authenticated GET /api/vm response missing vms array");
  beforeCount = authedJson.vms.length;

  result = {
    ok: true,
    target,
    projectId,
    url: targetUrl,
    unauthStatus: unauth.status,
    authedListStatus: authed.status,
    beforeCount,
  };

  if (shouldCreate) {
    // A timed-out request can still complete in the provider. Keep the Stack
    // owner until this create is followed by confirmed delete and leak checks.
    vmCleanupRequired = true;
    const createStartedAt = performance.now();
    const create = await fetchWithTimeout(`${targetUrl}/api/vm`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": `smoke-${suffix}` },
      body: JSON.stringify({ provider }),
    }, CREATE_REQUEST_TIMEOUT_MS);
    const createDurationMs = Math.round(performance.now() - createStartedAt);
    const createText = await create.text();
    if (create.status !== 200) throw new Error(`POST /api/vm expected 200, got ${create.status}: ${createText}`);
    const created = JSON.parse(createText);
    if (!created.id) throw new Error("create response missing id");
    vmId = created.id;
    if (created.provider !== provider) {
      throw new Error(`POST /api/vm returned provider ${created.provider}, expected ${provider}`);
    }

    let attachTransport;
    let attachDurationMs;
    if (!skipAttach) {
      // Blaxel machines run only the cmux-tui remote daemon; every other provider still
      // serves the legacy cmuxd-remote websocket PTY.
      const expectedTransport = created.provider === "blaxel" ? "cmux-remote" : "websocket";
      const attachBody = expectedTransport === "cmux-remote"
        ? { transport: "cmux-remote" }
        : { requireDaemon: true };
      const attachStartedAt = performance.now();
      const attach = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}/attach-endpoint`, {
        method: "POST",
        headers: { ...authHeaders, "content-type": "application/json" },
        body: JSON.stringify(attachBody),
      });
      attachDurationMs = Math.round(performance.now() - attachStartedAt);
      const attachText = await attach.text();
      if (attach.status !== 200) throw new Error(`POST attach-endpoint expected 200, got ${attach.status}: ${attachText}`);
      const attached = JSON.parse(attachText);
      if (attached.transport !== expectedTransport) {
        throw new Error(`expected ${expectedTransport} attach, got ${attached.transport}`);
      }
      if (expectedTransport === "cmux-remote" && !/^wss:\/\/.+\/v1\/link\?/.test(attached.route ?? "")) {
        throw new Error("cmux-remote attach response missing the daemon route");
      }
      attachTransport = attached.transport;
    }

    Object.assign(result, {
      createdProvider: created.provider,
      imageVersion: created.imageVersion,
      createDurationMs,
      ...(skipAttach
        ? { attachSkipped: true }
        : { attachTransport, attachDurationMs }),
    });
  }
} catch (error) {
  operationError = error;
} finally {
  if (vmId && authHeaders) {
    const cleanupVmId = vmId;
    try {
      const cleanupResult = await destroyAndVerifyVm(cleanupVmId);
      Object.assign(result, cleanupResult);
      vmId = undefined;
      vmCleanupRequired = false;
      if (operationError) console.error(`cleanup_destroyed_vm=${cleanupVmId}`);
    } catch (error) {
      vmCleanupError = error;
      console.error(
        `${cleanupFailurePrefix(error)}=${cleanupVmId} error=${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
  if (user && vmCleanupRequired) {
    console.error("cleanup_preserved_user reason=vm_cleanup_unconfirmed");
  } else if (user) {
    try {
      await user.delete();
    } catch (error) {
      userCleanupError = error;
      console.error(
        `cleanup_delete_user_failed error=${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
}

if (vmId) console.error(`cleanup_needed_vm=${vmId}`);
if (operationError) console.error(operationError instanceof Error ? operationError.message : String(operationError));
if (operationError || vmCleanupError || userCleanupError) {
  process.exitCode = 1;
} else {
  console.log(JSON.stringify(result));
}
