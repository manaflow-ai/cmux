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
// A kept file keeps its bytes too (`keeper.write`, as the native drafts kept theirs in the blob
// cache): the owner collects an upload no message names after a day, so a relaunched tray reads
// them back (`keeper.read`) and uploads them again when the upload is that old (`refresh`), and a
// send the owner refuses for a file it no longer holds (`unknown_attachment`) uploads the bytes again
// and goes on (`resend`, HomeChannelsStore `reupload`). The bytes of the files sent last stay here
// for that, at most `SENT_BYTES_BUDGET` (the app's own bound, HomeMessagesAttachmentDrafts.swift).
//
// A file a send took stays kept until the app's outbox keeps that send (`handedOver`, outbox.ts):
// the outbox then owns the bytes (HomeMessagesKept `outbox.remove` lets them go once the send is
// delivered or discarded), so a send that fails and a relaunch still find the bytes for Retry
// (`resend` reads them back from the app when this page no longer has them).
//
// Nothing leaves one owner before the next has said it saved it (round 11): a tray file counts as
// kept, and so lets a web update's reload go, only once the app answered both its entry (`put`) and
// its bytes (`write`); the native composer's file is let go of (`release`) only then; every call to
// the keeper still unanswered holds the reload too (`holdReason`).
//
// Cost: one tray per conversation that has files; a change copies only that tray, and the keeper
// hears one call per file that finished or left (not on upload progress), and the bytes of each
// finished file once.
import type { PendingAttachment } from "../../home-channels/AttachmentViews";
import type { UploadProgress } from "../../home-channels/attachmentService";
import type { HomeAttachment } from "../../home-channels/types";

const NONE: readonly PendingAttachment[] = [];

/** How many bytes of the files sent last stay in memory for `resend` (a retention budget, the
 * app's own for kept bytes: HomeMessagesAttachmentDrafts.maxTotalBytes). No file is refused for it:
 * one past it is only not kept, and the app refuses to keep a file's bytes past its own bound, which
 * keeps the part as before. */
export const SENT_BYTES_BUDGET = 50_000_000;
/** How long the owner keeps an upload no message names (home-core: collected after a day). */
export const OWNER_RETENTION_MS = 24 * 60 * 60 * 1000;
/** A restored file uploaded longer ago than this goes up again, well before the owner lets go. */
export const REFRESH_AFTER_MS = OWNER_RETENTION_MS - 4 * 60 * 60 * 1000;

/** What a web update's reload waits for (pages/shared/webSwap.ts), across every conversation. */
export type AttachmentHold = "home.uploading" | "home.attachments" | null;

/** One upload: the bytes go, with progress, until the signal aborts it. `sending` names the file
 * that goes when it is not the one attached (the app's preparation changed it): its bytes are kept. */
export type Upload = (
  signal: AbortSignal,
  progress: (progress: UploadProgress) => void,
  sending: (file: File) => void,
) => Promise<HomeAttachment>;

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
  /** The page's files whose bytes the app keeps, by conversation: hash -> when it was kept (ms). */
  files?: Record<string, Record<string, number>>;
}

/** What a keeper call answers: a promise resolves once the app holds the change (false or a
 * rejection: it did not); nothing means it holds it already (an in-page keeper). */
export type KeeperAck = Promise<unknown> | void;

/** Where the staged files are kept across launches (the app's HomeStore, host.ts), one file each. */
export interface AttachmentKeeper {
  load(): Promise<KeptAttachments>;
  /** Keeps one finished file as `conversation`'s (`at`: its place in the tray, ascending). */
  put(conversation: string, part: HomeAttachment, at: number): KeeperAck;
  /** Lets go of one of `conversation`'s files (sent, or removed from the tray). */
  remove(conversation: string, hash: string): KeeperAck;
  /** Lets go of the native composer's files the page took (their hashes). */
  release(conversation: string, migrated: readonly string[]): KeeperAck;
  /** Keeps a finished file's bytes (by its part's hash); resolves false when the app did not. */
  write?(hash: string, file: Blob): Promise<boolean>;
  /** A kept file's bytes again; undefined when the app has none. */
  read?(part: HomeAttachment): Promise<File | undefined>;
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
  /** A restored tray item: when its upload was kept (ms), until its bytes are back and it is fresh. */
  private readonly restoredAt = new Map<string, { conversation: string; at: number }>();
  /** The bytes of the files sent last, by hash, oldest first (at most SENT_BYTES_BUDGET), for `resend`. */
  private readonly sent = new Map<string, File>();
  private sentBytes = 0;
  /** Finished files whose bytes the app refused to keep (by hash): they are not kept across a
   * relaunch either, since a kept entry with no bytes cannot go up again once the owner lets go of
   * its upload. */
  private readonly bytesRefused = new Set<string>();
  /** The files a send took, by hash, with their tray's conversation, until the app's outbox keeps
   * that send (`handedOver`): their kept entries, and so their bytes, stay until then. */
  private readonly handing = new Map<string, string>();
  /** Keeper calls not answered yet (entries, bytes, removals, releases): a reload waits for them. */
  private unanswered = 0;
  /** Finished files the app has said it holds, entry and bytes both (by hash): only these count
   * as kept, and only these let the native composer's copy go. */
  private readonly durable = new Set<string>();
  /** Per hash, what the app has answered of it: its entry, its bytes. */
  private readonly answered = new Map<string, { entry: boolean; bytes: boolean }>();

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
      // The app holds these already: entry, and bytes when it has them (an entry it kept with
      // none has nothing more the page could give it).
      for (const part of parts) this.durable.add(part.hash);
      const tray = this.files(conversation);
      const back = parts
        .filter((part) => !tray.some((item) => item.part?.hash === part.hash))
        .map((part) => this.restored(part));
      this.trays.set(conversation, [...back, ...tray]);
    }
    this.legacy = kept.legacy;
    this.write(undefined);
    this.migrate();
    await this.readBack(kept.files ?? {});
  }

  /** Reads the kept files' bytes back into their tray items, one file at a time; each with bytes
   * and an old upload goes up again once the store can upload (`refresh`). */
  private async readBack(files: Record<string, Record<string, number>>): Promise<void> {
    const read = this.keeper?.read;
    if (!read) return;
    for (const [conversation, times] of Object.entries(files)) {
      for (const [hash, at] of Object.entries(times)) {
        const item = this.files(conversation).find((entry) => entry.part?.hash === hash && entry.file.size === 0);
        if (!item?.part) continue;
        const file = await read(item.part).catch(() => undefined);
        if (!file || file.size !== item.part.byteCount) continue;
        this.patch(conversation, item.id, { file });
        this.restoredAt.set(item.id, { conversation, at });
      }
    }
    this.refresh();
  }

  /** The restored files uploaded longer ago than REFRESH_AFTER_MS go up again from their bytes,
   * quietly: the tray keeps the part it has (Send stays on), and a failure leaves it as it was. */
  private refresh(): void {
    const upload = this.upload;
    if (!upload) return;
    const now = Date.now();
    for (const [id, { conversation, at }] of this.restoredAt) {
      this.restoredAt.delete(id);
      if (now - at < REFRESH_AFTER_MS) continue;
      const item = this.files(conversation).find((entry) => entry.id === id);
      if (!item?.part || item.file.size !== item.part.byteCount) continue;
      const controller = new AbortController();
      this.uploads.set(id, controller);
      upload
        .run(conversation, item.file, controller.signal, () => {})
        .then(
          (part) => this.patch(conversation, id, { part }),
          () => {},
        )
        .finally(() => {
          if (this.uploads.get(id) === controller) this.uploads.delete(id);
        });
    }
  }

  /** A send the owner refused for files it no longer holds: uploads their bytes again (the files
   * sent last, or still in a tray) and returns the parts to send; undefined when a file's bytes are
   * not here or the store cannot upload. */
  async resend(
    conversation: string,
    parts: readonly HomeAttachment[],
    signal: AbortSignal,
  ): Promise<HomeAttachment[] | undefined> {
    const upload = this.upload;
    if (!upload) return undefined;
    const files: File[] = [];
    for (const part of parts) {
      const file = this.bytesOf(part) ?? (await this.keptBytes(part));
      if (!file) return undefined;
      files.push(file);
    }
    const out: HomeAttachment[] = [];
    for (const file of files) out.push(await upload.run(conversation, file, signal, () => {}));
    return out;
  }

  /** A sent file's bytes as the app keeps them (the outbox owns them after a relaunch). */
  private async keptBytes(part: HomeAttachment): Promise<File | undefined> {
    if (part.byteCount <= 0) return undefined;
    const file = await this.keeper?.read?.(part).catch(() => undefined);
    return file && file.size === part.byteCount ? file : undefined;
  }

  private bytesOf(part: HomeAttachment): File | undefined {
    const sent = this.sent.get(part.hash);
    if (sent) return sent;
    for (const tray of this.trays.values())
      for (const item of tray)
        if (item.part?.hash === part.hash && item.file.size === part.byteCount && part.byteCount > 0) return item.file;
    return undefined;
  }

  /** Keeps a sent file's bytes for `resend`, dropping the oldest past SENT_BYTES_BUDGET. */
  private keepSent(item: PendingAttachment): void {
    const part = item.part;
    if (!part || item.file.size !== part.byteCount || part.byteCount === 0 || part.byteCount > SENT_BYTES_BUDGET)
      return;
    const old = this.sent.get(part.hash);
    if (old) {
      this.sent.delete(part.hash);
      this.sentBytes -= old.size;
    }
    this.sent.set(part.hash, item.file);
    this.sentBytes += item.file.size;
    for (const [hash, file] of this.sent) {
      if (this.sentBytes <= SENT_BYTES_BUDGET) break;
      this.sent.delete(hash);
      this.sentBytes -= file.size;
    }
  }

  /** The upload the files take (the latest store's: a reconnect's remount brings a new store and
   * connection); the native composer's files go once both it and the kept files are here. */
  uploadLegacy(run: ConversationUpload, failed: string): void {
    this.upload = { run, failed };
    this.migrate();
    this.refresh();
  }

  private migrate(): void {
    const legacy = this.legacy;
    const upload = this.upload;
    if (!legacy || !upload) return;
    this.legacy = undefined;
    for (const [conversation, files] of Object.entries(legacy)) {
      for (const kept of files) {
        const same = this.files(conversation).find((item) => item.part?.hash === kept.hash);
        if (same) {
          // Already the app's as the page's file: the native copy may go (else at a later launch).
          if (this.durable.has(kept.hash)) this.release(conversation, kept.hash);
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
    upload(
      controller.signal,
      (progress) => this.patch(conversation, id, { progress }),
      (sending) => this.patch(conversation, id, { file: sending }),
    )
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
    for (const item of taken) {
      this.keepSent(item);
      if (item.part) this.handing.set(item.part.hash, conversation);
    }
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
    for (const item of items) if (item.part) this.handing.delete(item.part.hash);
    if (back.length) this.write(conversation, [...back, ...tray]);
  }

  /** The app's outbox kept (or refused) the send that took these files: their tray entries go
   * now, and the outbox owns the bytes until that send is delivered or discarded. */
  handedOver(hashes: readonly string[]): void {
    const touched = new Set<string>();
    for (const hash of hashes) {
      const conversation = this.handing.get(hash);
      if (conversation === undefined) continue;
      this.handing.delete(hash);
      touched.add(conversation);
    }
    if (this.loaded) for (const conversation of touched) this.save(conversation);
  }

  /** `from`'s finished files go to `to`'s tray after its own (one per hash), and `from`'s tray
   * empties: a gone conversation's files follow the live Chief that replaced it (nav `carry`).
   * Files still uploading or failed stay behind with their upload. Returns how many went. */
  carry(from: string, to: string): number {
    if (from === to) return 0;
    const own = this.files(to);
    const moving = this.files(from).filter((item) => item.part);
    if (!moving.length) return 0;
    const hashes = new Set(own.flatMap((item) => (item.part ? [item.part.hash] : [])));
    const added = moving.filter((item) => item.part && !hashes.has(item.part.hash));
    this.write(
      from,
      this.files(from).filter((item) => !item.part),
    );
    if (added.length) this.write(to, [...own, ...added]);
    return moving.length;
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
    if (this.loaded && this.keeper) {
      const changed =
        conversation !== undefined
          ? [conversation]
          : [...new Set([...this.trays.keys(), ...this.saved.keys(), ...this.released.keys()])];
      for (const id of changed) this.save(id);
    }
    this.publish();
  }

  /** Works out the hold and tells the listeners. A file counts as kept only once the app answered
   * its entry and its bytes (`durable`); until every keeper call is answered nothing is sure. */
  private publish(): void {
    let uploading = false;
    let unkept = this.unanswered > 0;
    for (const items of this.trays.values()) {
      if (items.some((item) => !item.part && !item.error)) uploading = true;
      if (!this.keeper || items.some((item) => !item.part || !this.durable.has(item.part.hash))) unkept = true;
    }
    this.hold = uploading
      ? "home.uploading"
      : unkept && (this.trays.size || this.unanswered)
        ? "home.attachments"
        : null;
    for (const listener of this.listeners) listener();
  }

  /** Waits for one keeper call's answer (holding the reload until it comes); `done` hears whether
   * the app holds the change. */
  private ack(call: KeeperAck, done?: (held: boolean) => void): void {
    if (!call) {
      done?.(true);
      return;
    }
    this.unanswered += 1;
    void call.then(
      (answer) => {
        this.unanswered -= 1;
        done?.(answer !== false);
        this.publish();
      },
      () => {
        this.unanswered -= 1;
        done?.(false);
        this.publish();
      },
    );
  }

  /** The app answered part of `hash`'s keeping: once entry and bytes are both held it is durable,
   * and the native composer's copy of it may go (`save` releases it then). */
  private answer(conversation: string, hash: string, change: Partial<{ entry: boolean; bytes: boolean }>): void {
    const now = { ...(this.answered.get(hash) ?? { entry: false, bytes: false }), ...change };
    this.answered.set(hash, now);
    if (!now.entry || !now.bytes || this.durable.has(hash)) return;
    this.durable.add(hash);
    this.save(conversation);
  }

  /** The app refused `hash`'s bytes: its kept entry goes, and the tray counts it as not kept. */
  private refuseBytes(conversation: string, hash: string): void {
    if (this.bytesRefused.has(hash)) return;
    this.bytesRefused.add(hash);
    this.write(conversation, this.files(conversation));
  }

  private save(conversation: string): void {
    const keeper = this.keeper;
    if (!keeper) return;
    const tray = this.files(conversation);
    for (const item of tray) {
      const hash = this.legacyOf.get(item.id);
      // The native composer's copy goes only once the page's copy is the app's, entry and bytes.
      if (hash && item.part && this.durable.has(item.part.hash)) this.release(conversation, hash);
    }
    const saved = this.saved.get(conversation) ?? new Set<string>();
    const now = new Set<string>();
    for (const item of tray) {
      if (!item.part || this.bytesRefused.has(item.part.hash)) continue;
      now.add(item.part.hash);
      if (saved.has(item.part.hash)) continue;
      saved.add(item.part.hash);
      const hash = item.part.hash;
      this.ack(keeper.put(conversation, item.part, this.at++), (held) => {
        if (held) this.answer(conversation, hash, { entry: true });
      });
      // Its bytes too (after the entry, so the app never takes them for a page's leftovers). The app
      // keeps them within its own bound and refuses past it: then the entry goes too (below), so a
      // relaunch never restores a file with no bytes, and the tray says it is not kept. Until the
      // app answers, the file is not kept: the reload waits (round 11 F2).
      if (keeper.write && item.file.size === item.part.byteCount && item.file.size > 0)
        this.ack(keeper.write(hash, item.file), (kept) => {
          if (kept) this.answer(conversation, hash, { bytes: true });
          else this.refuseBytes(conversation, hash);
        });
      else if (!keeper.write) this.answer(conversation, hash, { bytes: true });
    }
    for (const hash of saved) {
      if (now.has(hash) || this.handing.has(hash)) continue;
      saved.delete(hash);
      this.durable.delete(hash);
      this.answered.delete(hash);
      this.ack(keeper.remove(conversation, hash));
    }
    if (saved.size) this.saved.set(conversation, saved);
    else this.saved.delete(conversation);
    const sent = this.releasedSent.get(conversation) ?? new Set<string>();
    const migrated = [...(this.released.get(conversation) ?? [])].filter((hash) => !sent.has(hash));
    if (!migrated.length) return;
    for (const hash of migrated) sent.add(hash);
    this.releasedSent.set(conversation, sent);
    this.ack(keeper.release(conversation, migrated));
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
