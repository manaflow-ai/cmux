import type { TrustRefusal } from "./direct";

/** The daemon capability required for the inline /btw reply shape. */
export const BTW_INLINE = "btw-inline-v1";

function isUnsupportedNativeAction(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return code === "native.invalid_request" || code === "unsupported";
}

export function supportsBtwInline(capabilities: ReadonlySet<string> | undefined): boolean {
  return capabilities?.has(BTW_INLINE) === true;
}

interface BtwClient {
  capabilities: ReadonlySet<string> | undefined;
  readonly selectedSession: string | undefined;
  readonly selectionToken: number;
  btw(question: string, sessionId: string): Promise<string>;
  routeTrustRefusal?(refusal: TrustRefusal, again?: () => void): boolean;
}

/** Route the composer's question without opening a late reply beside a different chat. */
export async function askBtwQuestion(
  client: BtwClient,
  question: string,
  sessionId: string,
  actions: {
    inline(question: string, sessionId: string): Promise<string>;
    openSide(sessionId: string): Promise<unknown>;
    discardSide?(sessionId: string): void;
    openedMessage(): string;
    staleMessage(): string;
  },
): Promise<string> {
  const selection = client.selectionToken;
  const current = () => client.selectedSession === sessionId && client.selectionToken === selection;
  if (!current()) throw new Error(actions.staleMessage());
  try {
    if (supportsBtwInline(client.capabilities)) {
      try {
        return await actions.inline(question, sessionId);
      } catch (error) {
        // App and daemon update independently. Both old page hosts and legacy
        // WebKit hosts reject an unknown action before starting any work.
        if (!isUnsupportedNativeAction(error)) throw error;
        if (!current()) throw new Error(actions.staleMessage());
      }
    }
    // Older daemons ignore `inline`: use only the legacy request shape.
    const side = await client.btw(question, sessionId);
    if (!current()) {
      actions.discardSide?.(side);
      throw new Error(actions.staleMessage());
    }
    try {
      await actions.openSide(side);
    } catch (error) {
      actions.discardSide?.(side);
      throw error;
    }
    return actions.openedMessage();
  } catch (error) {
    // Native replies keep the daemon's trust reason and folder in details;
    // direct legacy requests expose them on the error itself.
    const fields = error as {
      code?: unknown;
      reason?: unknown;
      cwd?: unknown;
      details?: { cwd?: unknown };
    } | null;
    const reason = fields?.reason ?? fields?.code;
    if (current() && (reason === "trust.pending" || reason === "trust.untrusted")) {
      const cwd = fields?.cwd ?? fields?.details?.cwd;
      client.routeTrustRefusal?.({ reason, ...(typeof cwd === "string" ? { cwd } : {}) });
    }
    throw error;
  }
}
