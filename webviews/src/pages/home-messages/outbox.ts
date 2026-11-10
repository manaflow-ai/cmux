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
  /** Lets go of one send. */
  remove(conversation: string, key: string): void;
}

export class KeptPendingCarry extends PendingCarry {
  /** What the keeper last heard per send key (the row's text). */
  private readonly saved = new Map<string, { conversation: string; text: string }>();
  /** Nothing is saved before the kept rows are read (a remove then could drop another page's). */
  private loaded = false;

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
      void this.keeper.put(entry).then((kept) => {
        this.mark(entry.key, !kept);
        if (entry.attachments?.length) this.handedOver?.(entry.attachments.map((part) => part.hash));
      });
    }
    for (const [key, { conversation }] of this.saved) {
      if (now.has(key)) continue;
      this.saved.delete(key);
      this.keeper.remove(conversation, key);
    }
  }

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
      void client.call(OutboxOps.remove, { conversation, key }).catch(() => undefined);
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
