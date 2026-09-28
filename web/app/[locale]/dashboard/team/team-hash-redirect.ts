/**
 * `/dashboard/team` used to host Hexclave's `<AccountSettings />`, which
 * addressed pages with URL hashes. The hash never reaches the server, so the
 * route maps it on the client to the matching cmux settings route.
 */
const SECTION_ROUTES: Record<string, string> = {
  profile: "/dashboard/settings",
  auth: "/dashboard/settings/auth",
  notifications: "/dashboard/settings/notifications",
  sessions: "/dashboard/settings/sessions",
  "api-keys": "/dashboard/settings/api-keys",
  settings: "/dashboard/settings/account",
  payments: "/dashboard/billing",
};

export const DEFAULT_SETTINGS_ROUTE = "/dashboard/settings";

export function settingsRouteForHash(hash: string): string {
  const raw = hash.startsWith("#") ? hash.slice(1) : hash;
  let key: string;
  try {
    key = decodeURIComponent(raw).trim();
  } catch {
    return DEFAULT_SETTINGS_ROUTE;
  }
  if (key === "team-creation") return "/dashboard/teams/new";
  if (key.startsWith("team-") && key.length > "team-".length) {
    return `/dashboard/teams/${encodeURIComponent(key.slice("team-".length))}`;
  }
  return Object.hasOwn(SECTION_ROUTES, key) ? SECTION_ROUTES[key] : DEFAULT_SETTINGS_ROUTE;
}
