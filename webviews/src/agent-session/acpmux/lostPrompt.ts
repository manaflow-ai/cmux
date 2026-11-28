// A prompt whose connection went before acpmux took it (an acpmux restart, a reset socket, the
// app's transport closing). The host's prompt journal (Swift `AgentPanePromptJournal`) sends it
// again, once, on the pane's next connection with the same promptId, and acpmux runs a promptId at
// most once. So the pane does not ask the person to read the chat's saved state and press Enter again: the sender waits for the
// next connection and for the prompt to show there, and says "Not sent" only when it never does.
// Leo, 2026-10-21: "why does it say it's not responding?"

import type { ComposerAttachment } from "./attachments";

/// How long a sender waits for the pane's next connection: until it comes. An acpmux restart for an
/// app update can take longer than any fixed wait, and the host's journal sends the prompt again on
/// that connection whenever it comes, so a wait that gave up first handed the prompt back (or said
/// "Not sent") for a prompt that then ran anyway (Leo, 2026-11-24: after an update, chats said
/// "Not sent: no answer from cmux" and wanted a Retry by hand).
export const LOST_PROMPT_CONNECT_MS = Number.POSITIVE_INFINITY;
/// How long the next connection waits with no word at all of the prompt the host sends again: a
/// quiet window, opened again by each word of the host's outbox (`PromptResendNotice`), never a
/// deadline on a send that progresses (Leo, 2026-11-24: "10s timeout for messages being sendsble
/// is a shame. if it's making good progress, it shiukd be allowed to keep going?").
export const LOST_PROMPT_SHOW_MS = 30_000;

/// What the host's prompt outbox (Swift `AgentPanePromptRelay`, `_cmux/prompt_resend`) says of a
/// prompt it sends again: `sent` on the wire, `accepted` acpmux took it, `retrying` acpmux said
/// "not now" (just restarted, busy) and it goes again in `retryInMs`, `refused` for good.
export type PromptResendNotice = {
  sessionId: string;
  promptId: string;
  state: "sent" | "accepted" | "retrying" | "refused";
  attempt: number;
  retryInMs?: number;
  code?: string;
  reason?: string;
  message?: string;
};

export function promptResendNotice(params: unknown): PromptResendNotice | undefined {
  const p = params as Record<string, unknown> | null;
  if (!p || typeof p.sessionId !== "string" || typeof p.promptId !== "string") return undefined;
  const state = p.state;
  if (state !== "sent" && state !== "accepted" && state !== "retrying" && state !== "refused") return undefined;
  const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
  const retryInMs =
    typeof p.retryInMs === "number" && Number.isFinite(p.retryInMs) ? Math.max(0, p.retryInMs) : undefined;
  const code = text(p.code);
  const reason = text(p.reason);
  const message = text(p.message);
  return {
    sessionId: p.sessionId,
    promptId: p.promptId,
    state,
    attempt: typeof p.attempt === "number" ? p.attempt : 0,
    ...(retryInMs !== undefined ? { retryInMs } : {}),
    ...(code ? { code } : {}),
    ...(reason ? { reason } : {}),
    ...(message ? { message } : {}),
  };
}

/// acpmux's refusal of a resent prompt as the error its "Not sent" row shows.
export function resendRefusalError(notice: PromptResendNotice): Error & { code?: string; reason?: string } {
  // l10n-allow: the wire error's last-resort text; the notice carries its own
  return Object.assign(new Error(notice.message ?? "acpmux refused this message."), {
    ...(notice.code ? { code: notice.code } : {}),
    ...(notice.reason ? { reason: notice.reason } : {}),
  });
}

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
/// connects after `previous`, or undefined after `timeoutMs`. With no finite `timeoutMs` it waits
/// for the connection itself, however long that takes.
export function clientWaiter<Client>() {
  let current: Client | undefined;
  const waiting = new Set<(client: Client) => void>();
  return {
    connected(client: Client): void {
      current = client;
      for (const resolve of waiting) resolve(client);
    },
    next(previous: Client, timeoutMs: number = Number.POSITIVE_INFINITY): Promise<Client | undefined> {
      if (current !== undefined && current !== previous) return Promise.resolve(current);
      return new Promise((resolve) => {
        const done = (client: Client | undefined) => {
          if (timer !== undefined) clearTimeout(timer);
          waiting.delete(done);
          resolve(client);
        };
        // No timer for a wait with no end (a timer cannot hold `Infinity`: it would fire at once).
        const timer = Number.isFinite(timeoutMs) ? setTimeout(() => done(undefined), timeoutMs) : undefined;
        waiting.add(done);
      });
    },
  };
}

/// A connection the sender may wait on for the host's resend (`AcpmuxDirectClient`).
export type ResendWaiter = {
  readonly isClosed: boolean;
  awaitResent(sessionId: string, promptId: string, timeoutMs: number): Promise<boolean>;
  /// The chat the pane shows on this connection (`AcpmuxDirectClient.selectedSession`).
  readonly selectedSession?: string;
  /// Whether the host's store keeps the prompt for its chat (`AcpmuxDirectClient.keepsUnsentPrompt`).
  keepsUnsentPrompt?(promptId: string): boolean;
};

/// The pane left the lost prompt's chat while it waited, and the host's store keeps the prompt
/// there (unsentPrompts.ts): the host's outbox still sends it, and the chat, shown again, drops the
/// stored copy once acpmux has it, or draws it as not sent with Retry if acpmux never took it. Its
/// sender gives it back nowhere. Before, the wait said "not resent" on the switch and the prompt
/// went into its chat's draft while the outbox delivered it, and this pane, on another chat, never
/// heard the record that would take it out: the next Send there ran it twice (Leo, 2026-11-25:
/// "wait that message got split up and queued").
function leftForStore(next: ResendWaiter, from: ResendWaiter, lost: LostPrompt): boolean {
  return !next.isClosed && next.selectedSession !== lost.sessionId && from.keepsUnsentPrompt?.(lost.promptId) === true;
}

/// Tags a lost prompt's error as kept in its chat by the host's store (`leftForStore`): every
/// sender reads it as kept in the chat (pane/sendHost.ts `keptInChat`), never to give back.
function keepInStore(error: unknown): void {
  if (error && typeof error === "object") Object.assign(error, { keptUnsent: true });
}

/// Whether `error`'s prompt stays in its chat's store (`keepInStore`).
export function keptUnsent(error: unknown): boolean {
  return (error as { keptUnsent?: unknown } | null)?.keptUnsent === true;
}

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
): Promise<Client | "away" | undefined> {
  let previous = from;
  for (;;) {
    const next = await clients.next(previous, connectMs);
    if (!next) return undefined;
    if (await next.awaitResent(lost.sessionId, lost.promptId, showMs)) return next;
    if (leftForStore(next, from, lost)) return "away";
    if (!next.isClosed) return undefined;
    previous = next;
  }
}

/// Whether the prompt `error` says connection `from` lost showed on a later connection, sent again
/// there by the host: false at once for any other failure, and false when it never showed, so its
/// sender says "Not sent" and gives it back only then. False too when the pane left its chat and
/// the host's store keeps it there: then `error` says so (`keptUnsent`), and it goes back nowhere.
export async function resentAfterLoss<Client extends ResendWaiter>(
  error: unknown,
  clients: { next(previous: Client, timeoutMs: number): Promise<Client | undefined> },
  from: Client | undefined,
  connectMs = LOST_PROMPT_CONNECT_MS,
  showMs = LOST_PROMPT_SHOW_MS,
): Promise<boolean> {
  const lost = lostPrompt(error);
  if (!lost || !from) return false;
  const went = await waitForResend(clients, from, lost, connectMs, showMs);
  if (went === "away") keepInStore(error);
  return went !== undefined && went !== "away";
}

/// A connection that draws a lost prompt as its own row meanwhile (`AcpmuxDirectClient`).
export type LostRowHolder = ResendWaiter & {
  awaitResent(
    sessionId: string,
    promptId: string,
    timeoutMs: number,
    draw?: { input: string; attachments: ComposerAttachment[] },
  ): Promise<boolean>;
  failLostPrompt(promptId: string, error: unknown): boolean;
};

/// Where a lost prompt ended up (`keepLostPrompt`): it showed as sent on a later connection; it
/// stays there as a failed row with Retry; the pane left its chat, whose store keeps it
/// (`leftForStore`); or no connection could hold it, so its sender keeps it.
export type LostOutcome = "shown" | "failed" | "away" | "none";

/// A started chat's prompt its connection lost before the pane heard acpmux take it (acpmux may
/// well have it: Leo, 2026-11-11, every "Not sent yet" message had reached its chat). It stays
/// in the chat, one row with one state: on the next connection it draws as its own row on its way
/// until acpmux's record of it lands there, and only if that never comes does the row fail, with
/// Retry under the same prompt id. Before, the prompt went back to the composer and a free line
/// said "Not sent yet" under a bubble that, once the record came, already looked sent.
export async function keepLostPrompt<Client extends LostRowHolder>(
  error: unknown,
  clients: { next(previous: Client, timeoutMs: number): Promise<Client | undefined> },
  from: Client | undefined,
  draw: { input: string; attachments: ComposerAttachment[] },
  connectMs = LOST_PROMPT_CONNECT_MS,
  showMs = LOST_PROMPT_SHOW_MS,
): Promise<LostOutcome> {
  const lost = lostPrompt(error);
  if (!lost || !from) return "none";
  let previous = from;
  for (;;) {
    const next = await clients.next(previous, connectMs);
    if (!next) return "none";
    if (await next.awaitResent(lost.sessionId, lost.promptId, showMs, draw)) return "shown";
    if (leftForStore(next, from, lost)) {
      keepInStore(error);
      return "away";
    }
    if (!next.isClosed) return next.failLostPrompt(lost.promptId, error) ? "failed" : "none";
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
