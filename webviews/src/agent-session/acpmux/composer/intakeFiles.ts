// A dropped file is read by the session's own tools through its path, never copied into the
// prompt as a PDF or fenced text. Images also get a normalized preview; their originals stay
// accessible through the same session upload path (local, SSH or cloud).
import {
  isImageFile,
  linkAttachment,
  linkItems,
  readAttachment,
  savedAttachment,
  type AttachmentError,
  type ComposerAttachment,
  type DroppedKind,
  type LinkItem,
} from "../attachments";
import type { UploadResult } from "../cloudUploads";

export type IntakeOptions = {
  allowImages: boolean;
  /// The host knows a local drop's paths, matched by position. Never used for another machine.
  localPaths?(files: File[]): Promise<LinkItem[] | undefined>;
  /// Session storage owns transport limits and chunking; intake imposes no file or batch cap.
  upload?(files: File[], cancelled?: (index: number) => boolean): Promise<UploadResult>;
  /// Whether the person cancelled file `index` (its tile's ×): it is left out of the upload.
  cancelled?(index: number): boolean;
};

export type IntakeError = AttachmentError | { text: string };

/// What happens to each file of a batch, by its index, the moment it happens: a chip never waits
/// on the rest of its batch (Leo, 2026-10-24: "the attachments, they freeze").
export type IntakeEvents = {
  /// File `index` is this chip now.
  ready?(index: number, attachment: ComposerAttachment): void;
  /// File `index` could not be attached, and why.
  failed?(index: number, error: IntakeError): void;
  /// File `index` is streaming to the session's machine: its tile no longer holds a send.
  uploading?(index: number): void;
  /// Image `index`, already a chip, has its original saved at `path` (the agent reads it there).
  original?(index: number, path: string, name: string): void;
};

/// How long the host may take to say where a drop's or paste's files are (`chat.attach.dropped`
/// answers from memory): past it the files go as if it did not know, never held.
export const LOCAL_PATHS_DEADLINE_MS = 3000;

/// `promise`, or undefined once `ms` pass without it settling.
export function settleWithin<T>(promise: Promise<T>, ms: number): Promise<T | undefined> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(undefined), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        clearTimeout(timer);
        resolve(undefined);
      },
    );
  });
}

export async function intakeFiles(
  files: File[],
  options: IntakeOptions,
  events: IntakeEvents = {},
): Promise<{ attachments: ComposerAttachment[]; error?: IntakeError }> {
  // Ask while the host's record of this gesture still exists, alongside the image work; a host that
  // never answers holds nothing up past LOCAL_PATHS_DEADLINE_MS.
  const known = options.localPaths
    ? settleWithin(options.localPaths(files), LOCAL_PATHS_DEADLINE_MS).then((items) =>
        items?.length === files.length ? items : undefined,
      )
    : Promise.resolve(undefined);
  const images: (ComposerAttachment | undefined)[] = [];
  const links: (ComposerAttachment | undefined)[] = [];
  const waiting: { index: number; file: File; image?: ComposerAttachment }[] = [];
  let error: IntakeError | undefined;
  const fail = (index: number, reason: IntakeError) => {
    error ??= reason;
    events.failed?.(index, reason);
  };
  const link = (index: number, chip: ComposerAttachment) => {
    links[index] = chip;
    events.ready?.(index, chip);
  };
  await Promise.all(
    files.map(async (file, index) => {
      const result = isImageFile(file)
        ? await readAttachment(file, options.allowImages).catch(() => undefined)
        : undefined;
      const image = result && !("reason" in result) ? result : undefined;
      const path = (await known)?.[index];
      if (image) {
        if (path) {
          image.originalPath = path.path;
          image.originalName = file.name;
        }
        images[index] = image;
        events.ready?.(index, image);
      }
      if (path) {
        if (!image)
          link(index, {
            ...linkAttachment(path.path, path.folder),
            mimeType: file.type || "application/octet-stream",
            size: file.size,
          });
      } else if (options.upload) {
        // WebKit exposes folders as unreadable zero-byte Files. Do not let one prevent real files
        // in the batch from uploading. Files with bytes are left unread here for the streaming host.
        if (
          file.size === 0 &&
          !(await file.arrayBuffer().then(
            () => true,
            () => false,
          ))
        ) {
          if (!image) fail(index, { name: file.name, reason: "unsupported" });
          return;
        }
        waiting.push({ index, file, ...(image ? { image } : {}) });
      } else if (!image) {
        fail(index, { name: file.name, reason: result && "reason" in result ? result.reason : "unsupported" });
      }
    }),
  );
  if (waiting.length) {
    // One upload for the batch, in the order the files came (the host's batch token covers them),
    // without the files cancelled meanwhile.
    waiting.sort((a, b) => a.index - b.index);
    for (let at = waiting.length - 1; at >= 0; at--) if (options.cancelled?.(waiting[at]!.index)) waiting.splice(at, 1);
  }
  if (waiting.length) {
    for (const { index } of waiting) events.uploading?.(index);
    const files = waiting.map(({ file }) => file);
    const sent = await options
      .upload?.(files, (at) => options.cancelled?.(waiting[at]!.index) ?? false)
      .catch((failure: unknown): UploadResult => ({
        error: failure instanceof Error ? failure.message : String(failure),
      }));
    for (const [at, { index, file, image }] of waiting.entries()) {
      const path = sent && "paths" in sent && sent.paths.length === waiting.length ? sent.paths[at] : undefined;
      if (path && image) {
        image.originalPath = path;
        image.originalName = file.name;
        events.original?.(index, path, file.name);
      } else if (path)
        link(index, {
          ...savedAttachment(path, file.name),
          mimeType: file.type || "application/octet-stream",
          size: file.size,
        });
      else if (!image && !options.cancelled?.(index))
        fail(index, sent && "error" in sent ? { text: sent.error } : { name: file.name, reason: "unsupported" });
    }
  }
  const attachments = [...images, ...links].filter((chip): chip is ComposerAttachment => Boolean(chip));
  return { attachments, ...(error ? { error } : {}) };
}

/// The host's record of where the files of the person's last `kind` (a drop on the page or a paste)
/// are (`chat.attach.dropped`), for `files`: their items in order, undefined when the host does not
/// know them (another batch, a chat not on this Mac, an older host).
export async function droppedPaths(
  kind: DroppedKind,
  files: File[],
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): Promise<LinkItem[] | undefined> {
  try {
    const items = linkItems(await call("chat.attach.dropped", { kind, names: files.map((file) => file.name) }));
    return items.length === files.length ? items : undefined;
  } catch {
    return undefined;
  }
}
