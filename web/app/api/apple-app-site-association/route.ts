/**
 * The Apple App Site Association file, served at
 * `/.well-known/apple-app-site-association` (next.config.ts rewrites it here).
 * It lets the cmux iOS app open cmux.com's agent links
 * (`/deeplink/agent?harness=&session=`) directly, as universal links, instead
 * of in Safari. A link is an address, not a credential: the app opens only a
 * session the person's own Mac already shows (schemas/deeplinks/agent-link.json).
 * Without the app installed the page loads as before.
 */

/** Apple team `7WLXT3NR37`, app "cmux INTERNAL" (the cmux-next iOS TestFlight build). */
const APP_IDS = ["7WLXT3NR37.dev.cmux.app.internal"];

/** The agent link page, bare and under a locale prefix (`/ja/deeplink/agent`). */
const COMPONENTS = [{ "/": "/deeplink/agent" }, { "/": "/*/deeplink/agent" }];

export function appleAppSiteAssociation() {
  return { applinks: { details: [{ appIDs: APP_IDS, components: COMPONENTS }] } };
}

export function GET() {
  return Response.json(appleAppSiteAssociation(), {
    headers: { "Cache-Control": "public, max-age=3600" },
  });
}
