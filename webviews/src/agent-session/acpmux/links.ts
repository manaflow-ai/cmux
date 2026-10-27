/// cmux:// links the page copies (the deep links contract). The host hands over this build's URL
/// scheme in the handshake (`linkScheme`, with the other bootstrap values); the page never hardcodes
/// `cmux://`, so a tagged build copies links that open in itself.

/// The Release scheme, for the mock page that runs without a cmux host.
export const FALLBACK_LINK_SCHEME = "cmux";

/// An RFC 3986 scheme.
const SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*$/;
/// What a link can carry as a session or turn id (CmuxNextActions `DeepLink`): nothing to escape.
const TOKEN = /^[A-Za-z0-9._-]{1,200}$/;
/// What an outside harness can publish as its session id (DeepLink.isAgentSession).
export const AGENT_SESSION_TOKEN = /^(?!\.+$)[A-Za-z0-9._:-]{1,256}$/;

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

/// The `revealTurn` value that scrolls to and highlights one message: the harness message id
/// acpmux reports on the message's chunks (`agent_message_chunk.messageId`), which a
/// `cmux://agent/<harness>/<session>?message=<id>` link carries.
export const MESSAGE_REVEAL = "message:";

/// The message a reveal names, or undefined for a turn.
export const revealedMessage = (value: string) =>
  value.startsWith(MESSAGE_REVEAL) ? value.slice(MESSAGE_REVEAL.length) || undefined : undefined;

/// Scrolls `row` into view and marks it for a moment.
function markRow(row: HTMLElement): true {
  row.scrollIntoView({ block: "center" });
  row.classList.add(REVEALED_TURN_CLASS);
  setTimeout(() => row.classList.remove(REVEALED_TURN_CLASS), REVEALED_TURN_MS);
  return true;
}

/// Scrolls the transcript row of turn `turnId` (`data-turn-id`) into view and marks it briefly.
/// False, and nothing moves, when no row carries that turn.
export function scrollToTurn(turnId: string, root: ParentNode = document): boolean {
  for (const row of root.querySelectorAll<HTMLElement>("[data-turn-id]")) {
    if (row.dataset.turnId !== turnId) continue;
    return markRow(row);
  }
  return false;
}

/// Scrolls the transcript row `rowId` (`data-row-id`) into view and marks it briefly. False, and
/// nothing moves, when the row is not on screen. The copy a "Worked for" fold draws of the row
/// wears the same id with `:fold` after it (turns.ts), and is the same row to a reader.
export function scrollToRow(rowId: string, root: ParentNode = document): boolean {
  for (const row of root.querySelectorAll<HTMLElement>("[data-row-id]")) {
    if (row.dataset.rowId !== rowId && row.dataset.rowId !== `${rowId}:fold`) continue;
    return markRow(row);
  }
  return false;
}

/// Marks row `rowId` once the transcript draws it, which is not the frame it was asked for: the
/// transcript virtualizes its rows, so a row far from the view scrolls first and mounts after.
/// Gives up quietly when it never mounts, or when `stale` says the row's chat is no longer the one
/// on screen, leaving the view where it is. Returns the way to stop waiting, which is what keeps a
/// later reveal's reader from being pulled back to this row. A reader who only scrolls away inside
/// the wait is still taken to the row when it is drawn, as a reveal they asked for should.
function markWhenDrawn(
  rowId: string,
  root: ParentNode,
  {
    waitMs = REVEAL_WAIT_MS,
    pollMs = REVEAL_POLL_MS,
    stale,
  }: { waitMs?: number; pollMs?: number; stale?: () => boolean } = {},
): () => void {
  const deadline = Date.now() + waitMs;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const tick = () => {
    timer = undefined;
    if (stale?.() || scrollToRow(rowId, root) || Date.now() >= deadline) return;
    timer = setTimeout(tick, pollMs);
  };
  tick();
  return () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  };
}

let pendingReveal: (() => void) | undefined;
/// The wait for a revealed row to be drawn, which outlives the reveal that asked for it.
let pendingMark: (() => void) | undefined;

/// Runs `attempt` now, then every `pollMs` until it succeeds or `waitMs` passes, giving up quietly.
/// A later reveal replaces a pending one. Resolves whether it scrolled.
function revealWhenShown(
  attempt: () => boolean,
  { waitMs = REVEAL_WAIT_MS, pollMs = REVEAL_POLL_MS }: { waitMs?: number; pollMs?: number } = {},
): Promise<boolean> {
  pendingReveal?.();
  // An earlier reveal's row may still be waiting to be drawn; this one is the reader's now.
  pendingMark?.();
  pendingMark = undefined;
  return new Promise((resolve) => {
    const deadline = Date.now() + waitMs;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (revealed: boolean) => {
      if (timer !== undefined) clearTimeout(timer);
      if (pendingReveal === cancel) pendingReveal = undefined;
      resolve(revealed);
    };
    const cancel = () => finish(false);
    const poll = () => {
      timer = undefined;
      if (attempt()) finish(true);
      else if (Date.now() >= deadline) finish(false);
      else timer = setTimeout(poll, pollMs);
    };
    pendingReveal = cancel;
    poll();
  });
}

/// Scrolls to turn `turnId` once its row renders: now when it is there, else as soon as it appears,
/// giving up quietly after `waitMs`. A later reveal replaces a pending one. Resolves whether it
/// scrolled.
export function revealTurnWhenShown(
  turnId: string,
  root: ParentNode = document,
  options: { waitMs?: number; pollMs?: number } = {},
): Promise<boolean> {
  return revealWhenShown(() => scrollToTurn(turnId, root), options);
}

/// Brings message `messageId`'s row in once the chat has it (a link's `message=<id>`): the
/// transcript replays when the tab opens, so the message can take a moment, and the row itself may
/// be far above the view, where no element exists to scroll to. `show` asks the transcript for the
/// row and answers which row it asked for (App.tsx `showMessage`), undefined while the chat has
/// none; this marks that row once it is drawn. `chat` names the chat the row belongs to, so a pane
/// the reader moves to another chat within the wait drops the row instead of scrolling in whatever
/// wears its id there (row ids start over with each session). Gives up quietly, leaving the view
/// where it is, when the chat never has that message: another machine's transcript, or one this
/// session never saw.
export function revealMessageWhenShown(
  messageId: string,
  show: (messageId: string) => string | undefined,
  root: ParentNode = document,
  options: { waitMs?: number; pollMs?: number; chat?: () => string | undefined } = {},
): Promise<boolean> {
  const { chat } = options;
  return revealWhenShown(() => {
    const rowId = show(messageId);
    if (rowId === undefined) return false;
    // The chat that answered with this row, read now that there is one.
    const asked = chat?.();
    pendingMark = markWhenDrawn(rowId, root, { ...options, stale: () => chat?.() !== asked });
    return true;
  }, options);
}
