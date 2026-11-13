// The chats whose prompt coach card the person dismissed on this device (PromptCoachCard's ×), by
// session id: once dismissed, that chat never draws a coach card again and the page never asks
// acpmux to write one for it (direct.ts). Capped like recapDismissed.ts, oldest first out.
const DISMISSED = "cmux.agentPane.promptCoachDismissed";
const MAX_DISMISSED = 200;

function read(): string[] {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(DISMISSED) ?? "[]");
    return Array.isArray(value) ? value.filter((key): key is string => typeof key === "string") : [];
  } catch {
    return [];
  }
}

export function promptCoachDismissed(sessionId: string): boolean {
  return read().includes(sessionId);
}

export function rememberPromptCoachDismissed(sessionId: string): void {
  try {
    const kept = read().filter((other) => other !== sessionId);
    globalThis.localStorage?.setItem(DISMISSED, JSON.stringify([...kept, sessionId].slice(-MAX_DISMISSED)));
  } catch {
    // Storage refused: the card is gone from this view only.
  }
}
