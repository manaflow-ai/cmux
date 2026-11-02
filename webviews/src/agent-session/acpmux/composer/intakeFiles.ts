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
import type { UploadCancelled, UploadProgressReport, UploadResult } from "../cloudUploads";

export type IntakeOptions = {
  allowImages: boolean;
  /// The host knows a local drop's paths, matched by position. Never used for another machine.
  localPaths?(files: File[]): Promise<LinkItem[] | undefined>;
  /// Session storage owns transport limits and chunking; intake imposes no file or batch cap.
  upload?(files: File[], cancelled?: UploadCancelled, progress?: UploadProgressReport): Promise<UploadResult>;
  /// Whether the person cancelled file `index` (its tile's ×): it is left out of the upload.
  cancelled?: UploadCancelled;
};

/// `final`: the host refused the upload outright, so it is not tried again on its own.
export type IntakeError = AttachmentError | { text: string; final?: boolean };

/// What happens to each file of a batch, by its index, the moment it happens: a chip never waits
/// on the rest of its batch (Leo, 2026-10-24: "the attachments, they freeze").
export type IntakeEvents = {
  /// File `index` is this chip now.
  ready?(index: number, attachment: ComposerAttachment): void;
  /// File `index` could not be attached, and why.
  failed?(index: number, error: IntakeError): void;
  /// File `index` is streaming to the session's machine (a send still waits for it).
  uploading?(index: number): void;
  /// How much of file `index` reached the session's machine, 0 to 1.
  progress?(index: number, done: number): void;
  /// Image `index`, already a chip, has its original saved at `path` (the agent reads it there).
  original?(index: number, path: string, name: string): void;
  /// Image `index`, already a chip, could not have its original saved, and why: the chip still
  /// sends its preview. Never for an original whose chip was sent or removed (`cancelled`).
  originalFailed?(index: number, error: IntakeError): void;
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
  let error: IntakeError | undefined;
  const fail = (index: number, reason: IntakeError) => {
    error ??= reason;
    events.failed?.(index, reason);
  };
  const link = (index: number, chip: ComposerAttachment) => {
    links[index] = chip;
    events.ready?.(index, chip);
  };
  // Each image's preview, made beside the batch's transport: no file's upload waits for a sibling
  // image to be decoded, and a send waits only for the image itself.
  const prepared = files.map(async (file, index) => {
    const result = isImageFile(file)
      ? await readAttachment(file, options.allowImages).catch(() => undefined)
      : undefined;
    const image = result && !("reason" in result) ? result : undefined;
    if (image) {
      const path = (await known)?.[index];
      if (path) {
        image.originalPath = path.path;
        image.originalName = file.name;
      }
      images[index] = image;
      events.ready?.(index, image);
    }
    return { result, image };
  });
  /// What each file becomes once its own preview is made (a link, or its failure): never awaited
  /// before the batch's upload starts.
  const outcomes: Promise<void>[] = [];
  const once = (index: number, then: (made: Awaited<(typeof prepared)[number]>) => void) =>
    outcomes.push(prepared[index]!.then(then));
  const entries = await Promise.all(
    files.map(async (file, index) => {
      const path = (await known)?.[index];
      if (path) {
        once(index, ({ image }) => {
          if (!image)
            link(index, {
              ...linkAttachment(path.path, path.folder),
              mimeType: file.type || "application/octet-stream",
              size: file.size,
            });
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
          once(index, ({ image }) => {
            if (!image) fail(index, { name: file.name, reason: "unsupported" });
          });
          return;
        }
        return { index, file };
      } else {
        once(index, ({ result, image }) => {
          if (!image)
            fail(index, { name: file.name, reason: result && "reason" in result ? result.reason : "unsupported" });
        });
      }
    }),
  );
  // One upload for the batch, in the order the files came (the host's batch token covers them),
  // without the files cancelled meanwhile.
  const waiting = entries.filter(
    (entry): entry is { index: number; file: File } => entry !== undefined && !options.cancelled?.(entry.index),
  );
  if (waiting.length) {
    let sending = true;
    // An image's tile holds a send until its preview is made; a file's (or an image that made none)
    // streams from then on.
    for (const { index } of waiting)
      void prepared[index]!.then(() => {
        if (sending) events.uploading?.(index);
      });
    const cancelled: UploadCancelled = Object.assign((at: number) => options.cancelled?.(waiting[at]!.index) ?? false, {
      subscribe: (at: number, changed: () => void) =>
        options.cancelled?.subscribe?.(waiting[at]!.index, changed) ?? (() => {}),
    });
    const uploads = waiting.map(({ file }) => file);
    const sent = await options
      .upload?.(uploads, cancelled, (at, done) => {
        const entry = waiting[at];
        if (entry && sending) events.progress?.(entry.index, done);
      })
      .catch((failure: unknown): UploadResult => ({
        error: failure instanceof Error ? failure.message : String(failure),
      }));
    sending = false;
    // Each file is its chip (or its image's original) on its own, never after a sibling's preview.
    await Promise.all(
      waiting.map(async ({ index, file }, at) => {
        const { image } = await prepared[index]!;
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
        else if (!options.cancelled?.(index)) {
          const reason: IntakeError =
            sent && "error" in sent
              ? { text: sent.error, final: sent.final }
              : { name: file.name, reason: "unsupported" };
          if (image) events.originalFailed?.(index, reason);
          else fail(index, reason);
        }
      }),
    );
  }
  await Promise.all([...prepared, ...outcomes]);
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
