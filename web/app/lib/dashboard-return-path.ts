/**
 * Middleware forwards the destination of a dashboard request to the server
 * layout. Keeping this value in a request header lets the shared auth gate
 * preserve the page (and its query string) without trusting a user-supplied
 * redirect target.
 */
export const DASHBOARD_RETURN_PATH_HEADER = "x-cmux-dashboard-return-path";

const DASHBOARD_PREFIX = "/dashboard";
const MAX_RETURN_PATH_LENGTH = 2_048;

export function dashboardReturnPathForRequest(
  pathname: string,
  search: string,
  locales: readonly string[],
): string | null {
  const segments = pathname.split("/").filter(Boolean);
  if (segments.length === 0) return null;

  const first = segments[0];
  const dashboardIndex = locales.includes(first) ? 1 : 0;
  if (segments[dashboardIndex] !== "dashboard") return null;

  const path = `/${segments.slice(dashboardIndex).join("/")}`;
  if (!isDashboardReturnPath(path)) return null;
  return `${path}${search.startsWith("?") ? search : ""}`;
}

/** Return a safe, dashboard-local path or the supplied fallback. */
export function normalizeDashboardReturnPath(
  value: string | null | undefined,
  fallback = DASHBOARD_PREFIX,
): string {
  if (
    !value ||
    value.length > MAX_RETURN_PATH_LENGTH ||
    !value.startsWith("/") ||
    value.startsWith("//")
  ) return fallback;

  try {
    // Parsing against an inert origin gives us normalized pathname and query
    // components while the checks above keep the value relative.
    const parsed = new URL(value, "https://cmux.invalid");
    if (parsed.origin !== "https://cmux.invalid") return fallback;
    const path = `${parsed.pathname}${parsed.search}`;
    return isDashboardReturnPath(path) ? path : fallback;
  } catch {
    return fallback;
  }
}

function isDashboardReturnPath(value: string): boolean {
  return value === DASHBOARD_PREFIX ||
    value.startsWith(`${DASHBOARD_PREFIX}/`);
}
