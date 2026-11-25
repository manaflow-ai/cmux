// Ask about this for another chat's ask (Needs you's row, the Needs your input pill): the pane that
// shows that chat asks it, as its own row would.

/// The `revealTurn` value the host hands the pane that shows a chat when Needs you in another pane
/// asked about one of its asks (`chat.asks.open {ask}`, AgentPaneAskOpen.swift `askReveal`):
/// `ask:{"sessionId":…,"turnId":…,"question":…}`. Leo 2026-10-20: "have an option to go to the
/// source, or like have an option to maybe even make a side chat to just ask like, okay, but what is
/// going on here?" The relay starts a side chat (`_acpmux/btw`) only for the chat a pane shows, so
/// the asking pane cannot; this one can. Only the host makes it: a link's turn is a bare token
/// (DeepLink `isToken`), and a `message=` link's value has its own prefix.
export const ASK_REVEAL = "ask:";

export type RevealedAsk = { sessionId: string; turnId?: string; question: string };

/// The ask a reveal names, or undefined for any other reveal (or a malformed one).
export function revealedAsk(value: string): RevealedAsk | undefined {
  if (!value.startsWith(ASK_REVEAL)) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(value.slice(ASK_REVEAL.length));
  } catch {
    return undefined;
  }
  if (!parsed || typeof parsed !== "object") return undefined;
  const { sessionId, turnId, question } = parsed as Record<string, unknown>;
  if (typeof sessionId !== "string" || !sessionId) return undefined;
  if (typeof question !== "string" || !question.trim()) return undefined;
  return { sessionId, question, ...(typeof turnId === "string" && turnId ? { turnId } : {}) };
}

/// How long a just-opened pane may take to connect and show the chat before the ask is dropped.
export const ASK_REVEAL_WAIT_MS = 15_000;
const ASK_REVEAL_STEP_MS = 100;

/// Starts the side chat once this pane shows the ask's chat with its client connected (`ready`), at
/// most `waitMs` after the reveal: a tab the host just opened gets the reveal with its handshake,
/// before it connects. A pane that never shows that chat (the person moved it to another) asks
/// nothing. Resolves whether it asked; a refused ask rejects, for the caller to say so.
export async function runRevealedAsk(
  ask: RevealedAsk,
  {
    ready,
    sideSession,
    waitMs = ASK_REVEAL_WAIT_MS,
    stepMs = ASK_REVEAL_STEP_MS,
  }: {
    ready: (sessionId: string) => boolean;
    sideSession: (sessionId: string, question: string) => Promise<unknown>;
    waitMs?: number;
    stepMs?: number;
  },
): Promise<boolean> {
  const deadline = Date.now() + waitMs;
  while (!ready(ask.sessionId)) {
    if (Date.now() >= deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, stepMs));
  }
  await sideSession(ask.sessionId, ask.question);
  return true;
}
