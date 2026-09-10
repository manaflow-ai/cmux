#!/usr/bin/env bun

import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

import { StackServerApp } from "@stackframe/stack";
import { Pool } from "pg";

import {
  createLegacySubrouterRetirementClient,
  legacySubrouterRetirementConfig,
} from "../../services/subrouter/legacyRetirementClient";
import {
  loadTargetEnv,
  parseBoolean,
  projects,
} from "../cloud-vm/projects.mjs";

export type LegacyTenantMapping = {
  readonly teamId: string;
  readonly tenantId: string;
  readonly tenantName: string;
};

type StackMigrationSession = {
  readonly accessToken: string;
  readonly close: () => Promise<void>;
};

type HostedTenantExchange = {
  readonly tenantId: string;
  readonly tenantKey: string;
};

type LegacyTenantMigrationTarget = "staging" | "production";

export function legacySubrouterRetirementConfigForTarget(
  target: LegacyTenantMigrationTarget,
  runtimeEnv: Record<string, string | undefined>,
) {
  const targetBaseUrl = target === "production"
    ? "https://subrouter.cmux.dev"
    : "https://subrouter-staging.cmux.dev";
  const configuredBaseUrl = runtimeEnv.SUBROUTER_BASE_URL?.trim().replace(/\/+$/, "");
  if (configuredBaseUrl && configuredBaseUrl !== targetBaseUrl) {
    throw new Error(`legacy Subrouter source does not match ${target} target`);
  }
  return legacySubrouterRetirementConfig({
    ...runtimeEnv,
    SUBROUTER_BASE_URL: targetBaseUrl,
  });
}

export async function runLegacyTenantMigration(options: {
  readonly mappings: readonly LegacyTenantMapping[];
  readonly apply: boolean;
  readonly finalizeSource: boolean;
  readonly destinationUrl: string;
  readonly openStackSession: (
    mapping: LegacyTenantMapping,
  ) => Promise<StackMigrationSession>;
  readonly exchangeHostedTenant: (input: {
    readonly teamId: string;
    readonly teamName: string;
    readonly accessToken: string;
    readonly destinationUrl: string;
  }) => Promise<HostedTenantExchange>;
  readonly migrateLegacyTenant: (input: {
    readonly legacyTenantId: string;
    readonly destinationUrl: string;
    readonly tenantKey: string;
    readonly finalizeSource: boolean;
  }) => Promise<{
    readonly migrated: number;
    readonly sourceFinalized: boolean;
  }>;
  readonly markFinalizationStarted: (teamId: string) => Promise<void>;
  readonly markHostedReady: (teamId: string) => Promise<void>;
  readonly log: (value: unknown) => void;
}): Promise<{
  readonly planned: number;
  readonly migrated: number;
  readonly sourceFinalized: boolean;
}> {
  if (options.finalizeSource && !options.apply) {
    throw new Error("--finalize-source requires --apply");
  }
  assertDestination(options.destinationUrl);
  const mappings = validatedMappings(options.mappings);
  if (!options.apply) {
    options.log({
      mode: "dry-run",
      destinationUrl: options.destinationUrl,
      tenants: mappings.map((mapping) => ({
        teamId: mapping.teamId,
        legacyTenantId: mapping.tenantId,
      })),
    });
    return { planned: mappings.length, migrated: 0, sourceFinalized: false };
  }

  // Resolve every destination before any source finalization. This catches a
  // stale DB mapping or missing Stack membership while all legacy tenants are
  // still serving traffic.
  const destinations: Array<{
    readonly mapping: LegacyTenantMapping;
    readonly tenantKey: string;
  }> = [];
  for (const mapping of mappings) {
    const session = await options.openStackSession(mapping);
    let operationError: unknown;
    try {
      const destination = await options.exchangeHostedTenant({
        teamId: mapping.teamId,
        teamName: mapping.tenantName,
        accessToken: session.accessToken,
        destinationUrl: options.destinationUrl,
      });
      if (destination.tenantId !== mapping.teamId) {
        throw new Error(`hosted tenant id does not match DB team mapping for ${mapping.teamId}`);
      }
      destinations.push({ mapping, tenantKey: destination.tenantKey });
    } catch (error) {
      operationError = error;
      throw error;
    } finally {
      try {
        await session.close();
      } catch (closeError) {
        if (operationError === undefined) throw closeError;
      }
    }
  }

  let migrated = 0;
  for (const destination of destinations) {
    if (options.finalizeSource) {
      // Persist the recoverable side of the two-phase transition before the
      // external finalization. Subrouter v0.1.54 returns its completed receipt
      // for an identical retry, so rerunning this command can finish the gate
      // write after a database interruption without touching Hosted again.
      await options.markFinalizationStarted(destination.mapping.teamId);
    }
    const result = await options.migrateLegacyTenant({
      legacyTenantId: destination.mapping.tenantId,
      destinationUrl: options.destinationUrl,
      tenantKey: destination.tenantKey,
      finalizeSource: options.finalizeSource,
    });
    if (result.sourceFinalized !== options.finalizeSource) {
      throw new Error(
        `legacy source finalization mismatch for ${destination.mapping.tenantId}`,
      );
    }
    if (result.sourceFinalized) {
      await options.markHostedReady(destination.mapping.teamId);
    }
    migrated += result.migrated;
    options.log({
      mode: options.finalizeSource ? "finalize" : "pre-copy",
      teamId: destination.mapping.teamId,
      legacyTenantId: destination.mapping.tenantId,
      migrated: result.migrated,
      sourceFinalized: result.sourceFinalized,
    });
  }
  return {
    planned: mappings.length,
    migrated,
    sourceFinalized: options.finalizeSource,
  };
}

async function main(): Promise<void> {
  const { target, apply, finalizeSource } = parseArguments(process.argv.slice(2));
  const project = projects[target];
  const runtimeEnv = loadTargetEnv(project);
  const destinationUrl = target === "production"
    ? "https://sr.cmux.com"
    : "https://staging.sr.cmux.com";
  const store = await openLegacyTenantMigrationStore(runtimeEnv);
  try {
    const mappings = await store.loadMappings();
    const legacyClient = createLegacySubrouterRetirementClient(
      legacySubrouterRetirementConfigForTarget(target, runtimeEnv),
    );
    const stackApp = stackAppFromEnv(runtimeEnv);

    const result = await runLegacyTenantMigration({
      mappings,
      apply,
      finalizeSource,
      destinationUrl,
      openStackSession: (mapping) =>
        openStackMigrationSession(stackApp, mapping, runtimeEnv),
      exchangeHostedTenant: (input) =>
        exchangeHostedTenant({
          ...input,
          controlToken: requiredEnv(
            runtimeEnv,
            "SUBROUTER_STACK_TENANT_DELETE_TOKEN",
          ),
        }),
      migrateLegacyTenant: async (input) =>
        await legacyClient.migrateTenant(input.legacyTenantId, {
          destinationUrl: input.destinationUrl,
          tenantKey: input.tenantKey,
          finalizeSource: input.finalizeSource,
        }),
      markFinalizationStarted: store.markFinalizationStarted,
      markHostedReady: store.markHostedReady,
      log: (value) => console.log(JSON.stringify(value)),
    });
    console.log(JSON.stringify({ ok: true, target, ...result }));
  } finally {
    await store.close();
  }
}

function parseArguments(args: readonly string[]): {
  readonly target: "staging" | "production";
  readonly apply: boolean;
  readonly finalizeSource: boolean;
} {
  const targetArg = args.find((arg) => !arg.startsWith("--"));
  const target = targetArg === "prod" ? "production" : targetArg;
  if (target !== "staging" && target !== "production") {
    throw new Error(
      "Usage: migrate-legacy-tenants.ts <staging|production> [--apply] [--finalize-source]",
    );
  }
  const allowed = new Set([targetArg!, "--apply", "--finalize-source"]);
  const unknown = args.find((arg) => !allowed.has(arg));
  if (unknown) throw new Error(`unknown option: ${unknown}`);
  return {
    target,
    apply: args.includes("--apply"),
    finalizeSource: args.includes("--finalize-source"),
  };
}

async function openLegacyTenantMigrationStore(
  runtimeEnv: Record<string, string | undefined>,
): Promise<{
  readonly loadMappings: () => Promise<readonly LegacyTenantMapping[]>;
  readonly markFinalizationStarted: (teamId: string) => Promise<void>;
  readonly markHostedReady: (teamId: string) => Promise<void>;
  readonly close: () => Promise<void>;
}> {
  for (const key of ["AWS_REGION", "PGHOST", "PGPORT", "PGUSER", "PGDATABASE"]) {
    if (!runtimeEnv[key]?.trim()) throw new Error(`migration environment is missing ${key}`);
  }
  const port = Number(runtimeEnv.PGPORT);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    throw new Error("migration environment has an invalid PGPORT");
  }
  const password = execFileSync(process.env.AWS_CLI ?? "aws", [
    "rds",
    "generate-db-auth-token",
    "--hostname",
    runtimeEnv.PGHOST!,
    "--port",
    String(port),
    "--region",
    runtimeEnv.AWS_REGION!,
    "--username",
    runtimeEnv.PGUSER!,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
  const pool = new Pool({
    host: runtimeEnv.PGHOST,
    port,
    user: runtimeEnv.PGUSER,
    database: runtimeEnv.PGDATABASE,
    password,
    ssl: {
      rejectUnauthorized: parseBoolean(
        runtimeEnv.CMUX_DB_SSL_REJECT_UNAUTHORIZED,
        true,
      ),
    },
    max: 1,
  });
  return {
    loadMappings: async () => {
      const result = await pool.query<{
        teamId: string;
        tenantId: string;
        tenantName: string;
      }>(
        `select team_id as "teamId", tenant_id as "tenantId", tenant_name as "tenantName"
         from subrouter_tenants
         order by team_id`,
      );
      return result.rows;
    },
    markFinalizationStarted: async (teamId) => {
      const result = await pool.query(
        `update subrouter_tenants
         set hosted_finalization_started_at = coalesce(hosted_finalization_started_at, now()),
             updated_at = now()
         where team_id = $1`,
        [teamId],
      );
      if (result.rowCount !== 1) {
        throw new Error(`legacy tenant mapping disappeared for ${teamId}`);
      }
    },
    markHostedReady: async (teamId) => {
      const result = await pool.query(
        `update subrouter_tenants
         set hosted_ready_at = coalesce(hosted_ready_at, now()), updated_at = now()
         where team_id = $1 and hosted_finalization_started_at is not null`,
        [teamId],
      );
      if (result.rowCount !== 1) {
        throw new Error(`legacy tenant finalization was not prepared for ${teamId}`);
      }
    },
    close: async () => await pool.end(),
  };
}

function stackAppFromEnv(runtimeEnv: Record<string, string | undefined>) {
  const projectId = requiredEnv(runtimeEnv, "NEXT_PUBLIC_STACK_PROJECT_ID");
  const publishableClientKey = requiredEnv(
    runtimeEnv,
    "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  );
  const secretServerKey = requiredEnv(runtimeEnv, "STACK_SECRET_SERVER_KEY");
  return new StackServerApp({
    projectId,
    publishableClientKey,
    secretServerKey,
    tokenStore: null,
    noAutomaticPrefetch: true,
  });
}

async function openStackMigrationSession(
  app: ReturnType<typeof stackAppFromEnv>,
  mapping: LegacyTenantMapping,
  runtimeEnv: Record<string, string | undefined>,
): Promise<StackMigrationSession> {
  const team = await app.getTeam(mapping.teamId);
  const teamUsers = team ? await team.listUsers() : [];
  const directUser = teamUsers.length === 0
    ? await app.getUser(mapping.teamId)
    : null;
  const user = [...teamUsers, ...(directUser ? [directUser] : [])]
    .sort((left, right) => left.id.localeCompare(right.id))[0];
  if (!user) {
    throw new Error(`Stack mapping has no member for ${mapping.teamId}`);
  }
  const session = await user.createSession({
    expiresInMillis: 5 * 60 * 1_000,
    isImpersonation: true,
  });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) {
    throw new Error(`Stack session is incomplete for ${mapping.teamId}`);
  }
  return {
    accessToken: tokens.accessToken,
    close: async () => {
      await revokeStackSession(runtimeEnv, tokens.accessToken!, tokens.refreshToken!);
    },
  };
}

async function exchangeHostedTenant(input: {
  readonly teamId: string;
  readonly teamName: string;
  readonly accessToken: string;
  readonly destinationUrl: string;
  readonly controlToken: string;
}): Promise<HostedTenantExchange> {
  let response: Response;
  try {
    response = await fetch(`${input.destinationUrl}/_subrouter/auth/stack`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${input.accessToken}`,
        "content-type": "application/json",
        "x-subrouter-stack-control-token": input.controlToken,
      },
      body: JSON.stringify({
        teamId: input.teamId,
        teamName: input.teamName,
        capabilities: ["manage_accounts"],
      }),
      signal: AbortSignal.timeout(30_000),
    });
  } catch {
    throw new Error(`hosted tenant exchange is unavailable for ${input.teamId}`);
  }
  if (!response.ok) {
    throw new Error(
      `hosted tenant exchange failed for ${input.teamId} with status ${response.status}`,
    );
  }
  const body = await response.json().catch(() => null) as Record<string, unknown> | null;
  if (
    !body ||
    typeof body.tenantId !== "string" ||
    typeof body.tenantKey !== "string" ||
    !/^srt_[0-9a-f]{32}$/.test(body.tenantKey)
  ) {
    throw new Error(`hosted tenant exchange was invalid for ${input.teamId}`);
  }
  return { tenantId: body.tenantId, tenantKey: body.tenantKey };
}

async function revokeStackSession(
  runtimeEnv: Record<string, string | undefined>,
  accessToken: string,
  refreshToken: string,
): Promise<void> {
  const projectId = requiredEnv(runtimeEnv, "NEXT_PUBLIC_STACK_PROJECT_ID");
  const publishableClientKey = requiredEnv(
    runtimeEnv,
    "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  );
  const apiUrl = (runtimeEnv.NEXT_PUBLIC_STACK_API_URL?.trim() ||
    "https://api.stack-auth.com/api/v1").replace(/\/+$/, "");
  const headers = new Headers({
    "content-type": "application/json",
    "x-stack-refresh-token": refreshToken,
    "x-hexclave-refresh-token": refreshToken,
  });
  for (const prefix of ["x-stack", "x-hexclave"]) {
    headers.set(`${prefix}-project-id`, projectId);
    headers.set(`${prefix}-access-type`, "client");
    headers.set(`${prefix}-publishable-client-key`, publishableClientKey);
    headers.set(`${prefix}-access-token`, accessToken);
  }
  const response = await fetch(`${apiUrl}/auth/sessions/current`, {
    method: "DELETE",
    headers,
    body: "{}",
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok && response.status !== 401 && response.status !== 404) {
    throw new Error(`Stack session revocation failed with status ${response.status}`);
  }
}

function validatedMappings(
  values: readonly LegacyTenantMapping[],
): readonly LegacyTenantMapping[] {
  const mappings = [...values].sort((left, right) =>
    left.teamId.localeCompare(right.teamId)
  );
  const teamIds = new Set<string>();
  const tenantIds = new Set<string>();
  for (const mapping of mappings) {
    if (!mapping.teamId.trim() || !mapping.tenantId.trim() || !mapping.tenantName.trim()) {
      throw new Error("legacy tenant mapping contains an empty identifier");
    }
    if (teamIds.has(mapping.teamId) || tenantIds.has(mapping.tenantId)) {
      throw new Error("legacy tenant mapping contains a duplicate identifier");
    }
    teamIds.add(mapping.teamId);
    tenantIds.add(mapping.tenantId);
  }
  return mappings;
}

function assertDestination(value: string): void {
  if (
    value !== "https://sr.cmux.com" &&
    value !== "https://staging.sr.cmux.com"
  ) {
    throw new Error("hosted migration destination is not allowed");
  }
}

function requiredEnv(
  runtimeEnv: Record<string, string | undefined>,
  key: string,
): string {
  const value = runtimeEnv[key]?.trim();
  if (!value) throw new Error(`migration environment is missing ${key}`);
  return value;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
