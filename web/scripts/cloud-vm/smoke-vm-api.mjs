#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  loadTargetEnv,
  optionValue,
  parseWebDirAndTarget,
  requireEnvKeys,
} from "./projects.mjs";

const usage = "Usage: smoke-vm-api.mjs [web-dir] <staging|production> [--create] [--provider e2b|freestyle]";
const args = process.argv.slice(2);
const { webDir, target, project, rest } = parseWebDirAndTarget(args, usage);
const shouldCreate = rest.includes("--create");
const provider = optionValue(rest, "--provider") ?? "e2b";
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
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
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

  const unauth = await fetchWithTimeout(`${project.url}/api/vm`);
  if (unauth.status !== 401) throw new Error(`unauthenticated GET /api/vm expected 401, got ${unauth.status}`);

  const authed = await fetchWithTimeout(`${project.url}/api/vm`, { headers: authHeaders });
  const authedText = await authed.text();
  if (authed.status !== 200) throw new Error(`authenticated GET /api/vm expected 200, got ${authed.status}: ${authedText}`);
  const authedJson = JSON.parse(authedText);

  const result = {
    ok: true,
    target,
    projectId,
    unauthStatus: unauth.status,
    authedListStatus: authed.status,
    beforeCount: Array.isArray(authedJson.vms) ? authedJson.vms.length : null,
  };

  if (shouldCreate) {
    const create = await fetchWithTimeout(`${project.url}/api/vm`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": `smoke-${suffix}` },
      body: JSON.stringify({ provider }),
    });
    const createText = await create.text();
    if (create.status !== 200) throw new Error(`POST /api/vm expected 200, got ${create.status}: ${createText}`);
    const created = JSON.parse(createText);
    if (!created.id) throw new Error("create response missing id");
    if (created.provider !== provider) {
      throw new Error(`POST /api/vm returned provider ${created.provider}, expected ${provider}`);
    }
    vmId = created.id;

    const attach = await fetchWithTimeout(`${project.url}/api/vm/${encodeURIComponent(vmId)}/attach-endpoint`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: JSON.stringify({ requireDaemon: true }),
    });
    const attachText = await attach.text();
    if (attach.status !== 200) throw new Error(`POST attach-endpoint expected 200, got ${attach.status}: ${attachText}`);
    const attached = JSON.parse(attachText);
    if (attached.transport !== "websocket") throw new Error(`expected websocket attach, got ${attached.transport}`);

    const destroy = await fetchWithTimeout(`${project.url}/api/vm/${encodeURIComponent(vmId)}`, {
      method: "DELETE",
      headers: authHeaders,
    });
    const destroyText = await destroy.text();
    if (destroy.status !== 200) throw new Error(`DELETE /api/vm/${vmId} expected 200, got ${destroy.status}: ${destroyText}`);
    vmId = undefined;

    Object.assign(result, {
      createdProvider: created.provider,
      imageVersion: created.imageVersion,
      attachTransport: attached.transport,
      destroyed: true,
    });
  }

  console.log(JSON.stringify(result));
} catch (error) {
  if (vmId && authHeaders) {
    try {
      const destroy = await fetchWithTimeout(`${project.url}/api/vm/${encodeURIComponent(vmId)}`, {
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
