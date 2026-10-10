/**
 * cmux.com/i/<code>: the short, trusted home of Home invite links
 * (plans/cmux-next/home-messaging.md, decision D-H1). The code names the
 * conversation (`g`/`d` + 26 base32 characters); the secret is in the URL
 * fragment, which never reaches this server. Until the accept flow moves
 * here, the page shows a link preview card and forwards the browser to the
 * cmux Cloud accept page with the fragment intact.
 */
export const INVITE_CODE = /^[dg][0-9A-HJKMNP-TV-Z]{26}$/;
export const INVITE_SECRET = /^[0-9A-HJKMNP-TV-Z]{26}$/;

export const isInviteCode = (code: string): boolean => INVITE_CODE.test(code);

const DEFAULT_ACCEPT_ORIGIN = "https://console.cmux.dev";

/** The accept page's origin: `HOME_INVITE_ACCEPT_ORIGIN` when it is a bare https origin, else production. */
export function acceptOrigin(value: string | undefined = process.env.HOME_INVITE_ACCEPT_ORIGIN): string {
  if (!value) return DEFAULT_ACCEPT_ORIGIN;
  try {
    const url = new URL(value);
    if (url.protocol === "https:" && url.pathname === "/" && !url.search && !url.hash) {
      return url.origin;
    }
  } catch {}
  return DEFAULT_ACCEPT_ORIGIN;
}

/** Where the browser goes: the same code, and the secret fragment only when it is well formed. */
export function forwardUrl(origin: string, code: string, hash: string): string | null {
  if (!isInviteCode(code)) return null;
  const secret = hash.startsWith("#") ? hash.slice(1) : hash;
  return `${origin}/i/${code}${INVITE_SECRET.test(secret) ? `#${secret}` : ""}`;
}

export const INVITE_TITLE = "You're invited to a conversation on cmux";
export const INVITE_DESCRIPTION =
  "Tap to open it. cmux is where people and their AI agents work together.";
export const INVITE_IMAGE = "https://cmux.com/opengraph-image";
