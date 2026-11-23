// My Send Later messages (`conversation-scheduled-v1`, cmux#25634) in the open conversation: the
// local owner keeps the queue and sends each message at its time as me, while the app runs; the
// page only shows it and changes it. The list is read when a conversation opens and again on each
// `conversation-scheduled-changed` for it (`batch.scheduled`) or a reconnect; a change the page
// makes shows at once from the owner's answer. Rows read it through `useScheduled`.
import { useCallback, useSyncExternalStore } from "react";
import type { PageClient } from "../shared/pageClient";
import { HomeOps, type HomeAttachment, type HomeScheduleChange, type HomeScheduled } from "./types";

const NONE: readonly HomeScheduled[] = [];

const byTime = (a: HomeScheduled, b: HomeScheduled) => a.sendAt - b.sendAt || a.id.localeCompare(b.id);

export class ScheduledBook {
  private readonly lists = new Map<string, readonly HomeScheduled[]>();
  /** The conversation the page shows: the only one whose list is kept current. */
  private watched: string | undefined;
  /** Bumped per read of a conversation: an older read that answers late is dropped. */
  private readonly reads = new Map<string, number>();
  private readonly listeners = new Set<() => void>();
  private nextKey = 0;

  constructor(
    private readonly client: PageClient | null,
    /** A refused change: the page shows the owner's reason. */
    private readonly fail: (error: unknown) => void,
  ) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  list(conversation: string | undefined): readonly HomeScheduled[] {
    return (conversation && this.lists.get(conversation)) || NONE;
  }

  /** The page opened `conversation`: its list is read now and kept current. */
  watch(conversation: string | undefined): void {
    if (conversation === this.watched) return;
    if (this.watched) this.lists.delete(this.watched);
    this.watched = conversation;
    if (conversation) void this.load(conversation);
  }

  /** The owner said these conversations' lists changed (or, with none, that the page reconnected). */
  changed(conversations?: readonly string[]): void {
    if (this.watched && (!conversations || conversations.includes(this.watched))) void this.load(this.watched);
  }

  /** Queues a message for `sendAt` (ms); resolves true when the owner took it. */
  async create(
    conversation: string,
    text: string,
    sendAt: number,
    attachments?: readonly HomeAttachment[],
    threadRoot?: string,
    replyTo?: string,
  ): Promise<boolean> {
    const change: HomeScheduleChange = {
      kind: "create",
      conversation,
      text,
      sendAt,
      ...(attachments?.length ? { attachments } : {}),
      ...(threadRoot ? { threadRoot } : {}),
      ...(replyTo ? { replyTo } : {}),
    };
    // One key per press: a repeat of the same request is the same message on the owner.
    return this.change(change, `later-${Date.now().toString(36)}-${this.nextKey++}`);
  }

  reschedule(entry: HomeScheduled, sendAt: number): Promise<boolean> {
    return this.change({ kind: "update", id: entry.id, sendAt });
  }

  edit(entry: HomeScheduled, text: string): Promise<boolean> {
    return this.change({ kind: "update", id: entry.id, text });
  }

  cancel(entry: HomeScheduled): Promise<boolean> {
    return this.change({ kind: "cancel", id: entry.id }, undefined, entry);
  }

  sendNow(entry: HomeScheduled): Promise<boolean> {
    return this.change({ kind: "sendNow", id: entry.id }, undefined, entry);
  }

  private async change(change: HomeScheduleChange, key?: string, removing?: HomeScheduled): Promise<boolean> {
    if (!this.client) return false;
    try {
      const reply = await this.client.call<{ scheduled?: HomeScheduled }>(HomeOps.schedule, {
        ...change,
        ...(key ? { idempotencyKey: key } : {}),
      });
      if (reply.scheduled) this.put(reply.scheduled);
      else if (removing) this.remove(removing);
      return true;
    } catch (error) {
      this.fail(error);
      return false;
    }
  }

  private put(entry: HomeScheduled): void {
    if (entry.conversation !== this.watched) return;
    const rest = this.list(entry.conversation).filter((held) => held.id !== entry.id);
    this.supersedeReads(entry.conversation);
    this.lists.set(entry.conversation, [...rest, entry].sort(byTime));
    this.notify();
  }

  private remove(entry: HomeScheduled): void {
    const list = this.list(entry.conversation);
    if (!list.some((held) => held.id === entry.id)) return;
    this.supersedeReads(entry.conversation);
    this.lists.set(
      entry.conversation,
      list.filter((held) => held.id !== entry.id),
    );
    this.notify();
  }

  /** A read that started before a change answers with the list before it: drop it (the change's event reads again). */
  private supersedeReads(conversation: string): void {
    this.reads.set(conversation, (this.reads.get(conversation) ?? 0) + 1);
  }

  private async load(conversation: string): Promise<void> {
    if (!this.client) return;
    const read = (this.reads.get(conversation) ?? 0) + 1;
    this.reads.set(conversation, read);
    try {
      const reply = await this.client.call<{ scheduled?: HomeScheduled[] }>(HomeOps.scheduled, { conversation });
      if (this.reads.get(conversation) !== read || conversation !== this.watched) return;
      this.lists.set(conversation, [...(reply.scheduled ?? [])].sort(byTime));
      this.notify();
    } catch {
      // An owner without Send Later (or a read that failed) shows no list; the next change reads again.
    }
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }
}

/** My scheduled messages in `conversation`, by send time. */
export function useScheduled(book: ScheduledBook, conversation: string | undefined): readonly HomeScheduled[] {
  const read = useCallback(() => book.list(conversation), [book, conversation]);
  return useSyncExternalStore(book.subscribe, read, read);
}
