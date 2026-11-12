import { rpc } from "../lib/rpc";

export type * from "../lib/coderouter-types";

/** Prefix of every coderouter overview query; mutations invalidate it. */
export const coderouterQueryRoot = rpc.coderouter.key();

/**
 * The overview for `team` (the `?team=` search param), or the Stack-selected
 * team when absent. Team grants are checked on every fetch, so it is always
 * refetched on mount.
 */
export function coderouterOverviewQuery(team: string | undefined) {
  return rpc.coderouter.overview.queryOptions({
    input: { team: team ?? null },
    staleTime: 0,
    retry: false,
  });
}

/** Coderouter account and API-key requests give up after this long. */
export const CODEROUTER_REQUEST_TIMEOUT_MS = 10_000;

/** API keys load beside the overview, so a slow key list never blocks the page. */
export function coderouterApiKeysQueryKey(teamId: string) {
  return rpc.coderouter.apiKeys.queryKey({ input: { teamId } });
}

export type { CoderouterApiKeySummary } from "@/orpc/server/dashboard/schemas/coderouter";

/**
 * The team's coderouter API keys. The team is part of the key, so a team
 * switch never shows the previous team's keys.
 */
export function coderouterApiKeysQuery(teamId: string) {
  return rpc.coderouter.apiKeys.queryOptions({
    input: { teamId },
    context: { timeoutMs: CODEROUTER_REQUEST_TIMEOUT_MS },
    select: (body) => body.keys,
    staleTime: 0,
    retry: false,
  });
}
