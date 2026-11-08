import {
  MANAGED_IROH_RELAY_CATALOG,
  MANAGED_IROH_RELAY_URLS,
} from "./generated/managedRelayCatalog";

// Exact URLs are intentional: arbitrary relay URLs remain endpoint-local.
export const APPROVED_IROH_RELAY_CATALOG = MANAGED_IROH_RELAY_CATALOG;
export const APPROVED_IROH_RELAY_CATALOG_SEQUENCE =
  MANAGED_IROH_RELAY_CATALOG.sequence;
export const APPROVED_IROH_RELAY_URLS = MANAGED_IROH_RELAY_URLS;

const APPROVED_IROH_RELAY_URL_SET: ReadonlySet<string> = new Set(APPROVED_IROH_RELAY_URLS);
const ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
const MAX_ROUTE_ID_LENGTH = 256;

function plainRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function sanitizeIrohRoute(route: Record<string, unknown>): Record<string, unknown> | null {
  const routeId = typeof route.id === "string" ? route.id : "";
  const endpoint = plainRecord(route.endpoint);
  const endpointId = endpoint?.id;
  if (
    routeId.length === 0 ||
    routeId.length > MAX_ROUTE_ID_LENGTH ||
    endpoint?.type !== "peer" ||
    typeof endpointId !== "string" ||
    !ENDPOINT_ID_RE.test(endpointId)
  ) {
    return null;
  }

  const publicEndpoint: Record<string, unknown> = { type: "peer", id: endpointId };
  if (
    typeof endpoint.relay_url === "string" &&
    APPROVED_IROH_RELAY_URL_SET.has(endpoint.relay_url)
  ) {
    publicEndpoint.relay_url = endpoint.relay_url;
  }

  const published: Record<string, unknown> = {
    id: routeId,
    kind: "iroh",
    endpoint: publicEndpoint,
  };
  if (typeof route.priority === "number" && Number.isSafeInteger(route.priority)) {
    published.priority = route.priority;
  }
  return published;
}

/**
 * Server-side route publication policy. Iroh direct/private coordinates and
 * opaque relay hints stay endpoint-local. Legacy route kinds pass through
 * unchanged until their existing clients can migrate to a typed policy.
 */
export function sanitizePublishedRoutes(
  routes: readonly unknown[] | undefined,
): Record<string, unknown>[] | undefined {
  if (routes === undefined) return undefined;
  const published: Record<string, unknown>[] = [];
  for (const value of routes) {
    const route = plainRecord(value);
    if (!route) continue;
    if (route.kind !== "iroh") {
      published.push(route);
      continue;
    }
    const sanitized = sanitizeIrohRoute(route);
    if (sanitized) published.push(sanitized);
  }
  return published;
}
