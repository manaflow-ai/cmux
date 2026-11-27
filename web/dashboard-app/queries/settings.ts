import { useQueryClient } from "@tanstack/react-query";
import { rpc } from "../lib/rpc";

export type {
  SettingsApiKey,
  SettingsEmail,
  SettingsNotificationCategory,
  SettingsOAuthProvider,
  SettingsOverview,
  SettingsSession,
} from "@/orpc/server/dashboard/settings";

/** Project sign-in flags and the user's emails. */
export const settingsOverviewQuery = rpc.settings.overview.queryOptions();

export const settingsNotificationsQuery = rpc.settings.notifications.queryOptions();

/** Sessions change when the user signs in elsewhere, so they are refetched on mount. */
export const settingsSessionsQuery = rpc.settings.sessions.queryOptions({ staleTime: 0 });

export const settingsApiKeysQuery = rpc.settings.apiKeys.queryOptions();

export const settingsOAuthProvidersQuery = rpc.settings.oauthProviders.queryOptions();

/**
 * Settings writes run on the Hexclave client SDK with the user's own session
 * (Hexclave applies its user-level rules there). Call this after a write so
 * the prefetched oRPC reads show the change.
 */
export function useRefreshSettings(): () => Promise<void> {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: rpc.settings.key() });
}
