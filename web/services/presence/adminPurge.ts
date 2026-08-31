// Account-deletion presence purge: after the Aurora registry rows are gone,
// ask the presence worker (TeamPresence Durable Object) to drop the deleted
// user's live instance records and owner pins so team members do not keep
// seeing a ghost "online" Mac for up to the DO's 24h prune.
//
// Strictly best-effort: presence is display-only state that self-heals, so a
// worker outage must never fail or delay account deletion (which has already
// committed the authoritative deletes). Failures are logged and dropped.

import { after } from "next/server";
import { env } from "../../app/env";

// The purge fans out DO deletes and broadcasts, so allow more than the 750ms
// connectivity-invalidation budget; it runs after the response, where the only
// cost of a generous bound is holding the function alive slightly longer.
const PURGE_TIMEOUT_MS = 5_000;

/** Builds the exact backend-only worker purge request without performing I/O. */
export function buildPresenceAdminPurgeRequest(
  input: { readonly teamId: string; readonly userId: string },
  configuration: {
    readonly baseURL?: string;
    readonly purgeSecret?: string;
  } = {
    baseURL: env.CMUX_PRESENCE_BASE_URL,
    purgeSecret: env.PRESENCE_ADMIN_PURGE_SECRET,
  },
): Request | null {
  const { baseURL, purgeSecret } = configuration;
  if (!baseURL || !purgeSecret) return null;
  return new Request(new URL("/v1/admin/purge-user", baseURL), {
    method: "POST",
    headers: {
      authorization: `Bearer ${purgeSecret}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ teamId: input.teamId, userId: input.userId }),
  });
}

/**
 * Purge the deleted user's presence in every deletion-scoped team. Sequential
 * (one DO per team, tiny fan-out) and per-team isolated: one team's failure
 * must not skip the rest. Resolves without throwing in every case.
 */
export async function purgePresenceForDeletedAccount(
  input: {
    readonly userId: string;
    readonly teamIds: readonly string[];
  },
  dependencies: {
    readonly fetchResponse?: typeof fetch;
    readonly buildRequest?: typeof buildPresenceAdminPurgeRequest;
  } = {},
): Promise<void> {
  const buildRequest = dependencies.buildRequest ?? buildPresenceAdminPurgeRequest;
  const fetchResponse = dependencies.fetchResponse ?? fetch;
  for (const teamId of new Set(input.teamIds)) {
    if (!teamId) continue;
    try {
      const purge = buildRequest({ teamId, userId: input.userId });
      // Unconfigured presence worker (previews, local dev): nothing to purge.
      if (!purge) return;
      const controller = new AbortController();
      const timeout = setTimeout(
        () => controller.abort(new Error("presence_purge_timeout")),
        PURGE_TIMEOUT_MS,
      );
      try {
        const response = await fetchResponse(purge, { signal: controller.signal });
        if (!response.ok) throw new Error(`presence_purge_rejected_${response.status}`);
      } finally {
        clearTimeout(timeout);
      }
    } catch (error) {
      // Do not log tokens or the secret; the team id and failure class are
      // enough to correlate, and the DO's own prune bounds the ghost window.
      console.warn("account deletion presence purge failed", {
        teamId,
        failure: error instanceof Error ? error.message : "unknown",
      });
    }
  }
}

/**
 * Fire the purge without coupling it to the caller's control flow. Inside a
 * request `after` defers it past the response so worker round-trips cannot add
 * user-visible latency to account deletion; outside one (tests, scripts)
 * `after` throws and the purge runs fire-and-forget.
 */
export function schedulePresenceAccountPurge(input: {
  readonly userId: string;
  readonly teamIds: readonly string[];
}): void {
  const run = () => purgePresenceForDeletedAccount(input);
  try {
    after(run);
  } catch {
    void run();
  }
}
