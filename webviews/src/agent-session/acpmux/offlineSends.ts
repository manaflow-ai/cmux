// Prompts sent while the pane has no link to acpmux (a reconnect, a daemon restart, the first
// moments of a launch). Leo, 2026-11-22: "FUCKING RECONNECTING JUST LET ME SEND WHY WOULD IT
// FUCKING BLOCK SENDS IN THE FIRST PLACE STUPID STUPID FUCKING DESIGN". Before, Send did nothing
// while the link was down: the composer kept the text and said nothing.
//
// Now Send always takes the prompt: it leaves the composer at once and shows in the transcript as
// its own pending row (the row the chat's client draws for it later has the same id, so it is one
// row throughout). It is on disk before it shows (the app's unsent-prompt store,
// AgentPaneUnsentPrompts.swift, keyed by chat and prompt id, marked `queued`), so a reload, a crash
// or a relaunch keeps it and sends it then. Once the link is back the prompts go one at a time, in
// the order they were sent, each once acpmux took the one before, each under its own prompt id:
// acpmux runs a prompt id at most once (a send it already has answers `duplicate`), so a resend
// after a drop never runs twice. Once the chat's client sends one it owns the stored copy (it puts
// the same prompt id again and forgets it at acpmux's acknowledgement).
import type { ComposerAttachment } from "./attachments";
import { onDraftActionsChanged } from "./composerDraft";
import { attachedImages, sentPromptShape } from "./direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import type { UnsentPromptRecord, UnsentPromptStore } from "./unsentPrompts";

export type OfflineSend = {
  /// Its prompt id: the row's id is `local-<id>`, as the client's own send draws it.
  id: string;
  /// The chat it was sent in.
  chat: string;
  text: string;
  attachments: ComposerAttachment[];
  /// When the person sent it (Date.now()).
  at: number;
};

/// Sends one prompt under its own id; settles once acpmux took it, rejects with its refusal.
export type OfflineSender = (send: OfflineSend) => Promise<void>;

/// What a failed send of a queued prompt means for it.
export type OfflineOutcome =
  /// The link went again before acpmux answered: it waits for the next link.
  | "wait"
  /// Refused: the caller has put it where it belongs (its failed row, the trust hold, the composer).
  | "dropped";

/// The queue: in page memory for drawing, on disk for a reload. Writes are per prompt.
export class OfflineSends {
  private items: OfflineSend[] = [];
  private flushing = false;
  /// No flush before this (a send that lost the link backs off; `linkChanged` clears it).
  private retryAt = 0;
  private listeners = new Set<() => void>();
  private store: UnsentPromptStore | undefined;
  /// Bumped on every change, for `useSyncExternalStore`-style readers.
  version = 0;

  constructor(store?: UnsentPromptStore) {
    this.store = store;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  /// The queued prompts of chat `chat`, oldest first.
  in(chat: string | undefined): readonly OfflineSend[] {
    if (!chat) return [];
    return this.items.filter((item) => item.chat === chat);
  }

  /// Whether chat `chat` has prompts waiting or going: a prompt sent now goes after them.
  pending(chat: string | undefined): boolean {
    return this.flushing || this.in(chat).length > 0;
  }

  /// Takes a prompt sent now: kept on disk first, then drawn.
  add(chat: string, text: string, attachments: ComposerAttachment[], id: string = crypto.randomUUID()): OfflineSend {
    const send: OfflineSend = { id, chat, text, attachments, at: Date.now() };
    this.items = [...this.items, send];
    void this.store?.put(chat, offlineRecord(send)).catch(() => undefined);
    this.changed();
    return send;
  }

  /// Prompts a reload read back from the store (`queued` records) for chat `chat`: each once.
  adopt(chat: string, records: readonly UnsentPromptRecord[]): void {
    const known = new Set(this.items.map((item) => item.id));
    const adopted = records
      .filter((record) => record.queued === true && !known.has(record.promptId))
      .map((record) => ({
        id: record.promptId,
        chat,
        text: record.input,
        attachments: record.attachments,
        at: record.at,
      }));
    if (!adopted.length) return;
    this.items = [...this.items, ...adopted].sort((a, b) => a.at - b.at);
    this.changed();
  }

  /// A new link came up: the next flush goes at once.
  linkChanged(): void {
    this.retryAt = 0;
  }

  /// The person removed it, or it went back into the composer: off disk too.
  remove(id: string, forget = true): void {
    const item = this.items.find((entry) => entry.id === id);
    if (!item) return;
    this.items = this.items.filter((entry) => entry.id !== id);
    if (forget) void this.store?.remove(item.chat, id).catch(() => undefined);
    this.changed();
  }

  /// Sends chat `chat`'s prompts, one at a time and in order, while `linkUp()` holds. A prompt
  /// whose send failed for the link waits for the next flush; a refused one leaves the queue (the
  /// sender put it where it belongs). The client owns the stored copy once it sent it.
  async flush(
    chat: string,
    linkUp: () => boolean,
    send: OfflineSender,
    failed: (send: OfflineSend, error: unknown) => OfflineOutcome,
  ): Promise<void> {
    if (this.flushing || Date.now() < this.retryAt) return;
    this.flushing = true;
    this.changed();
    try {
      for (;;) {
        const next = this.items.find((item) => item.chat === chat);
        if (!next || !linkUp()) break;
        try {
          await send(next);
        } catch (error) {
          if (failed(next, error) === "wait") {
            // The client let go of its stored copy with the send; it is this queue's again.
            void this.store?.put(next.chat, offlineRecord(next)).catch(() => undefined);
            // Asked again after a short wait, not in a loop while a dying link still looks up; a
            // new link asks at once (its flush comes with the link).
            this.retryAt = Date.now() + OFFLINE_RETRY_MS;
            setTimeout(() => this.changed(), OFFLINE_RETRY_MS);
            break;
          }
        }
        // Sent or refused: the client's row (or the failed row, or the composer) has it now.
        this.items = this.items.filter((item) => item.id !== next.id);
        this.changed();
      }
    } finally {
      this.flushing = false;
      this.changed();
    }
  }
}

/// The stored record of a queued prompt: the same shape as an unsent one, marked `queued`, so a
/// reload sends it instead of drawing it as Not sent.
export function offlineRecord(send: OfflineSend): UnsentPromptRecord {
  return { promptId: send.id, input: send.text, attachments: send.attachments, at: send.at, queued: true };
}

/// A queued prompt as its transcript row: the user's message, pending, under the id the client's
/// own send draws it under (`local-<promptId>`).
export function offlineRow(send: OfflineSend): AcpmuxRow {
  const { inline, text, pasted } = sentPromptShape(send.text, send.attachments, { dropped: () => false });
  return {
    id: `local-${send.id}`,
    version: 0,
    at: send.at,
    kind: "user",
    text,
    promptId: send.id,
    ...(pasted.length ? { pasted } : {}),
    ...(inline ? { inlineParts: inline.parts } : {}),
    ...(send.attachments.length
      ? { images: attachedImages(send.attachments), retryAttachments: send.attachments }
      : {}),
    pending: true,
  };
}

/// The snapshot with chat's queued prompts as pending rows at its end; one the client already draws
/// (its row id or its prompt id) is the client's.
export function withOfflineSends(raw: AcpmuxSnapshot, sends: readonly OfflineSend[]): AcpmuxSnapshot {
  if (!sends.length) return raw;
  const drawn = new Set<string>();
  for (const row of raw.rows) {
    drawn.add(row.id);
    if (row.promptId) drawn.add(row.promptId);
  }
  const rows = sends.filter((send) => !drawn.has(`local-${send.id}`) && !drawn.has(send.id)).map(offlineRow);
  return rows.length ? { ...raw, rows: [...raw.rows, ...rows] } : raw;
}

/// A send that failed because the link went (the socket closed or was not open, or the host lost
/// the prompt with its connection): it goes again on the next link, under the same prompt id.
export function lostToLink(error: unknown): boolean {
  const fields = error as { code?: unknown; interrupted?: unknown; lostPrompt?: unknown; message?: unknown } | null;
  if (!fields) return false;
  if (fields.interrupted === true || fields.lostPrompt !== undefined) return true;
  if (fields.code === "native.not_connected") return true;
  return fields.message === OFFLINE_NOT_CONNECTED;
}

/// The error a queued send gets when the actions went between the check and the call.
export const OFFLINE_NOT_CONNECTED = "offline.notConnected";

/// How long a queued prompt whose send lost the link waits before it is tried again on the same link.
export const OFFLINE_RETRY_MS = 1_000;

/// Whether the pane can reach acpmux now: the connected client's action map is installed.
export function linked(): boolean {
  return typeof window !== "undefined" && Boolean(window.cmuxAcpmuxActions?.["chat.send"]);
}

/// Settles once the pane can reach acpmux (at once when it can now). A send that needs the link
/// waits on this instead of being refused while the pane reconnects; it never times out, as a
/// reconnect never gives up.
export function untilLinked(): Promise<void> {
  if (linked()) return Promise.resolve();
  return new Promise((resolve) => {
    const stop = onDraftActionsChanged(() => {
      if (!linked()) return;
      stop();
      resolve();
    });
  });
}
