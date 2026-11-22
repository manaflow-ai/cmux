import { redirect } from "@tanstack/react-router";

/**
 * `/dashboard/team` used to host Hexclave's `<AccountSettings />`, which
 * addressed pages with URL hashes. Stack emails and old bookmarks still link
 * there, so the route maps the hash to the matching cmux route.
 */
const SECTION_REDIRECTS = {
  profile: () => redirect({ to: "/dashboard/settings", replace: true }),
  auth: () => redirect({ to: "/dashboard/settings/auth", replace: true }),
  notifications: () => redirect({ to: "/dashboard/settings/notifications", replace: true }),
  sessions: () => redirect({ to: "/dashboard/settings/sessions", replace: true }),
  "api-keys": () => redirect({ to: "/dashboard/settings/api-keys", replace: true }),
  settings: () => redirect({ to: "/dashboard/settings/account", replace: true }),
  payments: () => redirect({ to: "/dashboard/billing", replace: true }),
} as const;

/** The redirect for a legacy hash, with or without the leading `#`. */
export function legacyTeamHashRedirect(hash: string) {
  const key = decodeHashKey(hash);
  if (key === "team-creation") return redirect({ to: "/dashboard/teams/new", replace: true });
  if (key.startsWith("team-") && key.length > "team-".length) {
    return redirect({
      to: "/dashboard/teams/$teamId",
      params: { teamId: key.slice("team-".length) },
      replace: true,
    });
  }
  if (Object.hasOwn(SECTION_REDIRECTS, key)) {
    return SECTION_REDIRECTS[key as keyof typeof SECTION_REDIRECTS]();
  }
  return SECTION_REDIRECTS.profile();
}

function decodeHashKey(hash: string): string {
  const raw = hash.startsWith("#") ? hash.slice(1) : hash;
  try {
    return decodeURIComponent(raw).trim();
  } catch {
    return "";
  }
}
