/** Recovery uses the native host's provider VM ID; daemon summaries do not carry machine context. */
export function cloudCredentialRecovery(
  connected: boolean,
  machineID: string | undefined,
  sessionId: string | undefined,
  provider: string | undefined,
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  isCurrent: (sessionId: string) => boolean,
): (() => Promise<boolean>) | undefined {
  if (!connected || !machineID || !sessionId || (provider !== "claude" && provider !== "codex")) return undefined;
  return async () => {
    if (!isCurrent(sessionId)) return false;
    const reply = await call("chat.cloudCredentialTransfer", {
      provider,
      machineID,
      sessionId,
    }).catch(() => undefined);
    return (
      isCurrent(sessionId) &&
      typeof reply === "object" &&
      reply !== null &&
      "transferred" in reply &&
      reply.transferred === true
    );
  };
}
