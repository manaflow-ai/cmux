export const poweredByHeader = false;

/**
 * Content-Security-Policy. Restrictive baseline applied to every route via
 * `next.config.ts` `headers()` (so Stack Auth handler routes and all others are
 * covered, not just proxied HTML).
 *
 * `script-src 'self' 'unsafe-inline'` blocks external-origin script injection
 * (the primary XSS vector) while allowing the app's own inline scripts (Next
 * hydration, the first-paint theme bootstrap). A per-request nonce would be
 * stricter against inline injection, but there is no current inline-injection
 * path and nonce threading through the next-intl proxy is unreliable, so this
 * static policy is the robust baseline. `style-src 'unsafe-inline'` covers
 * Shiki per-token color styles and Next-injected styles (not a script risk).
 *
 * `connect-src` is scoped to same-origin plus the PostHog ingest host
 * (api_host https://r.cmux.com); the web client has no other cross-origin
 * XHR/WS. `img-src` covers next/image (github.com) and GitHub avatars.
 */
export const contentSecurityPolicy = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "connect-src 'self' https://r.cmux.com",
  "img-src 'self' data: https://github.com https://avatars.githubusercontent.com",
  "font-src 'self' data:",
  "base-uri 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
].join("; ");

export const securityHeaders = [
  { key: "Content-Security-Policy", value: contentSecurityPolicy },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()" },
];

export const securityHeaderRules = [
  {
    source: "/:path*",
    headers: securityHeaders,
  },
];
