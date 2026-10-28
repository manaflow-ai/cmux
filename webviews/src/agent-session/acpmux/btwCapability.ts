/** The daemon capability required for the inline /btw reply shape. */
export const BTW_INLINE = "btw-inline-v1";

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
  if (supportsBtwInline(client.capabilities)) return actions.inline(question, sessionId);
  // Older daemons ignore `inline`: use only the legacy request shape.
  const side = await client.btw(question, sessionId);
  if (!current()) throw new Error(actions.staleMessage());
  await actions.openSide(side);
  return actions.openedMessage();
}
