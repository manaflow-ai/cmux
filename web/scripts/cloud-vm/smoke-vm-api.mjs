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

const usage = "Usage: smoke-vm-api.mjs [web-dir] <staging|production> [--create] [--provider freestyle|default] [--image <manifest image id or version>] [--url https://preview.example] [--vercel-curl] [--skip-attach] [--paid] [--edge-check] [--claude-check]";
const args = process.argv.slice(2);
const { webDir, target, project, rest } = parseWebDirAndTarget(args, usage);
const shouldCreate = rest.includes("--create");
const useVercelCurl = rest.includes("--vercel-curl");
const skipAttach = rest.includes("--skip-attach");
// --paid marks the throwaway smoke user as a paid plan via the billing
// metadata key the entitlements layer reads (cmuxVmPlan). Required to
// exercise provisioning now that free plans are gated (vm_requires_pro).
const paid = rest.includes("--paid");
// --edge-check proves the coderouter edge model plane from inside the guest:
// no route token on disk, the injected token reaches coderouter, and one
// codex turn completes through the edge.
const edgeCheck = rest.includes("--edge-check");
// --claude-check extends --edge-check to the Claude leg: the smoke team gets an
// Anthropic API key upstream (CMUX_SMOKE_CLAUDE_API_KEY, never logged) through
// PUT /api/coderouter/claude-upstream, then one `claude -p` turn runs in the
// guest through the edge. Proves routing, upstream rewrite, and the usage row.
const claudeCheck = rest.includes("--claude-check");
// Either an Anthropic API key (CMUX_SMOKE_CLAUDE_API_KEY) or a full
// PUT /api/coderouter/claude-upstream body (CMUX_SMOKE_CLAUDE_UPSTREAM_JSON,
// e.g. a bedrock upstream) becomes the smoke team's Claude upstream.
const claudeUpstreamApiKey = process.env.CMUX_SMOKE_CLAUDE_API_KEY?.trim() ?? "";
const claudeUpstreamJson = process.env.CMUX_SMOKE_CLAUDE_UPSTREAM_JSON?.trim() ?? "";
const claudeUpstreamBody = claudeUpstreamJson
  ? claudeUpstreamJson
  : claudeUpstreamApiKey
    ? JSON.stringify({ kind: "anthropic_api_key", apiKey: claudeUpstreamApiKey })
    : "";
if (claudeCheck && !edgeCheck) {
  console.error("--claude-check requires --edge-check");
  process.exit(2);
}
if (claudeCheck && !claudeUpstreamBody) {
  console.error("--claude-check requires CMUX_SMOKE_CLAUDE_API_KEY or CMUX_SMOKE_CLAUDE_UPSTREAM_JSON in the environment");
  process.exit(2);
}
const provider = optionValue(rest, "--provider") ?? "freestyle";
const image = optionValue(rest, "--image");
const targetUrl = optionValue(rest, "--url") ?? project.url;
const REQUEST_TIMEOUT_MS = 45_000;

// "default" omits the provider from the create body, exercising the same
// server-side default-provider path real clients (CLI, Mac app) use.
if (
  shouldCreate &&
  provider !== "freestyle" &&
  provider !== "default"
) {
  console.error("--provider must be freestyle or default");
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

  if (paid) {
    await user.update({ clientReadOnlyMetadata: { cmuxVmPlan: "pro" } });
  }
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

  if (claudeCheck) {
    const upstream = await fetchWithTimeout(`${targetUrl}/api/coderouter/claude-upstream`, {
      method: "PUT",
      headers: { ...authHeaders, "content-type": "application/json" },
      body: claudeUpstreamBody,
    });
    const upstreamText = await upstream.text();
    if (upstream.status !== 200 && upstream.status !== 201) {
      throw new Error(`PUT /api/coderouter/claude-upstream expected 200/201, got ${upstream.status}: ${upstreamText}`);
    }
    const parsedUpstream = JSON.parse(upstreamText);
    result.claudeUpstream = parsedUpstream.upstream?.identifier ?? null;
  }

  if (shouldCreate) {
    const createStartedAt = performance.now();
    const create = await fetchWithTimeout(`${targetUrl}/api/vm`, {
      method: "POST",
      headers: { ...authHeaders, "content-type": "application/json", "idempotency-key": `smoke-${suffix}` },
      body: JSON.stringify({
        ...(provider === "default" ? {} : { provider }),
        ...(image ? { image } : {}),
      }),
    });
    const createDurationMs = Math.round(performance.now() - createStartedAt);
    const createText = await create.text();
    if (create.status !== 200) throw new Error(`POST /api/vm expected 200, got ${create.status}: ${createText}`);
    const created = JSON.parse(createText);
    if (!created.id) throw new Error("create response missing id");
    if (provider !== "default" && created.provider !== provider) {
      throw new Error(`POST /api/vm returned provider ${created.provider}, expected ${provider}`);
    }
    vmId = created.id;

    let attachTransport;
    let attachDurationMs;
    if (!skipAttach) {
      // Every cmux Cloud machine runs only the cmux-tui remote daemon.
      const expectedTransport = "cmux-remote";
      const attachBody = { transport: "cmux-remote" };
      // First attach after create races the in-VM daemon boot; the API says
      // retryable with retryAfterSeconds and real clients loop. Retry 502s
      // within a bounded budget so the smoke measures the client contract,
      // not the race.
      const attachStartedAt = performance.now();
      const attachBudgetMs = 120_000;
      let attach;
      let attachText;
      for (;;) {
        attach = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}/attach-endpoint`, {
          method: "POST",
          headers: { ...authHeaders, "content-type": "application/json" },
          body: JSON.stringify(attachBody),
        });
        attachText = await attach.text();
        if (attach.status !== 502) break;
        const elapsed = performance.now() - attachStartedAt;
        if (elapsed >= attachBudgetMs) break;
        let retryAfterSeconds = 2;
        try {
          const parsed = JSON.parse(attachText);
          if (typeof parsed.retryAfterSeconds === "number") retryAfterSeconds = parsed.retryAfterSeconds;
          if (parsed.retryable !== true) break;
        } catch {
          break;
        }
        await new Promise((resolve) => setTimeout(resolve, Math.max(1, retryAfterSeconds) * 1000));
      }
      attachDurationMs = Math.round(performance.now() - attachStartedAt);
      if (attach.status !== 200) throw new Error(`POST attach-endpoint expected 200, got ${attach.status}: ${attachText}`);
      const attached = JSON.parse(attachText);
      if (attached.transport !== expectedTransport) {
        throw new Error(`expected ${expectedTransport} attach, got ${attached.transport}`);
      }
      // Freestyle reaches the daemon straight at the VM's public IPv6 over ws.
      if (!/^wss?:\/\/.+\/v1\/link(\?|$)/.test(attached.route ?? "")) {
        throw new Error("cmux-remote attach response missing the daemon route");
      }
      attachTransport = attached.transport;
    }

    let edge;
    if (edgeCheck) {
      const exec = async (command, timeoutMs = 120_000) => {
        const response = await fetchWithTimeout(`${targetUrl}/api/vm/${encodeURIComponent(vmId)}/exec`, {
          method: "POST",
          headers: { ...authHeaders, "content-type": "application/json" },
          body: JSON.stringify({ command, timeoutMs }),
        }, timeoutMs + 30_000);
        const text = await response.text();
        if (response.status !== 200) throw new Error(`POST exec expected 200, got ${response.status}: ${text}`);
        return JSON.parse(text);
      };
      const guestEnv = "export HOME=/root; for f in /etc/profile.d/*.sh; do [ -r \"$f\" ] && . \"$f\"; done; . /etc/cmux/agent-config.sh;";
      const originHost = await exec(`${guestEnv} printf '%s' "$CMUX_CODEROUTER_URL" | sed -e 's#^https\\?://##' -e 's#/.*$##'`);
      const hosts = await exec("sed -n '/BEGIN freestyle-tls-egress/,/END freestyle-tls-egress/p' /etc/hosts");
      const host = (originHost.stdout ?? "").trim();
      const steered = host.length > 0 && (hosts.stdout ?? "").includes(host);
      // Any crt_ string under the agent config roots means a token leaked into the guest.
      const leak = await exec("grep -rslE 'crt_[A-Za-z0-9_-]{40,}' /root/.config/cmux /root/.codex /root/.pi /root/.config/opencode /etc/cmux /etc/environment /etc/profile.d 2>/dev/null; true");
      const tokenOnDisk = (leak.stdout ?? "").trim();
      // /v1/models needs an upstream client_version query, so the self-usage
      // route is the guest-side proof that the bound token arrived.
      const models = await exec(`${guestEnv} curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -H "authorization: Bearer $OPENAI_API_KEY" "$CMUX_CODEROUTER_URL/api/coderouter/vm-usage/self"`);
      const modelsStatus = (models.stdout ?? "").trim();
      const codex = await exec(`${guestEnv} cd /root && codex exec --skip-git-repo-check 'Reply with exactly the single word pong and nothing else.' 2>&1 | tail -20`, 240_000);
      const codexOut = `${codex.stdout ?? ""}${codex.stderr ?? ""}`;
      // codex echoes the prompt, so only a line that is exactly the answer counts.
      const codexPong = codexOut.split("\n").some((line) => line.trim().toLowerCase() === "pong");
      // The edge delivered the token but the team has no upstream subscription:
      // a real outcome on staging teams, reported rather than failed.
      const codexOutcome = codexPong ? "answered" : /no_usable_account/.test(codexOut) ? "no_account" : "failed";
      edge = {
        hostsSteered: steered,
        tokenOnDisk: tokenOnDisk === "" ? null : tokenOnDisk,
        modelsStatus,
        codexExit: codex.exitCode,
        codexOutcome,
        codexTail: codexOut.slice(-400),
      };
      if (claudeCheck) {
        // Claude Code trusts the edge CA through NODE_EXTRA_CA_CERTS exported by
        // agent-config.sh and authenticates with the placeholder x-api-key; the
        // edge-injected route token selects the team's upstream.
        const claude = await exec(
          `${guestEnv} cd /root && claude -p 'Reply with exactly the single word pong and nothing else.' --model claude-haiku-4-5-20251001 2>&1 | tail -20`,
          240_000,
        );
        const claudeOut = `${claude.stdout ?? ""}${claude.stderr ?? ""}`;
        const claudePong = claudeOut.split("\n").some((line) => line.trim().toLowerCase().replace(/[.!]$/, "") === "pong");
        edge.claudeExit = claude.exitCode;
        edge.claudeOutcome = claudePong ? "answered" : /claude_upstream_not_configured|no upstream/i.test(claudeOut) ? "no_upstream" : "failed";
        edge.claudeTail = claudeOut.slice(-400);
        const selfUsage = await exec(`${guestEnv} curl -sS --max-time 20 -H "authorization: Bearer $OPENAI_API_KEY" "$CMUX_CODEROUTER_URL/api/coderouter/vm-usage/self"`);
        edge.selfUsage = (selfUsage.stdout ?? "").trim().slice(0, 600);
      }
      const problems = [];
      if (!steered) problems.push(`guest /etc/hosts is not steered to the edge for ${host || "the coderouter origin"}`);
      if (tokenOnDisk) problems.push(`route token found in guest files: ${tokenOnDisk}`);
      if (modelsStatus !== "200") problems.push(`GET /api/coderouter/vm-usage/self from the guest returned ${modelsStatus || "nothing"}`);
      if (codexOutcome === "failed") problems.push(`codex turn through the edge did not answer: ${edge.codexTail}`);
      if (claudeCheck && edge.claudeOutcome !== "answered") problems.push(`claude turn through the edge did not answer: ${edge.claudeTail}`);
      if (problems.length > 0) throw new Error(`edge check failed: ${problems.join("; ")}`);
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
      ...(edge ? { edge } : {}),
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
