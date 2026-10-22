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

/// Lost prompts that came back while the pane showed another chat, by chat. Each goes back into
/// the composer, with its "Not sent", only once the pane shows its own chat again: in another
/// chat's composer, the next Send would run it there.
export function lostDrafts<Draft extends { promptId: string }>() {
  const kept = new Map<string, Draft[]>();
  return {
    hold(sessionId: string, draft: Draft): void {
      kept.set(sessionId, [...(kept.get(sessionId) ?? []), draft]);
    },
    /// The host sent `promptId` again after all: its draft never comes back, in any chat.
    drop(promptId: string): void {
      for (const [sessionId, drafts] of kept) {
        const left = drafts.filter((draft) => draft.promptId !== promptId);
        if (left.length > 0) kept.set(sessionId, left);
        else kept.delete(sessionId);
      }
    },
    /// The drafts kept for `sessionId`, once: the pane shows that chat now.
    take(sessionId: string | undefined): Draft[] {
      if (sessionId === undefined) return [];
      const drafts = kept.get(sessionId) ?? [];
      kept.delete(sessionId);
      return drafts;
    },
  };
}

/// A composer's prompt, by its text and its chips' ids in order.
export type HeldPrompt = { text: string; attachmentIds: readonly string[] };

/// The composer without `restored`, the lost prompt that came back into it, or undefined when it
/// no longer holds that prompt as it came back. Once the host sends the prompt again after all,
/// its draft goes (its next Send would run it a second time, under a new id). `restore` puts a
/// prompt that comes back first, ahead of what the composer held, separated by a blank line, so
/// two prompts lost together come back as one draft: each goes as its own part, and what the
/// person typed stays. A part they edited, or a chip of it they removed, is theirs and stays.
export function withoutRestored(composer: HeldPrompt, restored: HeldPrompt): HeldPrompt | undefined {
  if (!restored.text && restored.attachmentIds.length === 0) return undefined;
  if (!restored.attachmentIds.every((id) => composer.attachmentIds.includes(id))) return undefined;
  const attachmentIds = composer.attachmentIds.filter((id) => !restored.attachmentIds.includes(id));
  if (!restored.text) return { text: composer.text, attachmentIds };
  const gap = "\n\n";
  const text = composer.text;
  for (let at = text.indexOf(restored.text); at >= 0; at = text.indexOf(restored.text, at + 1)) {
    const end = at + restored.text.length;
    const starts = at === 0 || text.startsWith(gap, at - gap.length);
    const ends = end === text.length || text.startsWith(gap, end);
    if (!starts || !ends) continue;
    // The part and one blank line beside it: the one after it, or before it when it is last.
    const rest =
      end < text.length ? text.slice(0, at) + text.slice(end + gap.length) : text.slice(0, Math.max(0, at - gap.length));
    return { text: rest, attachmentIds };
  }
  return undefined;
}
