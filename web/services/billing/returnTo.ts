import { locales } from "../../i18n/routing";

const MAX_RETURN_PATH_LENGTH = 200;
const SAFE_SEGMENT = /^[A-Za-z0-9._~-]+$/;

/**
 * The dashboard page a checkout returns to: a same-origin `/dashboard` path,
 * optionally behind a supported locale prefix. Query and fragment are
 * dropped, and every segment must be plain URL-safe text, so an encoded
 * slash, a dot segment, or a control character can never widen it into an
 * open redirect or reach an API route. Anything else is null.
 */
export function dashboardReturnPath(value: string | null | undefined): string | null {
  if (!value || value.length > MAX_RETURN_PATH_LENGTH) return null;
  if (!value.startsWith("/") || value.startsWith("//")) return null;
  const path = value.split(/[?#]/, 1)[0]!;
  const segments = path.slice(1).split("/");
  if (segments.some((segment) => !SAFE_SEGMENT.test(segment) || segment === "." || segment === "..")) return null;
  const dashboardIndex = (locales as readonly string[]).includes(segments[0]!) ? 1 : 0;
  if (segments[dashboardIndex] !== "dashboard") return null;
  return path;
}
