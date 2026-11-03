/// Native palette commands carry the session that was focused when the action was queued. The
/// page drops a command after a tab switch instead of applying it to the replacement chat.
export type MenuCommand = { action: string; sessionId: string };

export function parseMenuCommand(value: unknown): MenuCommand | undefined {
  if (typeof value !== "string" || !value.startsWith("menu:")) return undefined;
  const divider = value.lastIndexOf("|");
  if (divider <= "menu:".length) return undefined;
  const action = value.slice("menu:".length, divider);
  const sessionId = value.slice(divider + 1);
  return sessionId ? { action, sessionId } : undefined;
}

export function isCurrentMenuCommand(value: unknown, sessionId: string | undefined): value is string {
  const command = parseMenuCommand(value);
  return command !== undefined && command.sessionId === sessionId;
}
