import { agentKey } from "../shared/agentKey";
import type { AcpmuxDirectClient } from "./direct";

type RecoveryClient = Pick<AcpmuxDirectClient, "selectedSession" | "resendPrompt" | "send">;
type Recovery = (rowId: string, prompt: string, automatic?: boolean) => Promise<void>;

/** Recovery uses the native host's provider VM ID; daemon summaries do not carry machine context. */
export function cloudCredentialRecovery(
  connected: boolean,
  machineID: string | undefined,
  sessionId: string | undefined,
  harness: string | undefined,
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  isCurrent: (sessionId: string) => boolean,
  currentClient: () => RecoveryClient | undefined,
): Recovery | undefined {
  const provider = agentKey(harness?.split("/").pop());
  if (!connected || !machineID || !sessionId || (provider !== "claude" && provider !== "codex")) return undefined;
  let pending = false;
  let automaticAttempted = false;
  return async (rowId, prompt, automatic = false) => {
    const client = currentClient();
    if (pending || (automatic && automaticAttempted) || !client || !isCurrent(sessionId)) return;
    if (automatic) automaticAttempted = true;
    pending = true;
    try {
      const retryPromptId = crypto.randomUUID();
      // Reserve the click natively before any async attachment restoration or provider login.
      const reply = await call("chat.cloudCredentialTransfer", {
        provider,
        machineID,
        sessionId,
        retryPromptId,
        automatic,
      });
      if (
        !isCurrent(sessionId) ||
        currentClient() !== client ||
        typeof reply !== "object" ||
        reply === null ||
        !("transferred" in reply) ||
        reply.transferred !== true ||
        !("promptId" in reply) ||
        reply.promptId !== retryPromptId ||
        !("ticket" in reply) ||
        typeof reply.ticket !== "string" ||
        !reply.ticket
      )
        return;
      const draft = await client.resendPrompt(rowId, prompt);
      if (!isCurrent(sessionId) || currentClient() !== client) return;
      // An expired ticket takes the client's existing unsent-prompt recovery path.
      await client.send(draft.input, draft.attachments, retryPromptId, undefined, reply.ticket);
    } finally {
      pending = false;
    }
  };
}
