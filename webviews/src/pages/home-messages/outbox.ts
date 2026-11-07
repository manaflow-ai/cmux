// The Messages page's unsent sends, kept by the app across launches (`cmux.home.messages.outbox.*`,
// HomeMessagesOutbox.swift), as the native composer's durable outbox: the composer clears its
// draft the moment a send shows as pending, so a send the owner never took would be lost with the
// page. Every change of the page's pending rows is saved per conversation; a new page shows the
// kept ones again as not sent, with Retry (each keeps its idempotency key, so none goes twice).
//
// Cost: one save per conversation whose rows changed (a send, its delivery, a failure, a discard),
// none on typing; the rows are small (text and the owner's parts, never file bytes).
import { PendingCarry, type PendingSend } from "../home-channels/store";
import type { PageClient } from "../shared/pageClient";

export const OutboxOps = {
  load: "cmux.home.messages.outbox.load",
  save: "cmux.home.messages.outbox.save",
} as const;

/** Where the unsent sends are kept (the app's HomeStore). */
export interface OutboxKeeper {
  load(): Promise<PendingSend[]>;
  save(conversation: string, pending: readonly PendingSend[]): void;
}

export class KeptPendingCarry extends PendingCarry {
  /** What the keeper last heard per conversation. */
  private readonly saved = new Map<string, string>();
  /** Nothing is saved before the kept rows are read (a save then would drop them). */
  private loaded = false;

  constructor(private readonly keeper: OutboxKeeper) {
    super();
  }

  /** Reads the kept sends (once, as the page starts) and shows them as not sent. */
  async load(): Promise<void> {
    const kept = await this.keeper.load().catch((): PendingSend[] => []);
    for (const entry of kept) this.saved.set(entry.conversation, "");
    this.loaded = true;
    this.restore(kept);
    this.changed(this.entries);
  }

  protected override changed(entries: readonly PendingSend[]): void {
    if (!this.loaded) return;
    const byConversation = new Map<string, PendingSend[]>();
    for (const entry of entries) {
      const list = byConversation.get(entry.conversation) ?? [];
      list.push(entry);
      byConversation.set(entry.conversation, list);
    }
    for (const conversation of new Set([...this.saved.keys(), ...byConversation.keys()])) {
      const rows = byConversation.get(conversation) ?? [];
      const text = JSON.stringify(rows);
      if (this.saved.get(conversation) === text) continue;
      if (rows.length) this.saved.set(conversation, text);
      else this.saved.delete(conversation);
      this.keeper.save(conversation, rows);
    }
  }
}

/** The unsent sends kept by the app across launches. */
export function pageOutboxKeeper(client: PageClient): OutboxKeeper {
  return {
    async load() {
      const answer = await client.call<unknown>(OutboxOps.load, {}).catch(() => undefined);
      return parseOutbox(answer);
    },
    save(conversation, pending) {
      // An older host without the op keeps nothing; the page's rows still hold them.
      void client.call(OutboxOps.save, { conversation, pending }).catch(() => undefined);
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
