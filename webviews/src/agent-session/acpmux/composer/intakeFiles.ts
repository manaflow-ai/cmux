// A dropped file is read by the session's own tools through its path, never copied into the
// prompt. Files without a usable path retain their existing preview and upload transport.
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
  type KnownPaths,
  filesOnce,
} from "../attachments";
import { localImagePreview, previewForFile } from "./imagePool";
import { linkedImagePath } from "../conversation/userBubbleModel";
import { isVideoName } from "./videoAttachments";
import { videoShapeOf } from "./videoShape";
import type { UploadCancelled, UploadProgressReport, UploadResult } from "../cloudUploads";

export type IntakeOptions = {
  allowImages: boolean;
  /// The host knows a local drop's paths, matched by position. Never used for another machine.
  localPaths?(files: File[]): Promise<KnownPaths | undefined>;
  /// A drop or paste may expose a clipboard image twice. Each explicit file pick is kept.
  deduplicateImages?: boolean;
  /// Session storage owns transport limits and chunking; intake imposes no file or batch cap.
  upload?(files: File[], cancelled?: UploadCancelled, progress?: UploadProgressReport): Promise<UploadResult>;
  /// Whether the person cancelled file `index` (its tile's ×): it is left out of the upload.
  cancelled?: UploadCancelled;
};

/// `final`: the host refused the upload outright (it is still asked again on its own, slowly:
/// uploadRetry.ts).
export type IntakeError = AttachmentError | { text: string; final?: boolean };

/// What happens to each file of a batch, by its index, the moment it happens: a chip never waits
/// on the rest of its batch (Leo, 2026-10-24: "the attachments, they freeze").
export type IntakeEvents = {
  /// File `index` is this chip now.
  ready?(index: number, attachment: ComposerAttachment): void;
  /// The local path lookup missed these files. Their chips now show byte preparation or transfer.
  needsBytes?(indices: number[]): void;
  /// Another chip already represents this file.
  duplicate?(index: number): void;
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
/// answers from memory; a native drop's come pushed with it, composer/dropPush.ts): past it the files
/// go as if it did not know, never held.
export const LOCAL_PATHS_DEADLINE_MS = 1500;

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
  const items = options.localPaths ? await settleWithin(options.localPaths(files), LOCAL_PATHS_DEADLINE_MS) : undefined;
  const known = items && items.length !== files.length ? alignPaths(files, items) : items;
  const images: (ComposerAttachment | undefined)[] = [];
  const links: ComposerAttachment[] = [];
  let error: IntakeError | undefined;
  const fail = (index: number, reason: IntakeError) => {
    error ??= reason;
    events.failed?.(index, reason);
  };
  const link = (index: number, chip: ComposerAttachment) => {
    links[index] = chip;
    events.ready?.(index, chip);
  };
  // Publish native links before reading anything, even when siblings have only clipboard bytes.
  const imagePaths = new Set<string>();
  const missing: number[] = [];
  files.forEach((file, index) => {
    const path = known?.[index];
    if (path) {
      if (options.deduplicateImages && !path.folder && isImageFile(file)) {
        if (imagePaths.has(path.path)) {
          events.duplicate?.(index);
          return;
        }
        imagePaths.add(path.path);
      }
      link(index, {
        ...linkAttachment(path.path, path.folder),
        ...(!path.folder && linkedImagePath({ path: path.path, mimeType: file.type })
          ? { [localImagePreview]: previewForFile(file) }
          : {}),
        mimeType: file.type || "application/octet-stream",
        size: file.size,
      });
    } else missing.push(index);
  });
  // Clipboard tools may hand the browser two copies of a screenshot. Distinct native paths
  // identify distinct files even when the contents match.
  if (missing.length === 0) return { attachments: links.filter(Boolean) };
  if (options.localPaths) events.needsBytes?.(missing);
  const pathless = missing.map((index) => files[index]!);
  const unique = options.deduplicateImages ? filesOnce(pathless) : pathless;
  const kept = Array.isArray(unique) ? unique : await unique;
  let next = 0;
  const skip = files.map((file, index) => {
    if (known?.[index]) return true;
    if (kept[next] === file) {
      next++;
      return false;
    }
    events.duplicate?.(index);
    return true;
  });
  const prepared = files.map(async (file, index) => {
    if (skip[index]) return { image: undefined, result: undefined, videoShape: undefined };
    const videoShape = isVideoName(file.name) ? ((await videoShapeOf(file)) ?? 1) : undefined;
    const result = isImageFile(file)
      ? await readAttachment(file, options.allowImages).catch(() => undefined)
      : undefined;
    const image = result && !("reason" in result) ? result : undefined;
    if (image) {
      images[index] = image;
      events.ready?.(index, image);
    }
    return { result, image, ...(videoShape ? { videoShape } : {}) };
  });
  /// What each file becomes once its own preview is made (a link, or its failure): never awaited
  /// before the batch's upload starts.
  const outcomes: Promise<void>[] = [];
  const once = (index: number, then: (made: Awaited<(typeof prepared)[number]>) => void) =>
    outcomes.push(prepared[index]!.then(then));
  const entries = await Promise.all(
    files.map(async (file, index) => {
      if (skip[index]) return;
      if (options.upload) {
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
    for (const { index, file } of waiting) {
      if (isImageFile(file)) {
        void prepared[index]!.then(() => {
          if (sending) events.uploading?.(index);
        });
      } else {
        events.uploading?.(index);
      }
    }
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
        const { image, videoShape } = await prepared[index]!;
        // A later file may fail after earlier files finished. Keep every returned path, even when
        // the batch also carries an error, so completed uploads remain attachable and only the
        // failed/unattempted chips are asked again (uploadRetry.ts).
        const path = sent && "paths" in sent ? sent.paths[at] : undefined;
        if (path && image) {
          image.originalPath = path;
          image.originalName = file.name;
          events.original?.(index, path, file.name);
        } else if (path)
          link(index, {
            ...savedAttachment(path, file.name),
            mimeType: file.type || "application/octet-stream",
            size: file.size,
            ...(videoShape ? { videoShape } : {}),
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
  /// When the page took the gesture (`Date.now()`): the host answers from that gesture's own record,
  /// never a later one's with the same names (two fast pastes of screenshots).
  gestureAt?: number,
): Promise<KnownPaths | undefined> {
  try {
    const names = files.map((file) => file.name);
    const items = linkItems(
      await call("chat.attach.dropped", { kind, names, ...(gestureAt === undefined ? {} : { gestureAt }) }),
    );
    if (items.length === 0) return undefined;
    return alignPaths(files, items);
  } catch {
    return undefined;
  }
}

/// The host's `items` for `files`, by index. The host answers in the order of their names, so an
/// answer with one item per file is used as it is. Any other answer keeps each path whose last
/// component names one of the files (a folder's too, which WebKit names `<name>.zip`), and only the
/// rest go without one: a mismatch never drops the paths the host did give. It is logged, with
/// counts only (the names are the person's files).
export function alignPaths(files: readonly File[], items: readonly (LinkItem | undefined)[]): KnownPaths {
  if (items.length === files.length) return items;
  const left = items.filter((item): item is LinkItem => Boolean(item));
  const aligned = files.map((file) => {
    const at = left.findIndex((item) => namesFile(item.path, file.name));
    return at < 0 ? undefined : left.splice(at, 1)[0];
  });
  console.warn(
    `agent pane: the host gave ${items.length} paths for ${files.length} files; kept ${aligned.filter(Boolean).length} by name`,
  );
  return aligned;
}

/// Whether the page's file `name` is the file or folder at `path` (as AgentPaneDroppedPaths.named).
export function namesFile(path: string, name: string): boolean {
  const last = path.replace(/\/+$/, "").split("/").pop()?.normalize("NFC") ?? "";
  const asked = name.normalize("NFC");
  return asked === last || asked === `${last}.zip`;
}
