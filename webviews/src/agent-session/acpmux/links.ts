/// cmux:// links the page copies (the deep links contract). The host hands over this build's URL
/// scheme in the handshake (`linkScheme`, with the other bootstrap values); the page never hardcodes
/// `cmux://`, so a tagged build copies links that open in itself.

/// The Release scheme, for the mock page that runs without a cmux host.
export const FALLBACK_LINK_SCHEME = "cmux";

/// Sets the scheme from the host's handshake value, or `fallback` when it sent none.
export function setLinkScheme(value: unknown, fallback?: string): void {
  void value;
  void fallback;
}

/// The scheme links are written in, or undefined before the host sent one.
export function linkScheme(): string | undefined {
  return undefined;
}

/// `<scheme>://session/<sessionId>[#turn-<turnId>]`, or undefined without a scheme or for an id a
/// link cannot carry.
export function sessionLink(sessionId: string, turnId?: string): string | undefined {
  void sessionId;
  void turnId;
  return undefined;
}

/// Scrolls the transcript row of turn `turnId` (`data-turn-id`) into view. False, and nothing
/// moves, when no row carries that turn.
export function scrollToTurn(turnId: string, root: ParentNode = document): boolean {
  void turnId;
  void root;
  return false;
}
