/** Public API namespace used by new clients. The Worker rewrites this to the
 * existing handler paths before forwarding to a Durable Object. */
export function normalizePublicPath(pathname: string): string {
  if (!pathname.startsWith("/v2/")) return pathname;
  if (pathname.startsWith("/v2/api/")) return pathname.slice(3);
  return `/v1${pathname.slice(3)}`;
}
