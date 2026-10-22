// A prompt whose connection went before acpmux took it (an acpmux restart, a reset socket, the
// app's transport closing). With Debug Settings agentPane.debug.lostPromptReplay on, the host's
// prompt journal (Swift `AgentPanePromptJournal`) sends it again, once, on the pane's next
// connection with the same promptId, and acpmux runs a promptId at most once. So the pane does not ask the person to read the chat's saved state and press
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
      for (const resolve of waiting) resolve(client);
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

/// A connection the sender may wait on for the host's resend (`AcpmuxDirectClient`).
export type ResendWaiter = {
  readonly isClosed: boolean;
  awaitResent(sessionId: string, promptId: string, timeoutMs: number): Promise<boolean>;
};

/// Waits for the host to send `lost` again on a connection after `from`: the connection it shows
/// on, or undefined when none comes within `connectMs` or the prompt does not show within
/// `showMs` on one that stays. A connection that drops first hands the wait on to the next: the
/// host's journal sends the prompt again there.
export async function waitForResend<Client extends ResendWaiter>(
  clients: { next(previous: Client, timeoutMs: number): Promise<Client | undefined> },
  from: Client,
  lost: LostPrompt,
  connectMs: number,
  showMs: number,
): Promise<Client | undefined> {
  let previous = from;
  for (;;) {
    const next = await clients.next(previous, connectMs);
    if (!next) return undefined;
    if (await next.awaitResent(lost.sessionId, lost.promptId, showMs)) return next;
    if (!next.isClosed) return undefined;
    previous = next;
  }
}

/// The prompts a connection lost, by chat. The host's journal may send one again once acpmux is
/// back, even after its sender said "Not sent", so the person's next send of the same text and
/// attachments in the same chat goes under its promptId, and acpmux runs it at most once. Any
/// other prompt gets its own id: one that took a lost prompt's id would be answered as that
/// prompt's duplicate and never run.
export function lostPromptSlot() {
  const keyOf = (sessionId: string, text: string, attachmentIds: readonly string[]) =>
    JSON.stringify([sessionId, text, attachmentIds]);
  const kept = new Map<string, string>();
  /// Ids the host sent again after all, even after the wait gave up: never kept again, since
  /// acpmux would answer a new prompt under one as that prompt's duplicate.
  const retired = new Set<string>();
  return {
    keep(sessionId: string, promptId: string, text: string, attachmentIds: readonly string[]): void {
      if (retired.has(promptId)) return;
      kept.set(keyOf(sessionId, text, attachmentIds), promptId);
    },
    /// The host sent `promptId` again after all: a later identical prompt is a new one.
    forget(promptId: string): void {
      retired.add(promptId);
      for (const [key, id] of kept) if (id === promptId) kept.delete(key);
    },
    /// Forgets each kept prompt `shows` finds in its chat (a connection's history, read before
    /// the pane heard of the connection), and names them.
    forgetShown(shows: (sessionId: string, promptId: string) => boolean): string[] {
      const shown = [...kept].filter(([key, id]) => shows(JSON.parse(key)[0], id)).map(([, id]) => id);
      for (const id of shown) this.forget(id);
      return shown;
    },
    /// The lost prompt's id when this send is that prompt. Each lost prompt goes again once, and
    /// the chat's other lost prompts stay for theirs; a send in the chat that is none of them ends
    /// them all, so a later "continue" is a new prompt, not the lost one. Other chats keep theirs.
    /// `take`, once the send has left (acpmux took it, or a row holds it): the lost prompt's id now,
    /// and `commit` makes the slot's change then. A send that fails before that, back in the
    /// composer, leaves the slot as it was, so its next send still runs the lost prompt once.
    claim(
      sessionId: string,
      text: string,
      attachmentIds: readonly string[],
    ): { promptId: string | undefined; commit: () => void } {
      const promptId = kept.get(keyOf(sessionId, text, attachmentIds));
      let done = false;
      return {
        promptId,
        commit: () => {
          if (done) return;
          done = true;
          this.take(sessionId, text, attachmentIds);
        },
      };
    },
    take(sessionId: string, text: string, attachmentIds: readonly string[]): string | undefined {
      const key = keyOf(sessionId, text, attachmentIds);
      const taken = kept.get(key);
      if (taken !== undefined) {
        kept.delete(key);
        return taken;
      }
      for (const other of kept.keys()) if (JSON.parse(other)[0] === sessionId) kept.delete(other);
      return undefined;
    },
  };
}
