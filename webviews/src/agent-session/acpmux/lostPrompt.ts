// A prompt whose connection went before acpmux took it (an acpmux restart, a reset socket, the
// app's transport closing). The host's prompt journal (Swift `AgentPanePromptJournal`) sends it
// again, once, on the pane's next connection with the same promptId, and acpmux runs a promptId
// at most once. So the pane does not ask the person to read the chat's saved state and press
// Enter again: the sender waits for the next connection and for the prompt to show there, and
// says "Not sent" only when it never does (a prompt the host did not keep: too large, a chat on
// another machine).

/// How long a sender waits for the pane's next connection.
export const LOST_PROMPT_CONNECT_MS = 30_000;
/// How long the next connection waits for the prompt the host sent again to show.
export const LOST_PROMPT_SHOW_MS = 10_000;

/// What `AcpmuxDirectClient.send` adds to the error of a prompt it lost with its connection.
export type LostPrompt = { sessionId: string; promptId: string };

/// The connection went while the request waited (`rejectPending`), not the request's own time.
export function isLostConnection(error: unknown): boolean {
  return (error as { interrupted?: unknown } | null)?.interrupted === true;
}

export function lostPrompt(error: unknown): LostPrompt | undefined {
  const lost = (error as { lostPrompt?: Partial<LostPrompt> } | null)?.lostPrompt;
  return typeof lost?.sessionId === "string" && typeof lost.promptId === "string"
    ? { sessionId: lost.sessionId, promptId: lost.promptId }
    : undefined;
}

/// The pane's connected clients, one after another: `next` settles with the first client that
/// connects after `previous`, or undefined after `timeoutMs`.
export function clientWaiter<Client>() {
  let current: Client | undefined;
  const waiting = new Set<(client: Client) => void>();
  return {
    connected(client: Client): void {
      current = client;
      for (const resolve of [...waiting]) resolve(client);
    },
    next(previous: Client, timeoutMs: number): Promise<Client | undefined> {
      if (current !== undefined && current !== previous) return Promise.resolve(current);
      return new Promise((resolve) => {
        const done = (client: Client | undefined) => {
          clearTimeout(timer);
          waiting.delete(done);
          resolve(client);
        };
        const timer = setTimeout(() => done(undefined), timeoutMs);
        waiting.add(done);
      });
    },
  };
}

/// The prompt a sender gave up on ("Not sent"). The host's journal may still send it once acpmux
/// is back, so the person's next send of the same text and attachments goes under its promptId,
/// and acpmux runs it at most once. Any other prompt gets its own id: one that took a lost
/// prompt's id would be answered as that prompt's duplicate and never run.
export function lostPromptSlot() {
  const keyOf = (text: string, attachmentIds: readonly string[]) => JSON.stringify([text, attachmentIds]);
  let kept: { promptId: string; key: string } | undefined;
  return {
    keep(promptId: string, text: string, attachmentIds: readonly string[]): void {
      kept = { promptId, key: keyOf(text, attachmentIds) };
    },
    /// The lost prompt's id when this send is that prompt. Only the next send may take it: a
    /// later "continue" is a new prompt, not the lost one.
    take(text: string, attachmentIds: readonly string[]): string | undefined {
      const taken = kept;
      kept = undefined;
      return taken?.key === keyOf(text, attachmentIds) ? taken.promptId : undefined;
    },
  };
}
