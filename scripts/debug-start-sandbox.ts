#!/usr/bin/env bun

import "dotenv/config";
import { normalizeOrigin } from "@cmux/shared";
import { StackAdminApp } from "@stackframe/js";
import { createClient } from "@cmux/www-openapi-client/client";
import { postApiSandboxesStart } from "@cmux/www-openapi-client";

interface CliOptions {
  environmentId: string;
  teamSlugOrId: string;
  attempts: number;
  delayMs: number;
  userId: string;
  ttlSeconds?: number;
}

function parseArgs(): CliOptions {
  const args = process.argv.slice(2);
  const options: Partial<CliOptions> = {};
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const value = args[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for --${key}`);
    }
    (options as Record<string, string>)[key] = value;
    i += 1;
  }

  const environmentId =
    options.environmentId ?? process.env.DEBUG_ENVIRONMENT_ID;
  if (!environmentId) {
    throw new Error(
      "Provide an environment id via --environmentId or DEBUG_ENVIRONMENT_ID"
    );
  }

  const teamSlugOrId =
    options.teamSlugOrId ?? process.env.DEBUG_TEAM_SLUG ?? "manaflow";

  const attempts = Number(options.attempts ?? process.env.DEBUG_ATTEMPTS ?? 1);
  if (!Number.isFinite(attempts) || attempts <= 0) {
    throw new Error("Attempts must be a positive integer");
  }

  const delayMs = Number(options.delayMs ?? process.env.DEBUG_DELAY_MS ?? 5000);
  if (!Number.isFinite(delayMs) || delayMs < 0) {
    throw new Error("delayMs must be a non-negative number");
  }

  const userId =
    options.userId ?? process.env.DEBUG_STACK_USER_ID ?? "487b5ddc-0da0-4f12-8834-f452863a83f5";

  const ttlSecondsValue = options.ttlSeconds ?? process.env.DEBUG_TTL_SECONDS;
  const ttlSeconds =
    ttlSecondsValue !== undefined ? Number(ttlSecondsValue) : undefined;
  if (ttlSeconds !== undefined && (!Number.isFinite(ttlSeconds) || ttlSeconds <= 0)) {
    throw new Error("ttlSeconds must be a positive number when provided");
  }

  return {
    environmentId,
    teamSlugOrId,
    attempts,
    delayMs,
    userId,
    ttlSeconds,
  };
}

async function getAuthHeader(userId: string): Promise<string> {
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
  const publishableClientKey = process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY;
  const secretServerKey = process.env.STACK_SECRET_SERVER_KEY;
  const superSecretAdminKey = process.env.STACK_SUPER_SECRET_ADMIN_KEY;

  if (!projectId || !publishableClientKey || !secretServerKey || !superSecretAdminKey) {
    throw new Error("Missing required Stack environment variables in .env");
  }

  const admin = new StackAdminApp({
    projectId,
    publishableClientKey,
    secretServerKey,
    superSecretAdminKey,
    tokenStore: "memory",
  });

  const user = await admin.getUser(userId);
  if (!user) {
    throw new Error(`User ${userId} not found in Stack project`);
  }

  const session = await user.createSession({ expiresInMillis: 5 * 60 * 1000 });
  const tokens = await session.getTokens();
  if (!tokens.accessToken) {
    throw new Error("Stack did not return an access token");
  }

  return JSON.stringify({
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken ?? undefined,
  });
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function main(): Promise<void> {
  const options = parseArgs();
  const rawBaseUrl = process.env.NEXT_PUBLIC_WWW_ORIGIN ?? "http://localhost:9779";
  const baseUrl = normalizeOrigin(rawBaseUrl);
  const client = createClient({ baseUrl });

  const authHeader = await getAuthHeader(options.userId);

  console.log(`Starting sandbox debug loop -> env ${options.environmentId}`);
  console.log(`Base URL: ${baseUrl}`);
  console.log(`Attempts: ${options.attempts}, delay: ${options.delayMs}ms`);

  for (let attempt = 1; attempt <= options.attempts; attempt += 1) {
    if (options.attempts > 1) {
      console.log(`\n[Attempt ${attempt}/${options.attempts}]`);
    }
    try {
      const res = await postApiSandboxesStart({
        client,
        headers: { "x-stack-auth": authHeader },
        body: {
          teamSlugOrId: options.teamSlugOrId,
          environmentId: options.environmentId,
          ttlSeconds: options.ttlSeconds ?? 20 * 60,
        },
      });

      console.log(`Status: ${res.response.status}`);
      if (res.response.ok) {
        console.log("Sandbox start response:", res.data);
      } else {
        console.log("Error response body:", await res.response.text());
      }
    } catch (error) {
      console.error("Request failed", error);
    }

    if (attempt < options.attempts) {
      await sleep(options.delayMs);
    }
  }
}

main().catch((error) => {
  console.error("Fatal error running sandbox debug script", error);
  process.exitCode = 1;
});
