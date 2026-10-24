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
  upload?(files: File[]): Promise<UploadResult>;
};

export async function intakeFiles(
  files: File[],
  options: IntakeOptions,
  ids?: readonly string[],
): Promise<{ attachments: ComposerAttachment[]; error?: AttachmentError | { text: string } }> {
  // Ask while the host's record of this gesture still exists, before any expensive image work.
  const known = await options.localPaths?.(files).catch(() => undefined);
  const paths = known?.length === files.length ? known : undefined;
  const ordered: (ComposerAttachment | undefined)[] = Array.from({ length: files.length });
  const waiting: { file: File; index: number; image?: ComposerAttachment }[] = [];
  let error: AttachmentError | { text: string } | undefined;
  for (const [index, file] of files.entries()) {
    const path = paths?.[index];
    const result = isImageFile(file)
      ? await readAttachment(file, options.allowImages, ids?.[index]).catch(() => undefined)
      : undefined;
    const image = result && !("reason" in result) ? result : undefined;
    if (image) {
      ordered[index] = image;
    }
    if (path) {
      if (image) {
        image.originalPath = path.path;
        image.originalName = file.name;
      } else {
        const link = {
          ...linkAttachment(path.path, path.folder),
          ...(ids?.[index] ? { id: ids[index]! } : {}),
          mimeType: file.type || "application/octet-stream",
          size: file.size,
        };
        ordered[index] = link;
      }
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
        error ??= { name: file.name, reason: "unsupported" };
        continue;
      }
      waiting.push({ file, index, ...(image ? { image } : {}) });
    } else if (!image) {
      error ??= {
        name: file.name,
        reason: result && "reason" in result ? result.reason : "unsupported",
      };
    }
  }
  if (waiting.length) {
    const sent = await options.upload?.(waiting.map(({ file }) => file));
    if (sent && "error" in sent) error ??= { text: sent.error };
    else if (sent && sent.paths.length === waiting.length) {
      for (const [sentIndex, { file, index, image }] of waiting.entries()) {
        const path = sent.paths[sentIndex]!;
        if (image) {
          image.originalPath = path;
          image.originalName = file.name;
        } else
          const link = {
            ...savedAttachment(path, file.name),
            ...(ids?.[index] ? { id: ids[index]! } : {}),
            mimeType: file.type || "application/octet-stream",
            size: file.size,
          };
          ordered[index] = link;
      }
    } else if (waiting.some(({ image }) => !image)) {
      error ??= { name: waiting.find(({ image }) => !image)!.file.name, reason: "unsupported" };
    }
  }
  return { attachments: ordered.flatMap((attachment) => (attachment ? [attachment] : [])), ...(error ? { error } : {}) };
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
