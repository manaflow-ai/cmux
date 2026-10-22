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

/// Lost prompts that came back while the pane showed another chat, by chat. Each goes back into
/// the composer, with its "Not sent", only once the pane shows its own chat again: in another
/// chat's composer, the next Send would run it there. `inDraft`: the prompt never left the composer,
/// so it is in its chat's saved draft already and only its provenance waits.
export function lostDrafts<Draft extends { promptId: string; inDraft?: boolean; delivered?: boolean }>() {
  const kept = new Map<string, Draft[]>();
  return {
    hold(sessionId: string, draft: Draft): void {
      kept.set(sessionId, [...(kept.get(sessionId) ?? []), draft]);
    },
    /// The host sent `promptId` again after all: its draft never comes back, in any chat. One in its
    /// chat's saved draft stays, marked delivered, so that chat's next send leaves it out.
    drop(promptId: string): void {
      for (const [sessionId, drafts] of kept) {
        const left = drafts.flatMap((draft) =>
          draft.promptId !== promptId ? [draft] : draft.inDraft ? [{ ...draft, delivered: true }] : [],
        );
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

/// The composer as it would hold had `parts[index]` never come back into it, or undefined when
/// the person changed it since (`withoutParts`).
export function withoutRestored(
  composer: HeldPrompt,
  parts: readonly HeldPrompt[],
  index: number,
): HeldPrompt | undefined {
  if (index < 0 || index >= parts.length) return undefined;
  return withoutParts(composer, parts, new Set([index]));
}

/// The composer as it would hold had the `parts` at `drop` never come back into it, or undefined
/// when the person changed it since. `parts`: the lost prompts put back into this chat's composer,
/// in the order they came back. `restore` puts each one first, ahead of what the composer held, a
/// blank line apart, with its chips first; so the composer is taken apart from its newest part
/// back to what was there before the first, and built again without the parts that went. Matching
/// whole parts by where they were put, never by searching the text, keeps a part that is also a
/// paragraph of another one.
export function withoutParts(
  composer: HeldPrompt,
  parts: readonly HeldPrompt[],
  drop: ReadonlySet<number>,
): HeldPrompt | undefined {
  const gap = "\n\n";
  let text = composer.text;
  let attachmentIds = [...composer.attachmentIds];
  for (let at = parts.length - 1; at >= 0; at--) {
    const part = parts[at]!;
    if (!text.startsWith(part.text)) return undefined;
    const rest = text.slice(part.text.length);
    if (rest && part.text && !rest.startsWith(gap)) return undefined;
    // An empty part over typed text left a blank line ahead of it, which Send trims away.
    text = rest.startsWith(gap) ? rest.slice(gap.length) : rest;
    if (!part.attachmentIds.every((id, position) => attachmentIds[position] === id)) return undefined;
    attachmentIds = attachmentIds.slice(part.attachmentIds.length);
  }
  for (const [at, part] of parts.entries()) {
    if (drop.has(at)) continue;
    text = text.trim() ? `${part.text}${gap}${text}` : part.text;
    attachmentIds = [...part.attachmentIds, ...attachmentIds.filter((id) => !part.attachmentIds.includes(id))];
  }
  return { text, attachmentIds };
}
