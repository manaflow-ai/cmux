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

/// The class a revealed turn's row wears for a moment (cc-pane-transcript owns its look).
export const REVEALED_TURN_CLASS = "acpmux-turn-revealed";
/// How long a revealed row keeps the class.
export const REVEALED_TURN_MS = 1600;
/// How long a link's turn is waited for before the page gives up quietly: the row renders once the
/// session attaches, which a new tab's first connect can take a moment for.
export const REVEAL_WAIT_MS = 5000;
const REVEAL_POLL_MS = 100;

/// Scrolls the transcript row of turn `turnId` (`data-turn-id`) into view and marks it briefly.
/// False, and nothing moves, when no row carries that turn.
export function scrollToTurn(turnId: string, root: ParentNode = document): boolean {
  for (const row of root.querySelectorAll<HTMLElement>("[data-turn-id]")) {
    if (row.dataset.turnId !== turnId) continue;
    row.scrollIntoView({ block: "center" });
    row.classList.add(REVEALED_TURN_CLASS);
    setTimeout(() => row.classList.remove(REVEALED_TURN_CLASS), REVEALED_TURN_MS);
    return true;
  }
  return false;
}

let pendingReveal: (() => void) | undefined;

/// Scrolls to turn `turnId` once its row renders: now when it is there, else as soon as it appears,
/// giving up quietly after `waitMs`. A later reveal replaces a pending one. Resolves whether it
/// scrolled.
export function revealTurnWhenShown(
  turnId: string,
  root: ParentNode = document,
  { waitMs = REVEAL_WAIT_MS, pollMs = REVEAL_POLL_MS }: { waitMs?: number; pollMs?: number } = {},
): Promise<boolean> {
  pendingReveal?.();
  return new Promise((resolve) => {
    const deadline = Date.now() + waitMs;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (revealed: boolean) => {
      if (timer !== undefined) clearTimeout(timer);
      if (pendingReveal === cancel) pendingReveal = undefined;
      resolve(revealed);
    };
    const cancel = () => finish(false);
    const attempt = () => {
      timer = undefined;
      if (scrollToTurn(turnId, root)) finish(true);
      else if (Date.now() >= deadline) finish(false);
      else timer = setTimeout(attempt, pollMs);
    };
    pendingReveal = cancel;
    attempt();
  });
}
