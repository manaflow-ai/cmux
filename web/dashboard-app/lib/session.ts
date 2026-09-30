import { queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import { vaultSignInHref, localizedVaultPath } from "@/app/lib/vault-auth";
import { dashboardFetch } from "./api";
import type { DashboardSessionResponse } from "./session-types";

const sessionSchema = z.object({
  user: z.object({
    id: z.string(),
    displayName: z.string().nullable(),
    primaryEmail: z.string().nullable(),
    primaryEmailVerified: z.boolean(),
    profileImageUrl: z.string().nullable(),
    selectedTeamId: z.string().nullable(),
  }),
  flags: z.object({ vaultEnabled: z.boolean() }),
}) satisfies z.ZodType<DashboardSessionResponse>;

export const sessionQuery = queryOptions({
  queryKey: ["dashboard", "session"] as const,
  queryFn: ({ signal }) => dashboardFetch("/api/dashboard/session", sessionSchema, { signal }),
  staleTime: 5 * 60_000,
  retry: false,
});

/** Full-page navigation to sign-in that returns to `path` afterwards. */
export function signInHref(locale: string, path: string): string {
  return vaultSignInHref(localizedVaultPath(locale, path));
}
