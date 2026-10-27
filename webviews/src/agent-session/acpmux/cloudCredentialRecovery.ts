/** Recovery uses the native host's provider VM ID; daemon summaries do not carry machine context. */
export function cloudCredentialRecovery(
  connected: boolean,
  machineID: string | undefined,
  sessionId: string | undefined,
  provider: string | undefined,
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): (() => Promise<boolean>) | undefined {
  if (!connected || !machineID || !sessionId || (provider !== "claude" && provider !== "codex")) return undefined;
  return async () => {
    const reply = await call("chat.cloudCredentialTransfer", {
      provider,
      machineID,
      sessionId,
    }).catch(() => undefined);
    return typeof reply === "object" && reply !== null && "transferred" in reply && reply.transferred === true;
  };
}
