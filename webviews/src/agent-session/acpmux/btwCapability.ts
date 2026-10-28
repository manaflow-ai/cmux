/** The daemon capability required for the inline /btw reply shape. */
export const BTW_INLINE = "btw-inline-v1";

function isUnsupportedNativeAction(error: unknown): boolean {
  return (error as { code?: unknown } | null)?.code === "native.invalid_request";
}

export function supportsBtwInline(capabilities: ReadonlySet<string> | undefined): boolean {
  return capabilities?.has(BTW_INLINE) === true;
}

interface BtwClient {
  capabilities: ReadonlySet<string> | undefined;
  readonly selectedSession: string | undefined;
  readonly selectionToken: number;
  btw(question: string, sessionId: string): Promise<string>;
}

/** Route the composer's question without opening a late reply beside a different chat. */
export async function askBtwQuestion(
  client: BtwClient,
  question: string,
  sessionId: string,
  actions: {
    inline(question: string, sessionId: string): Promise<string>;
    openSide(sessionId: string): Promise<unknown>;
    openedMessage(): string;
    staleMessage(): string;
  },
): Promise<string> {
  const selection = client.selectionToken;
  const current = () => client.selectedSession === sessionId && client.selectionToken === selection;
  if (!current()) throw new Error(actions.staleMessage());
  if (supportsBtwInline(client.capabilities)) {
    try {
      return await actions.inline(question, sessionId);
    } catch (error) {
      // A newer daemon can be paired with an older app host that does not know
      // the native operation yet. Keep the request useful across that version
      // skew by using the legacy side-session shape in that one case.
      if (!isUnsupportedNativeAction(error)) throw error;
      if (!current()) throw new Error(actions.staleMessage());
    }
  }
  // Older daemons ignore `inline`: use only the legacy request shape.
  const side = await client.btw(question, sessionId);
  if (!current()) throw new Error(actions.staleMessage());
  await actions.openSide(side);
  return actions.openedMessage();
}
