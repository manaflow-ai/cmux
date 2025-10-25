#!/usr/bin/env bun

import "dotenv/config";

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parse as parseEnvFile } from "dotenv";
import { StackAdminApp } from "@stackframe/js";
import {
  InstanceStatus,
  MorphCloudClient,
  type Instance,
} from "morphcloud";

type UserSummary = {
  id: string;
  displayName: string | null;
  primaryEmail: string | null;
};

type TeamSummary = {
  id: string;
  displayName: string | null;
  profileImageUrl: string | null;
};

type StackEnvConfig = {
  label: string;
  projectId: string;
  publishableClientKey: string;
  secretServerKey: string;
  superSecretAdminKey: string;
};

type UserRecord = {
  summary: UserSummary;
  environments: Set<string>;
};

type TeamRecord = {
  summary: TeamSummary;
  environments: Set<string>;
};

type InstanceRecord = {
  instance: Instance;
  metadata: Record<string, string>;
  ownerUserId: string | null;
  owner: UserSummary | null;
  ownerEnvironments: string[];
  ownerName: string | null;
  ownerEmail: string | null;
  teamId: string | null;
  team: TeamSummary | null;
  teamEnvironments: string[];
};

const REQUIRED_STACK_KEYS = [
  "NEXT_PUBLIC_STACK_PROJECT_ID",
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  "STACK_SECRET_SERVER_KEY",
  "STACK_SUPER_SECRET_ADMIN_KEY",
] as const;

const REQUIRED_MORPH_KEYS = ["MORPH_API_KEY"] as const;

function requireMorphEnv(): void {
  for (const key of REQUIRED_MORPH_KEYS) {
    const value = process.env[key];
    if (!value || value.trim() === "") {
      throw new Error(`Missing required environment variable: ${key}`);
    }
  }
}

function readOptionalEnvFile(fileName: string): Record<string, string> | null {
  const filePath = path.resolve(process.cwd(), fileName);
  if (!fs.existsSync(filePath)) {
    return null;
  }
  const content = fs.readFileSync(filePath, "utf8");
  return parseEnvFile(content);
}

function trimOrNull(value: string | undefined): string | null {
  if (value === undefined) return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

function extractStackConfig(
  source: Record<string, string | undefined>,
  label: string,
): StackEnvConfig | null {
  const projectId = trimOrNull(source.NEXT_PUBLIC_STACK_PROJECT_ID);
  const publishableClientKey = trimOrNull(
    source.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
  );
  const secretServerKey = trimOrNull(source.STACK_SECRET_SERVER_KEY);
  const superSecretAdminKey = trimOrNull(source.STACK_SUPER_SECRET_ADMIN_KEY);

  if (
    !projectId ||
    !publishableClientKey ||
    !secretServerKey ||
    !superSecretAdminKey
  ) {
    return null;
  }

  return {
    label,
    projectId,
    publishableClientKey,
    secretServerKey,
    superSecretAdminKey,
  };
}

function dedupeConfigs(configs: StackEnvConfig[]): StackEnvConfig[] {
  const seen = new Set<string>();
  const result: StackEnvConfig[] = [];
  for (const config of configs) {
    const key = [
      config.projectId,
      config.publishableClientKey,
      config.secretServerKey,
      config.superSecretAdminKey,
    ].join("|");
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(config);
  }
  return result;
}

async function loadUsersForEnvironment(
  admin: StackAdminApp,
  envLabel: string,
  userIndex: Map<string, UserRecord>,
): Promise<void> {
  const pageSize = 200;
  let cursor: string | undefined;
  for (;;) {
    const page = (await admin.listUsers({
      cursor,
      limit: pageSize,
      includeAnonymous: true,
    })) as { nextCursor: string | null } & Array<{
      id: string;
      displayName?: string | null;
      primaryEmail?: string | null;
    }>;

    for (const user of page) {
      const summary: UserSummary = {
        id: user.id,
        displayName: user.displayName ?? null,
        primaryEmail: user.primaryEmail ?? null,
      };

      const existing = userIndex.get(user.id);
      if (existing) {
        existing.environments.add(envLabel);
        if (!existing.summary.displayName && summary.displayName) {
          existing.summary.displayName = summary.displayName;
        }
        if (!existing.summary.primaryEmail && summary.primaryEmail) {
          existing.summary.primaryEmail = summary.primaryEmail;
        }
      } else {
        userIndex.set(user.id, {
          summary,
          environments: new Set([envLabel]),
        });
      }
    }

    if (!page.nextCursor) break;
    cursor = page.nextCursor ?? undefined;
  }
}

async function loadTeamsForEnvironment(
  admin: StackAdminApp,
  envLabel: string,
  teamIndex: Map<string, TeamRecord>,
): Promise<void> {
  const list = (await admin.listTeams()) as Array<{
    id: string;
    displayName?: string | null;
    profileImageUrl?: string | null;
  }>;

  for (const team of list) {
    const summary: TeamSummary = {
      id: team.id,
      displayName: team.displayName ?? null,
      profileImageUrl: team.profileImageUrl ?? null,
    };

    const existing = teamIndex.get(team.id);
    if (existing) {
      existing.environments.add(envLabel);
      if (!existing.summary.displayName && summary.displayName) {
        existing.summary.displayName = summary.displayName;
      }
      if (!existing.summary.profileImageUrl && summary.profileImageUrl) {
        existing.summary.profileImageUrl = summary.profileImageUrl;
      }
    } else {
      teamIndex.set(team.id, {
        summary,
        environments: new Set([envLabel]),
      });
    }
  }
}

function formatRelativeTime(timestampSeconds: number): string {
  const diffMs = Date.now() - timestampSeconds * 1000;
  const diffSeconds = Math.max(Math.floor(diffMs / 1000), 0);
  if (diffSeconds < 60) {
    return `${diffSeconds}s ago`;
  }
  const diffMinutes = Math.floor(diffSeconds / 60);
  if (diffMinutes < 60) {
    return `${diffMinutes}m ago`;
  }
  const diffHours = Math.floor(diffMinutes / 60);
  if (diffHours < 24) {
    return `${diffHours}h ago`;
  }
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 7) {
    return `${diffDays}d ago`;
  }
  const diffWeeks = Math.floor(diffDays / 7);
  if (diffWeeks < 5) {
    return `${diffWeeks}w ago`;
  }
  const diffMonths = Math.floor(diffDays / 30);
  if (diffMonths < 12) {
    return `${diffMonths}mo ago`;
  }
  const diffYears = Math.floor(diffDays / 365);
  return `${diffYears}y ago`;
}

function toStringRecord(
  metadata: Instance["metadata"],
): Record<string, string> {
  const out: Record<string, string> = {};
  if (!metadata) return out;
  for (const [key, value] of Object.entries(metadata)) {
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.length > 0) {
        out[key] = trimmed;
      }
    } else if (
      typeof value === "number" ||
      typeof value === "boolean" ||
      value === null
    ) {
      out[key] = String(value);
    }
  }
  return out;
}

const IGNORED_METADATA_KEYS = new Set(["instance", "taskRunJwt"]);

const OWNER_NAME_KEYS = [
  "ownerName",
  "userName",
  "name",
  "owner_display_name",
] as const;

const OWNER_EMAIL_KEYS = [
  "ownerEmail",
  "userEmail",
  "email",
  "owner_email",
] as const;

function renderOwnerLabel(
  owner: UserSummary | null,
  userId: string | null,
  environments: string[],
  fallbackName: string | null,
  fallbackEmail: string | null,
): string {
  const name =
    owner?.displayName ??
    (fallbackName && fallbackName.trim().length > 0 ? fallbackName : null);
  const email =
    owner?.primaryEmail ??
    (fallbackEmail && fallbackEmail.trim().length > 0 ? fallbackEmail : null);

  let base: string;
  if (name && email) {
    base = `${name} <${email}>`;
  } else if (name) {
    base = name;
  } else if (email) {
    base = email;
  } else if (userId) {
    base = userId;
  } else {
    base = "Unknown user";
  }

  const envSuffix =
    environments.length > 0 ? ` (${environments.join(", ")})` : "";
  return `${base}${envSuffix}`;
}

function renderTeamLabel(
  team: TeamSummary | null,
  teamId: string | null,
  environments: string[],
): string {
  const base = team?.displayName ?? teamId ?? "Unknown team";
  const envSuffix =
    environments.length > 0 ? ` (${environments.join(", ")})` : "";
  return `${base}${envSuffix}`;
}

async function main(): Promise<void> {
  requireMorphEnv();

  const stackConfigs: StackEnvConfig[] = dedupeConfigs(
    [
      extractStackConfig(process.env, "local"),
      extractStackConfig(readOptionalEnvFile(".env.production") ?? {}, "prod"),
    ].filter((cfg): cfg is StackEnvConfig => cfg !== null),
  );

  if (stackConfigs.length === 0) {
    throw new Error(
      `No Stack admin configuration found. Ensure the following keys exist in .env or .env.production: ${REQUIRED_STACK_KEYS.join(
        ", ",
      )}`,
    );
  }

  console.log(
    `Using Stack environments: ${stackConfigs
      .map((cfg) => cfg.label)
      .join(", ")}`,
  );

  const admins = stackConfigs.map(
    (config) =>
      new StackAdminApp({
        tokenStore: "memory",
        projectId: config.projectId,
        publishableClientKey: config.publishableClientKey,
        secretServerKey: config.secretServerKey,
        superSecretAdminKey: config.superSecretAdminKey,
      }),
  );

  const userIndex = new Map<string, UserRecord>();
  const teamIndex = new Map<string, TeamRecord>();

  for (let i = 0; i < admins.length; i += 1) {
    const admin = admins[i]!;
    const envLabel = stackConfigs[i]!.label;
    try {
      await loadUsersForEnvironment(admin, envLabel, userIndex);
    } catch (error) {
      console.warn(
        `Failed to load users for ${envLabel}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
    try {
      await loadTeamsForEnvironment(admin, envLabel, teamIndex);
    } catch (error) {
      console.warn(
        `Failed to load teams for ${envLabel}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  console.log("Fetching Morph instances...");
  const morphClient = new MorphCloudClient();
  const allInstances = await morphClient.instances.list();
  const activeStatuses = new Set<InstanceStatus>([
    InstanceStatus.READY,
    InstanceStatus.PENDING,
  ]);
  const activeInstances = allInstances.filter((instance) =>
    activeStatuses.has(instance.status),
  );

  if (activeInstances.length === 0) {
    console.log("No active Morph instances found.");
    return;
  }

  const records: InstanceRecord[] = [];

  for (const instance of activeInstances) {
    const metadata = toStringRecord(instance.metadata);
    const ownerUserId =
      metadata.userId ?? metadata.ownerUserId ?? metadata.owner ?? null;
    const ownerRecord = ownerUserId
      ? userIndex.get(ownerUserId) ?? null
      : null;
    const owner = ownerRecord?.summary ?? null;
    const ownerEnvironments = ownerRecord
      ? [...ownerRecord.environments].sort()
      : [];

    const teamId = metadata.teamId ?? null;
    const teamRecord = teamId ? teamIndex.get(teamId) ?? null : null;
    const team = teamRecord?.summary ?? null;
    const teamEnvironments = teamRecord
      ? [...teamRecord.environments].sort()
      : [];

    const ownerName =
      OWNER_NAME_KEYS.map((key) => metadata[key] ?? null).find(
        (value) => value !== null && value.trim().length > 0,
      ) ?? null;
    const ownerEmail =
      OWNER_EMAIL_KEYS.map((key) => metadata[key] ?? null).find(
        (value) => value !== null && value.trim().length > 0,
      ) ?? null;

    records.push({
      instance,
      metadata,
      ownerUserId,
      owner,
      ownerEnvironments,
      ownerName,
      ownerEmail,
      teamId,
      team,
      teamEnvironments,
    });
  }

  const statusCounts = new Map<string, number>();
  const metadataAggregations = new Map<string, Map<string, number>>();
  const ownerAggregations = new Map<
    string,
    {
      userId: string | null;
      owner: UserSummary | null;
      environments: Set<string>;
      count: number;
      instanceIds: string[];
      teamIds: Set<string>;
      fallbackName: string | null;
      fallbackEmail: string | null;
    }
  >();
  const teamAggregations = new Map<
    string,
    {
      teamId: string | null;
      team: TeamSummary | null;
      environments: Set<string>;
      count: number;
      ownerIds: Set<string>;
    }
  >();

  const addMetadataAggregate = (key: string, rawValue: string | null) => {
    if (!rawValue || rawValue.trim() === "") return;
    if (IGNORED_METADATA_KEYS.has(key)) return;
    const category = metadataAggregations.get(key) ?? new Map<string, number>();
    category.set(rawValue, (category.get(rawValue) ?? 0) + 1);
    metadataAggregations.set(key, category);
  };

  for (const record of records) {
    statusCounts.set(
      record.instance.status,
      (statusCounts.get(record.instance.status) ?? 0) + 1,
    );

    const ownerKey = record.ownerUserId ?? "UNKNOWN";
    const ownerEntry =
      ownerAggregations.get(ownerKey) ??
      {
        userId: record.ownerUserId,
        owner: record.owner,
        environments: new Set<string>(),
        count: 0,
        instanceIds: [],
        teamIds: new Set<string>(),
        fallbackName: record.ownerName,
        fallbackEmail: record.ownerEmail,
      };
    ownerEntry.count += 1;
    ownerEntry.instanceIds.push(record.instance.id);
    for (const env of record.ownerEnvironments) {
      ownerEntry.environments.add(env);
    }
    if (record.teamId) {
      ownerEntry.teamIds.add(record.teamId);
    }
    ownerEntry.owner = record.owner ?? ownerEntry.owner ?? null;
    if (!ownerEntry.fallbackName && record.ownerName) {
      ownerEntry.fallbackName = record.ownerName;
    }
    if (!ownerEntry.fallbackEmail && record.ownerEmail) {
      ownerEntry.fallbackEmail = record.ownerEmail;
    }
    ownerAggregations.set(ownerKey, ownerEntry);

    const teamKey = record.teamId ?? "UNKNOWN";
    const teamEntry =
      teamAggregations.get(teamKey) ??
      {
        teamId: record.teamId,
        team: record.team,
        environments: new Set<string>(),
        count: 0,
        ownerIds: new Set<string>(),
      };
    teamEntry.count += 1;
    for (const env of record.teamEnvironments) {
      teamEntry.environments.add(env);
    }
    if (record.ownerUserId) {
      teamEntry.ownerIds.add(record.ownerUserId);
    }
    teamEntry.team = record.team ?? teamEntry.team ?? null;
    teamAggregations.set(teamKey, teamEntry);

    const ownerLabel = renderOwnerLabel(
      record.owner,
      record.ownerUserId,
      record.ownerEnvironments,
      record.ownerName,
      record.ownerEmail,
    );
    const teamLabel = renderTeamLabel(
      record.team,
      record.teamId,
      record.teamEnvironments,
    );

    addMetadataAggregate("app", record.metadata.app ?? null);
    addMetadataAggregate("teamId", teamLabel);
    addMetadataAggregate(
      "environmentId",
      record.metadata.environmentId ?? null,
    );
    addMetadataAggregate("agentName", record.metadata.agentName ?? null);
    addMetadataAggregate("owner", ownerLabel);
  }

  console.log("");
  console.log("Instance details:");
  const sortedRecords = [...records].sort(
    (a, b) => b.instance.created - a.instance.created,
  );
  for (const record of sortedRecords) {
    const metadataPairs = Object.entries(record.metadata)
      .filter(([key]) => !IGNORED_METADATA_KEYS.has(key))
      .map(([key, value]) => `${key}=${value}`);
    const createdIso = new Date(record.instance.created * 1000).toISOString();
    const ownerLabel = renderOwnerLabel(
      record.owner,
      record.ownerUserId,
      record.ownerEnvironments,
      record.ownerName,
      record.ownerEmail,
    );
    const teamLabel = renderTeamLabel(
      record.team,
      record.teamId,
      record.teamEnvironments,
    );
    console.log(
      [
        `- ${record.instance.id}`,
        `status=${record.instance.status.toLowerCase()}`,
        `created=${createdIso} (${formatRelativeTime(record.instance.created)})`,
        `owner=${ownerLabel}`,
        `team=${teamLabel}`,
      `metadata={${metadataPairs.join(", ")}}`,
    ].join(" | "),
    );
  }

  const statusSummaryLines: string[] = [];
  statusSummaryLines.push(`Active Morph instances: ${records.length}`);
  for (const [status, count] of [...statusCounts.entries()].sort((a, b) =>
    a[0].localeCompare(b[0]),
  )) {
    statusSummaryLines.push(`- ${status.toLowerCase()}: ${count}`);
  }

  const ownerSummaryLines: string[] = [];
  const ownerRows = [...ownerAggregations.values()].sort(
    (a, b) => b.count - a.count,
  );
  for (const owner of ownerRows) {
    const label = renderOwnerLabel(
      owner.owner,
      owner.userId,
      [...owner.environments].sort(),
      owner.fallbackName ?? null,
      owner.fallbackEmail ?? null,
    );
    const teamLabel =
      owner.teamIds.size > 0
        ? `teams: ${[...owner.teamIds].join(", ")}`
        : "teams: (none)";
    ownerSummaryLines.push(
      `- ${label} → ${owner.count} instance${
        owner.count === 1 ? "" : "s"
      } (${teamLabel})`,
    );
  }

  const teamSummaryLines: string[] = [];
  const teamRows = [...teamAggregations.values()].sort(
    (a, b) => b.count - a.count,
  );
  for (const team of teamRows) {
    const label = renderTeamLabel(
      team.team,
      team.teamId,
      [...team.environments].sort(),
    );
    const owners =
      team.ownerIds.size > 0 ? [...team.ownerIds].join(", ") : "(no owners)";
    teamSummaryLines.push(
      `- ${label} → ${team.count} instance${
        team.count === 1 ? "" : "s"
      } (owners: ${owners})`,
    );
  }

  const metadataSummaryLines: string[] = [];
  for (const [key, values] of metadataAggregations) {
    metadataSummaryLines.push(`- ${key}:`);
    const sortedValues = [...values.entries()].sort((a, b) => b[1] - a[1]);
    const topValues = sortedValues.slice(0, 10);
    for (const [value, count] of topValues) {
      metadataSummaryLines.push(`    • ${value}: ${count}`);
    }
    if (sortedValues.length > topValues.length) {
      metadataSummaryLines.push(
        `    • (${sortedValues.length - topValues.length} more values omitted)`,
      );
    }
  }

  console.log("");
  console.log("Grouped summaries:");

  if (statusSummaryLines.length > 0) {
    console.log("");
    statusSummaryLines.forEach((line) => console.log(line));
  }

  if (ownerSummaryLines.length > 0) {
    console.log("");
    console.log("Owners:");
    ownerSummaryLines.forEach((line) => console.log(line));
  }

  if (teamSummaryLines.length > 0) {
    console.log("");
    console.log("Teams:");
    teamSummaryLines.forEach((line) => console.log(line));
  }

  if (metadataSummaryLines.length > 0) {
    console.log("");
    console.log("Metadata aggregates:");
    metadataSummaryLines.forEach((line) => console.log(line));
  }
}

main().catch((error) => {
  console.error("Failed to compute Morph instance stats:", error);
  process.exitCode = 1;
});
