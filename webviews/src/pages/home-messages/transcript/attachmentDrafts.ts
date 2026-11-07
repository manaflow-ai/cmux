// The composer's files per conversation (HomeStore's draft attachments for the native composer):
// a file attached in one conversation stays in its tray while another conversation shows, and an
// upload still running goes on to the end, so coming back finds the finished file ready to send.
// The composer is keyed by its conversation and remounts on every switch, so the files live here,
// with the page's view state (nav.ts), not in the component.
//
// The finished files are also kept by the app (`keeper`: HomeStore's draft cache, beside the text
// drafts, host.ts), so a relaunch or a web update's reload finds them in their trays again. Each
// file is its own entry, by its hash: a file that finished is put, a file that left the tray (sent,
// removed) is removed, so two pages showing one conversation never write over each other's trays.
// The files the native composer staged come over once (`legacy`): the page uploads them into their
// trays and then tells the keeper which it took, so the app lets go of only those.
//
// Cost: one tray per conversation that has files; a change copies only that tray, and the keeper
// hears one call per file that finished or left (not on upload progress).
import type { PendingAttachment } from "../../home-channels/AttachmentViews";
import type { UploadProgress } from "../../home-channels/attachmentService";
import type { HomeAttachment } from "../../home-channels/types";

const NONE: readonly PendingAttachment[] = [];

/** What a web update's reload waits for (pages/shared/webSwap.ts), across every conversation. */
export type AttachmentHold = "home.uploading" | "home.attachments" | null;

/** One upload: the bytes go, with progress, until the signal aborts it. */
export type Upload = (signal: AbortSignal, progress: (progress: UploadProgress) => void) => Promise<HomeAttachment>;

/** A file the native composer staged, with its bytes (base64), for the page to upload. */
export interface LegacyAttachment {
  hash: string;
  name: string;
  mimeType: string;
  data: string;
}

/** What the app kept: the page's finished files and the native composer's, by conversation. */
export interface KeptAttachments {
  attachments: Record<string, HomeAttachment[]>;
  legacy: Record<string, LegacyAttachment[]>;
}

/** Where the staged files are kept across launches (the app's HomeStore, host.ts), one file each. */
export interface AttachmentKeeper {
  load(): Promise<KeptAttachments>;
  /** Keeps one finished file as `conversation`'s (`at`: its place in the tray, ascending). */
  put(conversation: string, part: HomeAttachment, at: number): void;
  /** Lets go of one of `conversation`'s files (sent, or removed from the tray). */
  remove(conversation: string, hash: string): void;
  /** Lets go of the native composer's files the page took (their hashes). */
  release(conversation: string, migrated: readonly string[]): void;
}

/** One upload to a conversation (the owner's service), for the native composer's files. */
export type ConversationUpload = (
  conversation: string,
  file: File,
  signal: AbortSignal,
  progress: (progress: UploadProgress) => void,
) => Promise<HomeAttachment>;

export class AttachmentDrafts {
  private readonly trays = new Map<string, readonly PendingAttachment[]>();
  private readonly uploads = new Map<string, AbortController>();
  private readonly listeners = new Set<() => void>();
  private next = 1;
  private hold: AttachmentHold = null;
  /** Nothing is saved until the kept files are read (a save then would drop them). */
  private loaded: boolean;
  /** The finished files the keeper holds per conversation (their hashes). */
  private readonly saved = new Map<string, Set<string>>();
  /** The native composer's files the keeper already let go of, per conversation. */
  private readonly releasedSent = new Map<string, Set<string>>();
  /** The place the next kept file takes in its tray. */
  private at = Date.now();
  /** The native composer's files, until they are uploaded (`migrate`). */
  private legacy: Record<string, LegacyAttachment[]> | undefined;
  private upload: { run: ConversationUpload; failed: string } | undefined;
  /** A tray item that came from the native composer: its hash there. */
  private readonly legacyOf = new Map<string, string>();
  /** The native composer's files the page took (finished or removed), by conversation. */
  private readonly released = new Map<string, Set<string>>();

  constructor(private readonly keeper?: AttachmentKeeper) {
    this.loaded = !keeper;
  }

  /** Reads the kept files (once, as the page starts): each goes back to its tray, ahead of any
   * attached meanwhile. */
  async load(): Promise<void> {
    if (!this.keeper || this.loaded) return;
    const kept = await this.keeper.load().catch((): KeptAttachments => ({ attachments: {}, legacy: {} }));
    this.loaded = true;
    for (const [conversation, parts] of Object.entries(kept.attachments)) {
      this.saved.set(conversation, new Set(parts.map((part) => part.hash)));
      const tray = this.files(conversation);
      const back = parts
        .filter((part) => !tray.some((item) => item.part?.hash === part.hash))
        .map((part) => this.restored(part));
      this.trays.set(conversation, [...back, ...tray]);
    }
    this.legacy = kept.legacy;
    this.write(undefined);
    this.migrate();
  }

  /** The upload the native composer's files take; they go once both it and the kept files are here. */
  uploadLegacy(run: ConversationUpload, failed: string): void {
    this.upload ??= { run, failed };
    this.migrate();
  }

  private migrate(): void {
    const legacy = this.legacy;
    const upload = this.upload;
    if (!legacy || !upload) return;
    this.legacy = undefined;
    for (const [conversation, files] of Object.entries(legacy)) {
      for (const kept of files) {
        if (this.files(conversation).some((item) => item.part?.hash === kept.hash)) {
          this.release(conversation, kept.hash);
          continue;
        }
        const file = legacyFile(kept);
        if (!file) continue;
        const id = this.add(
          conversation,
          file,
          (signal, progress) => upload.run(conversation, file, signal, progress),
          upload.failed,
        );
        this.legacyOf.set(id, kept.hash);
      }
    }
    this.write(undefined);
  }

  private restored(part: HomeAttachment): PendingAttachment {
    return {
      id: `f${this.next++}`,
      file: new File([], part.name, { type: part.mimeType }),
      progress: { sent: part.byteCount, total: part.byteCount },
      part,
    };
  }

  private release(conversation: string, hash: string): void {
    const set = this.released.get(conversation) ?? new Set<string>();
    set.add(hash);
    this.released.set(conversation, set);
  }

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
    const hash = this.legacyOf.get(id);
    if (hash) this.release(conversation, hash);
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

  /** Writes `conversation`'s tray (undefined: every tray as it is), tells the keeper what
   * finished there, and the listeners. */
  private write(conversation: string | undefined, tray: readonly PendingAttachment[] = NONE): void {
    if (conversation !== undefined) {
      if (tray.length) this.trays.set(conversation, tray);
      else this.trays.delete(conversation);
    }
    let uploading = false;
    let unkept = false;
    for (const items of this.trays.values()) {
      if (items.some((item) => !item.part && !item.error)) uploading = true;
      if (!this.keeper || items.some((item) => !item.part)) unkept = true;
    }
    this.hold = uploading ? "home.uploading" : unkept && this.trays.size ? "home.attachments" : null;
    if (this.loaded && this.keeper) {
      const changed =
        conversation !== undefined
          ? [conversation]
          : [...new Set([...this.trays.keys(), ...this.saved.keys(), ...this.released.keys()])];
      for (const id of changed) this.save(id);
    }
    for (const listener of this.listeners) listener();
  }

  private save(conversation: string): void {
    const keeper = this.keeper;
    if (!keeper) return;
    const tray = this.files(conversation);
    for (const item of tray) {
      const hash = this.legacyOf.get(item.id);
      if (hash && item.part) this.release(conversation, hash);
    }
    const saved = this.saved.get(conversation) ?? new Set<string>();
    const now = new Set<string>();
    for (const item of tray) {
      if (!item.part) continue;
      now.add(item.part.hash);
      if (saved.has(item.part.hash)) continue;
      saved.add(item.part.hash);
      keeper.put(conversation, item.part, this.at++);
    }
    for (const hash of saved) {
      if (now.has(hash)) continue;
      saved.delete(hash);
      keeper.remove(conversation, hash);
    }
    if (saved.size) this.saved.set(conversation, saved);
    else this.saved.delete(conversation);
    const sent = this.releasedSent.get(conversation) ?? new Set<string>();
    const migrated = [...(this.released.get(conversation) ?? [])].filter((hash) => !sent.has(hash));
    if (!migrated.length) return;
    for (const hash of migrated) sent.add(hash);
    this.releasedSent.set(conversation, sent);
    keeper.release(conversation, migrated);
  }
}

/** The native composer's file as a File; undefined when its bytes do not decode. */
function legacyFile(kept: LegacyAttachment): File | undefined {
  try {
    const text = atob(kept.data);
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
    return new File([bytes], kept.name, { type: kept.mimeType });
  } catch {
    return undefined;
  }
}
