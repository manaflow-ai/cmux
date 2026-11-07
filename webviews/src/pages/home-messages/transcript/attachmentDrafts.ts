// The composer's files per conversation (HomeStore's draft attachments for the native composer):
// a file attached in one conversation stays in its tray while another conversation shows, and an
// upload still running goes on to the end, so coming back finds the finished file ready to send.
// The composer is keyed by its conversation and remounts on every switch, so the files live here,
// with the page's view state (nav.ts), not in the component.
//
// Cost: one tray per conversation that has files; a change copies only that tray.
import type { PendingAttachment } from "../../home-channels/AttachmentViews";
import type { UploadProgress } from "../../home-channels/attachmentService";
import type { HomeAttachment } from "../../home-channels/types";

const NONE: readonly PendingAttachment[] = [];

/** What a web update's reload waits for (pages/shared/webSwap.ts), across every conversation. */
export type AttachmentHold = "home.uploading" | "home.attachments" | null;

/** One upload: the bytes go, with progress, until the signal aborts it. */
export type Upload = (signal: AbortSignal, progress: (progress: UploadProgress) => void) => Promise<HomeAttachment>;

export class AttachmentDrafts {
  private readonly trays = new Map<string, readonly PendingAttachment[]>();
  private readonly uploads = new Map<string, AbortController>();
  private readonly listeners = new Set<() => void>();
  private next = 1;
  private hold: AttachmentHold = null;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** `conversation`'s files, in the order they were attached (the same array until one changes). */
  files(conversation: string): readonly PendingAttachment[] {
    return this.trays.get(conversation) ?? NONE;
  }

  /** Whether a file uploads anywhere, else whether any tray has a file. */
  holdReason = (): AttachmentHold => this.hold;

  /** Adds `file` to `conversation`'s tray and starts its upload; returns its id. A failed upload
   * shows `failed` on the file. */
  add(conversation: string, file: File, upload: Upload, failed: string): string {
    const id = `f${this.next++}`;
    const controller = new AbortController();
    this.uploads.set(id, controller);
    this.write(conversation, [...this.files(conversation), { id, file, progress: { sent: 0, total: file.size } }]);
    upload(controller.signal, (progress) => this.patch(conversation, id, { progress }))
      .then(
        (part) => this.patch(conversation, id, { part }),
        () => {
          if (!controller.signal.aborted) this.patch(conversation, id, { error: failed });
        },
      )
      .finally(() => this.uploads.delete(id));
    return id;
  }

  /** Changes one file (a picture read, progress, the finished part, a failure); a removed one stays removed. */
  patch(conversation: string, id: string, patch: Partial<PendingAttachment>): void {
    const tray = this.files(conversation);
    if (!tray.some((item) => item.id === id)) return;
    this.write(
      conversation,
      tray.map((item) => (item.id === id ? { ...item, ...patch } : item)),
    );
  }

  /** The person removed a file: its upload stops. */
  remove(conversation: string, id: string): void {
    this.uploads.get(id)?.abort();
    this.uploads.delete(id);
    this.write(
      conversation,
      this.files(conversation).filter((item) => item.id !== id),
    );
  }

  /** A send took `parts`: their files leave the tray; returns them, for a refusal to give back. */
  take(conversation: string, parts: readonly HomeAttachment[]): PendingAttachment[] {
    const tray = this.files(conversation);
    const taken = tray.filter((item) => item.part && parts.includes(item.part));
    if (taken.length)
      this.write(
        conversation,
        tray.filter((item) => !taken.includes(item)),
      );
    return taken;
  }

  /** A refused send gives its files back, ahead of what was attached since. */
  giveBack(conversation: string, items: readonly PendingAttachment[]): void {
    const tray = this.files(conversation);
    const back = items.filter((item) => !tray.some((kept) => kept.id === item.id));
    if (back.length) this.write(conversation, [...back, ...tray]);
  }

  /** Every running upload stops (a composer that owns its own drafts went away). */
  abortAll(): void {
    for (const controller of this.uploads.values()) controller.abort();
    this.uploads.clear();
  }

  private write(conversation: string, tray: readonly PendingAttachment[]): void {
    if (tray.length) this.trays.set(conversation, tray);
    else this.trays.delete(conversation);
    let uploading = false;
    for (const items of this.trays.values()) if (items.some((item) => !item.part && !item.error)) uploading = true;
    this.hold = uploading ? "home.uploading" : this.trays.size ? "home.attachments" : null;
    for (const listener of this.listeners) listener();
  }
}
