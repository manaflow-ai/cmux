// The Messages page's unsent sends, kept by the app across launches (`cmux.home.messages.outbox.*`,
// HomeMessagesOutbox.swift), as the native composer's durable outbox: the composer clears its
// draft the moment a send shows as pending, so a send the owner never took would be lost with the
// page. Each send is kept as its own entry, by its idempotency key: a new or changed row is put, a
// row gone (delivered, discarded) is removed, so two pages showing one conversation never write
// over each other's sends. A new page shows the kept ones again as not sent, with Retry (each keeps
// its idempotency key, so none goes twice). A send the app refuses (past its size cap) says so on
// its row ("Not Saved"), never a silent drop.
//
// Cost: one put per send whose row changed (a send, its delivery, a failure) and one remove per
// send that left, none on typing; the rows are small (text and the owner's parts, never file bytes).
import { PendingCarry, type PendingSend } from "../home-channels/store";
import type { PageClient } from "../shared/pageClient";
import { answered } from "./host";
import type { KeeperAck } from "./transcript/attachmentDrafts";

export const OutboxOps = {
  load: "cmux.home.messages.outbox.load",
  put: "cmux.home.messages.outbox.put",
  remove: "cmux.home.messages.outbox.remove",
} as const;

/** The host's code for a send larger than it keeps (HomeMessagesKept.tooLargeCode). */
export const OUTBOX_TOO_LARGE = "cmux.home.outbox.too_large";

/** Where the unsent sends are kept (the app's HomeStore), one send per entry. */
export interface OutboxKeeper {
  load(): Promise<PendingSend[]>;
  /** Keeps one send (adds or replaces it by its key); resolves false when the app refused it. */
  put(send: PendingSend): Promise<boolean>;
  /** Lets go of one send; resolves once the app has (nothing: it has already). */
  remove(conversation: string, key: string): KeeperAck;
}

export class KeptPendingCarry extends PendingCarry {
  /** What the keeper last heard per send key (the row's text). */
  private readonly saved = new Map<string, { conversation: string; text: string }>();
  /** Nothing is saved before the kept rows are read (a remove then could drop another page's). */
  private loaded = false;
  /** Keeper calls not answered yet: until the app answers, a send lives only in this page. */
  private unanswered = 0;
  /** Sends the app refused to keep, with the files each took: those files stay in their trays'
   * kept entries until the send leaves (delivered or discarded), so they are never let go of
   * while nothing else holds them. */
  private readonly refused = new Map<string, readonly string[]>();

  /** `handedOver` hears the files of each send the keeper answered for (kept or refused): the
   * staged-file trays keep those files' entries until then (attachmentDrafts.ts `handedOver`). */
  constructor(
    private readonly keeper: OutboxKeeper,
    private readonly handedOver?: (hashes: readonly string[]) => void,
  ) {
    super();
  }

  /** Reads the kept sends (once, as the page starts) and shows them as not sent. */
  async load(): Promise<void> {
    const kept = await this.keeper.load().catch((): PendingSend[] => []);
    for (const entry of kept)
      this.saved.set(entry.key, { conversation: entry.conversation, text: keptText({ ...entry, failed: true }) });
    this.loaded = true;
    this.restore(kept);
    this.changed(this.entries);
  }

  protected override changed(entries: readonly PendingSend[]): void {
    if (!this.loaded) return;
    const now = new Set<string>();
    for (const entry of entries) {
      now.add(entry.key);
      const text = keptText(entry);
      if (this.saved.get(entry.key)?.text === text) continue;
      this.saved.set(entry.key, { conversation: entry.conversation, text });
      const hashes = (entry.attachments ?? []).map((part) => part.hash);
      this.unanswered += 1;
      void this.keeper.put(entry).then(
        (kept) => this.answered(entry.key, kept, hashes),
        () => this.answered(entry.key, false, hashes),
      );
    }
    for (const [key, { conversation }] of this.saved) {
      if (now.has(key)) continue;
      this.saved.delete(key);
      // A send the app never kept leaves now: its files' tray entries may go with it.
      const files = this.refused.get(key);
      this.refused.delete(key);
      if (files?.length) this.handedOver?.(files);
      const call = this.keeper.remove(conversation, key);
      if (!call) continue;
      this.unanswered += 1;
      const done = () => void (this.unanswered -= 1);
      void call.then(done, done);
    }
  }

  /** The app answered a put: a kept send's files are the outbox's now (their tray entries go); a
   * refused one says so on its row and its files stay kept by their trays until it leaves. */
  private answered(key: string, kept: boolean, hashes: readonly string[]): void {
    this.unanswered -= 1;
    this.mark(key, !kept);
    if (kept) {
      this.refused.delete(key);
      if (hashes.length) this.handedOver?.(hashes);
    } else if (this.entries.some((item) => item.key === key)) this.refused.set(key, hashes);
    else if (hashes.length) this.handedOver?.(hashes);
  }

  /** Why a web update's reload would lose a send (pages/shared/webSwap.ts), or null: a put or a
   * remove the app has not answered, or a send it refused to keep, lives only in this page. */
  holdReason = (): string | null =>
    this.unanswered > 0 ? "home.sending" : this.entries.some((entry) => entry.unkept) ? "home.send-unkept" : null;

  /** A send the app refused (or kept after all) says so on its row. */
  private mark(key: string, unkept: boolean): void {
    const entry = this.entries.find((item) => item.key === key);
    if (!entry || !!entry.unkept === unkept) return;
    this.replace(this.entries.map((item) => (item.key === key ? { ...item, unkept: unkept || undefined } : item)));
  }
}

/** The row as kept: its own fields, without the page's own marks. */
function keptText(entry: PendingSend): string {
  const { unkept: _unkept, ...row } = entry;
  return JSON.stringify(row);
}

/** The unsent sends kept by the app across launches. */
export function pageOutboxKeeper(client: PageClient): OutboxKeeper {
  return {
    async load() {
      const answer = await client.call<unknown>(OutboxOps.load, {}).catch(() => undefined);
      return parseOutbox(answer);
    },
    async put(send) {
      const { unkept: _unkept, ...row } = send;
      // Any refusal (past the size cap, OUTBOX_TOO_LARGE, or a malformed row) says so on the row.
      return client.call(OutboxOps.put, { conversation: send.conversation, send: row }).then(
        () => true,
        () => false,
      );
    },
    remove(conversation, key) {
      return answered(client.call(OutboxOps.remove, { conversation, key }));
    },
  };
}

/** The kept rows the host sent; a malformed one reads as none. */
export function parseOutbox(value: unknown): PendingSend[] {
  const pending = (value as { pending?: unknown } | null | undefined)?.pending;
  const out: PendingSend[] = [];
  if (!pending || typeof pending !== "object" || Array.isArray(pending)) return out;
  for (const [conversation, rows] of Object.entries(pending as Record<string, unknown>)) {
    if (!Array.isArray(rows)) continue;
    for (const row of rows) {
      const entry = row as Partial<PendingSend> | null;
      if (
        !entry ||
        typeof entry.key !== "string" ||
        entry.conversation !== conversation ||
        typeof entry.text !== "string" ||
        typeof entry.createdAt !== "number"
      )
        continue;
      out.push({ ...(entry as PendingSend), failed: true });
    }
  }
  return out;
}
