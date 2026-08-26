function plainRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

/**
 * Server-side route publication policy. The iroh transport is retired, but old
 * released Macs still publish `kind: "iroh"` routes whose endpoint bodies can
 * carry private direct-address path hints; those entries are dropped at every
 * boundary so they are never stored or fanned out. Every other route kind
 * passes through unchanged (route semantics stay client-owned).
 */
export function sanitizePublishedRoutes(
  routes: readonly unknown[] | undefined,
): Record<string, unknown>[] | undefined {
  if (routes === undefined) return undefined;
  const published: Record<string, unknown>[] = [];
  for (const value of routes) {
    const route = plainRecord(value);
    if (!route) continue;
    if (route.kind === "iroh") continue;
    published.push(route);
  }
  return published;
}
