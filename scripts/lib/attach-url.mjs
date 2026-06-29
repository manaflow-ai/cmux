// Pure encoder for the cmux iOS attach deep link.
//
// Takes the raw payload returned by the `mobile.attach_ticket.create` RPC
// (`{ ticket: { routes, version, ... }, ... }`), optionally filters the ticket
// routes by id/kind, base64url-encodes the (filtered) ticket, and builds the
// `<scheme>://attach?v=<n>&payload=<b64>` URL the phone consumes.
//
// The scheme is channel-specific, mirroring `CmxPairingURLScheme` in
// `Packages/Shared/CMUXMobileCore`: development builds register and emit
// `cmux-ios-dev`, Release (TestFlight beta + App Store) emit `cmux-ios`. Both
// callers here are dev-only (the debug-CLI QR renderer and the headless
// dev-setup auto-pair mint), so the default is the dev scheme: a QR rendered by
// `mobile-attach-qr.sh` must route to the dev iOS build when scanned with the
// system Camera, not to an installed TestFlight/App Store build.
//
// This is the single source of truth for the encode recipe, shared by
// `scripts/mobile-attach-qr.sh` (QR/HTML rendering) and `scripts/dev-setup.sh`
// (headless auto-pair mint). Keep it pure (no I/O) so it is unit-testable with
// `node --test scripts/lib/attach-url.test.mjs`.

/** The pairing/attach URL scheme development (DEBUG/tagged) builds emit. */
export const DEV_URL_SCHEME = "cmux-ios-dev";

/** The pairing/attach URL scheme Release (beta + prod) builds emit. */
export const RELEASE_URL_SCHEME = "cmux-ios";

/**
 * Filter a ticket's routes by id and/or kind. Returns the matching subset.
 *
 * @param {Array<object>} routes Ticket routes.
 * @param {{routeID?: string, routeKind?: string}} [filter]
 * @returns {Array<object>} The matching routes (all routes when no filter).
 * @throws {Error} When a filter is given but matches nothing.
 */
export function filterRoutes(routes, { routeID = "", routeKind = "" } = {}) {
  const id = String(routeID || "").trim();
  const kind = String(routeKind || "").trim();
  let filtered = routes;
  if (id) {
    filtered = filtered.filter((route) => route.id === id);
  }
  if (kind) {
    filtered = filtered.filter((route) => route.kind === kind);
  }
  if (filtered.length === 0) {
    throw new Error(
      `No matching route for route_id=${id || "(none)"} route_kind=${kind || "(none)"}`,
    );
  }
  return filtered;
}

/**
 * Build the `<scheme>://attach` deep link from a raw attach-ticket payload.
 *
 * When the Mac returns a canonical `attach_url`, this preserves that
 * non-secret ticket-reference URL. When the caller locally filters routes and
 * this module reconstructs the legacy v1 payload, the returned `attachURL`
 * includes the bearer ticket and must not be logged.
 *
 * @param {object} payload The raw `mobile.attach_ticket.create` result.
 * @param {{routeID?: string, routeKind?: string, scheme?: string}} [filter]
 *   `scheme` is the channel-specific URL scheme (default ``DEV_URL_SCHEME`` so a
 *   dev-rendered QR routes to the dev iOS build via the system Camera).
 * @returns {{attachURL: string, routes: Array<object>, payload: object}}
 *   `payload` is a shallow clone with `ticket.routes`/`routes` narrowed to the
 *   filtered set, so callers (e.g. the QR HTML renderer) can show the addresses.
 * @throws {Error} When the payload has no ticket/routes, or the filter is empty.
 */
export function buildAttachURL(payload, filter = {}) {
  if (!payload || !payload.ticket || !Array.isArray(payload.ticket.routes)) {
    throw new Error(
      "mobile.attach_ticket.create did not return a ticket with routes",
    );
  }

  const { routeID, routeKind, scheme = DEV_URL_SCHEME } = filter;
  const routes = filterRoutes(payload.ticket.routes, { routeID, routeKind });

  const ticket = { ...payload.ticket, routes };
  const result = { ...payload, ticket, routes };

  // Newer Mac builds return the canonical pairing URL from the Swift ticket
  // store. Prefer it when the caller did not narrow the route set locally:
  // the Swift path may emit the v2 bare-route QR grammar, while this JS module
  // can only reconstruct the older v1 JSON payload. If a caller filters an
  // unfiltered payload locally, the canonical URL may point at a different
  // route set, so fall through to the lossless v1 reconstruction.
  if (
    typeof payload.attach_url === "string" &&
    isCanonicalAttachURL(payload.attach_url, routes.length) &&
    routes.length === payload.ticket.routes.length
  ) {
    result.attach_url = payload.attach_url;
    return { attachURL: result.attach_url, routes, payload: result };
  }

  const encodedPayload = Buffer.from(JSON.stringify(ticket)).toString(
    "base64url",
  );
  const version = ticket.version || 1;
  result.attach_url = `${scheme}://attach?v=${version}&payload=${encodedPayload}`;

  return { attachURL: result.attach_url, routes, payload: result };
}

function isCanonicalAttachURL(value, expectedRouteCount) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (
    url.protocol !== `${RELEASE_URL_SCHEME}:` &&
    url.protocol !== `${DEV_URL_SCHEME}:`
  ) {
    return false;
  }
  if (url.hostname !== "attach") {
    return false;
  }
  const params = url.searchParams;
  const ticketRef = params.get("tr")?.trim() ?? "";
  return (
    params.get("v") === "2" &&
    ticketRef.length > 0 &&
    !params.has("payload") &&
    params.getAll("r").length === expectedRouteCount
  );
}
