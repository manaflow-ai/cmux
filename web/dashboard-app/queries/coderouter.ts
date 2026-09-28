import { queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import type { DashboardCoderouterResponse } from "../lib/coderouter-types";
import { dashboardFetch } from "../lib/api";

export type * from "../lib/coderouter-types";

const nullableString = z.string().nullable();

const claudeAccountSchema = z.object({
  id: z.string(),
  kind: z.enum(["anthropic_api_key", "anthropic_oauth", "bedrock"]),
  label: z.string(),
  visibility: z.enum(["private", "team"]).optional(),
  createdBy: z.string().optional(),
  identifier: z.string(),
  region: nullableString,
  modelIds: z.record(z.string(), z.string()),
  state: z.enum(["active", "disabled"]),
  cooldownUntil: nullableString,
  lastFailureCode: nullableString,
  lastUsedAt: nullableString,
  createdAt: z.string(),
  updatedAt: z.string(),
});

const nativeAccountSchema = z.object({
  visibility: z.enum(["private", "team"]).optional(),
  createdBy: nullableString.optional(),
  id: z.string(),
  provider: z.enum(["codex", "opencode-go", "openai-apikey", "openrouter-apikey"]),
  providerAccountId: z.string(),
  providerUserId: z.string().optional(),
  label: z.string(),
  state: z.enum(["active", "refreshing", "expired", "broken"]),
  credentialExpiresAt: nullableString,
  lastFailureCode: nullableString,
  cooldownUntil: nullableString,
  activeSessions: z.number(),
});

const sharedAccountSchema = z.object({
  id: z.string(),
  kind: z.string(),
  label: nullableString.optional(),
  createdAt: z.string().optional(),
  health: z.object({ ok: z.boolean(), message: z.string().optional() }).optional(),
});

const metricsTotalsSchema = z.object({
  inputTokens: z.number(),
  cachedInputTokens: z.number(),
  outputTokens: z.number(),
  totalTokens: z.number(),
  apiEquivalentUsd: z.number(),
  pricedTokens: z.number(),
  unpricedTokens: z.number(),
});

const metricsSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("unavailable") }),
  z.object({
    kind: z.literal("ready"),
    periodDays: z.number(),
    generatedAt: z.string(),
    rateCardVersion: z.string(),
    totals: metricsTotalsSchema,
    daily: z.array(z.object({ day: z.string(), totalTokens: z.number(), apiEquivalentUsd: z.number() })),
  }),
]);

const machineSchema = z.object({
  vmId: z.string(),
  providerVmId: nullableString,
  displayName: nullableString,
  totals: z.object({
    inputTokens: z.number(),
    cachedInputTokens: z.number(),
    outputTokens: z.number(),
    totalTokens: z.number(),
    apiEquivalentUsd: z.number(),
  }),
});

const errorState = z.object({ kind: z.literal("error") });

export const coderouterResponseSchema = z.object({
  selectedTeam: z.object({
    id: z.string(),
    name: z.string(),
    use: z.boolean(),
    manageAccounts: z.boolean(),
    manageApiKeys: z.boolean(),
    personal: z.boolean(),
  }),
  transferTeams: z.array(z.object({ id: z.string(), name: z.string() })),
  viewerUserId: z.string(),
  metrics: metricsSchema,
  machineUsage: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("unavailable"), periodDays: z.number() }),
    z.object({ kind: z.literal("ready"), periodDays: z.number(), machines: z.array(machineSchema) }),
  ]),
  claude: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("ok"), accounts: z.array(claudeAccountSchema) }),
    errorState,
  ]),
  native: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("ok"), accounts: z.array(nativeAccountSchema) }),
    errorState,
  ]),
  shared: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("ok"), accounts: z.array(sharedAccountSchema) }),
    z.object({ kind: z.literal("migrationPending") }),
    z.object({ kind: z.literal("notConfigured") }),
    errorState,
  ]),
}) satisfies z.ZodType<DashboardCoderouterResponse>;

/** Prefix of every coderouter overview query; mutations invalidate it. */
export const coderouterQueryRoot = ["dashboard", "coderouter"] as const;

/**
 * The overview for `team` (the `?team=` search param), or the Stack-selected
 * team when absent. Team grants are checked on every fetch, so it is always
 * refetched on mount.
 */
export function coderouterOverviewQuery(team: string | undefined) {
  const search = team ? `?${new URLSearchParams({ team })}` : "";
  return queryOptions({
    queryKey: [...coderouterQueryRoot, "overview", team ?? null] as const,
    queryFn: ({ signal }): Promise<DashboardCoderouterResponse> =>
      dashboardFetch(`/api/dashboard/coderouter${search}`, coderouterResponseSchema, { signal }),
    staleTime: 0,
    retry: false,
  });
}

/** API keys load beside the overview, so a slow key list never blocks the page. */
export function coderouterApiKeysQueryKey(teamId: string) {
  return [...coderouterQueryRoot, "api-keys", teamId] as const;
}
