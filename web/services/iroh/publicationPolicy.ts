/**
 * Server publication policy for Iroh rendezvous data.
 *
 * Public surfaces expose only a verified Iroh EndpointID and an exact managed
 * relay URL. The authenticated same-account broker may additionally exchange a
 * bounded public direct address or an exact relay already saved by that account.
 * Private LAN and VPN coordinates never reach a server surface.
 */

import {
  MANAGED_IROH_RELAY_CATALOG,
  MANAGED_IROH_RELAY_URLS,
} from "../relay/generated/managedRelayCatalog";

export const MANAGED_RELAY_CATALOG_SEQUENCE = MANAGED_IROH_RELAY_CATALOG.sequence;
export const MANAGED_RELAY_URLS = MANAGED_IROH_RELAY_URLS;

const MANAGED_RELAY_URL_SET: ReadonlySet<string> = new Set(MANAGED_RELAY_URLS);
const ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
const MAX_ROUTE_ID_LENGTH = 256;

type PathHintLike = {
  readonly kind: string;
  readonly value: string;
  readonly source?: string;
  readonly privacy_scope?: string;
};

/** Keep only endpoint-reported managed relay URLs for server persistence. */
export function serverPublishedIrohPathHints<T extends PathHintLike>(
  hints: readonly T[],
): T[] {
  return hints.filter((hint) =>
    hint.kind === "relay_url" && MANAGED_RELAY_URL_SET.has(hint.value));
}

/**
 * Keep only routes safe for the authenticated same-account broker.
 *
 * An arbitrary endpoint-reported relay URL is never authoritative. Custom
 * relays must match the account's saved metadata exactly. Direct addresses are
 * limited to native public-internet candidates; LAN, Tailscale, and other VPN
 * coordinates remain endpoint-local and are exchanged by Iroh only after peer
 * admission.
 */
export function accountPrivateIrohPathHints<T extends PathHintLike>(
  hints: readonly T[],
  savedCustomRelayURLs: ReadonlySet<string>,
): T[] {
  return hints.filter((hint) => {
    if (hint.kind === "relay_url") {
      return MANAGED_RELAY_URL_SET.has(hint.value) || savedCustomRelayURLs.has(hint.value);
    }
    return hint.kind === "direct_address" &&
      hint.source === "native" &&
      hint.privacy_scope === "public_internet";
  });
}

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
  if (typeof endpoint.relay_url === "string" && MANAGED_RELAY_URL_SET.has(endpoint.relay_url)) {
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
 * Sanitize route bodies before persistence or publication. Invalid Iroh routes
 * are dropped because their EndpointID cannot be authenticated or dialed.
 */
export function sanitizeServerPublishedRoutes(routes: readonly unknown[]): Record<string, unknown>[] {
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
