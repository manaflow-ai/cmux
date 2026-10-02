/// cmux:// links the page copies (the deep links contract). The host hands over this build's URL
/// scheme in the handshake (`linkScheme`, with the other bootstrap values); the page never hardcodes
/// `cmux://`, so a tagged build copies links that open in itself.

/// The Release scheme, for the mock page that runs without a cmux host.
export const FALLBACK_LINK_SCHEME = "cmux";

/// An RFC 3986 scheme.
const SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*$/;
/// What a link can carry as a session or turn id (CmuxNextActions `DeepLink`): nothing to escape.
const TOKEN = /^[A-Za-z0-9._-]{1,200}$/;

let scheme: string | undefined;

/// Sets the scheme from the host's handshake value, or `fallback` when it sent none.
export function setLinkScheme(value: unknown, fallback?: string): void {
  scheme = typeof value === "string" && SCHEME.test(value) ? value : fallback;
}

/// The scheme links are written in, or undefined before the host sent one.
export function linkScheme(): string | undefined {
  return scheme;
}

/// `<scheme>://session/<sessionId>[#turn-<turnId>]`, or undefined without a scheme or for an id a
/// link cannot carry.
export function sessionLink(sessionId: string, turnId?: string): string | undefined {
  if (!scheme || !TOKEN.test(sessionId)) return undefined;
  if (turnId === undefined) return `${scheme}://session/${sessionId}`;
  if (!TOKEN.test(turnId)) return undefined;
  return `${scheme}://session/${sessionId}#turn-${turnId}`;
}

/// Scrolls the transcript row of turn `turnId` (`data-turn-id`) into view. False, and nothing
/// moves, when no row carries that turn.
export function scrollToTurn(turnId: string, root: ParentNode = document): boolean {
  for (const row of root.querySelectorAll<HTMLElement>("[data-turn-id]")) {
    if (row.dataset.turnId !== turnId) continue;
    row.scrollIntoView({ block: "center" });
    return true;
  }
  return false;
}
