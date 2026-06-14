// Pure encoder for the cmux iOS attach deep link.
//
// Takes the raw payload returned by the `mobile.attach_ticket.create` RPC
// (`{ ticket: { routes, version, ... }, ... }`), optionally filters the ticket
// routes by id/kind, base64url-encodes the (filtered) ticket, and builds the
// `cmux-ios://attach?v=<n>&payload=<b64>` URL the phone consumes.
//
// This is the single source of truth for the encode recipe, shared by
// `scripts/mobile-attach-qr.sh` (QR/HTML rendering) and `scripts/dev-setup.sh`
// (headless auto-pair mint). Keep it pure (no I/O) so it is unit-testable with
// `node --test scripts/lib/attach-url.test.mjs`.

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
 * Build the `cmux-ios://attach` deep link from a raw attach-ticket payload.
 *
 * The returned `attachURL` is a bearer credential: it grants the holder the
 * paired Mac's terminals for the ticket's TTL. Never log it.
 *
 * @param {object} payload The raw `mobile.attach_ticket.create` result.
 * @param {{routeID?: string, routeKind?: string}} [filter]
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

  const routes = filterRoutes(payload.ticket.routes, filter);

  const ticket = { ...payload.ticket, routes };
  const result = { ...payload, ticket, routes };

  const encodedPayload = Buffer.from(JSON.stringify(ticket)).toString(
    "base64url",
  );
  const version = ticket.version || 1;
  result.attach_url = `cmux-ios://attach?v=${version}&payload=${encodedPayload}`;

  return { attachURL: result.attach_url, routes, payload: result };
}
