// What a pasted, dropped or chosen batch of files becomes. Images, PDFs and text files are chips
// the prompt carries as ACP blocks (attachments.ts). A file no block takes (a zip, a video, an
// unknown binary, one past a block's size, or an image for an agent that takes none) goes to the
// chat's host when it saves files (`chat.upload`, cloudUploads.ts): its chip names the saved copy,
// which the prompt sends as a resource_link to its path, never as text in the prompt.
import {
  MAX_ATTACHMENTS,
  readAttachments,
  savedAttachment,
  type AttachmentError,
  type ComposerAttachment,
  type RefusedFile,
} from "../attachments";
import { MAX_UPLOAD_FILE_BYTES, MAX_UPLOAD_TOTAL_BYTES, type UploadResult } from "../cloudUploads";

/// The refusals the host's saved copy stands in for.
const SAVABLE = new Set<AttachmentError["reason"]>(["unsupported", "tooLarge", "imagesUnsupported"]);

export type IntakeOptions = {
  /// The chips the composer already holds.
  held: number;
  allowImages: boolean;
  /// The chat's host saves what the composer can't attach; absent where nothing is saved (a capture,
  /// shell mode, a chat whose host takes no uploads).
  upload?(files: File[]): Promise<UploadResult>;
};

/// The chips `files` add, and the note for what none takes: a refusal, or the host's error text.
export async function intakeFiles(
  files: File[],
  options: IntakeOptions,
): Promise<{ attachments: ComposerAttachment[]; error?: AttachmentError | { text: string } }> {
  const read = await readAttachments(files, options.held, options.allowImages);
  const room = MAX_ATTACHMENTS - options.held - read.attachments.length;
  const sendable = options.upload ? savable(read.errors, room) : [];
  const sent = sendable.length > 0 ? await options.upload?.(sendable.map((refused) => refused.file)) : undefined;
  if (sent && "error" in sent) return { attachments: read.attachments, error: { text: sent.error } };
  const saved = sent ? sent.paths.map((path, index) => savedAttachment(path, sendable[index]?.file.name ?? "")) : [];
  // What the host did not save keeps its refusal; one it would have saved but for the composer's
  // chip limit is refused for that limit.
  const full = sent !== undefined && saved.length >= room;
  const [first] = read.errors.filter((refused) => !sent || !sendable.includes(refused));
  const attachments = [...read.attachments, ...saved];
  if (!first) return { attachments };
  return { attachments, error: { name: first.name, reason: full && saves(first) ? "tooMany" : first.reason } };
}

/// Whether the host can save a refused file: a refusal it stands in for, with bytes to read (not a
/// folder), a name, and no larger than one upload takes.
function saves(refused: RefusedFile): boolean {
  return (
    SAVABLE.has(refused.reason) &&
    !refused.unreadable &&
    Boolean(refused.file.name) &&
    refused.file.size <= MAX_UPLOAD_FILE_BYTES
  );
}

/// The refused files the host can save, in order, while the composer has `room` for chips and the
/// batch stays under the upload's limits; a folder (no bytes to read) is never sent.
function savable(errors: RefusedFile[], room: number): RefusedFile[] {
  const picked: RefusedFile[] = [];
  let total = 0;
  for (const refused of errors) {
    if (picked.length >= room) break;
    if (!saves(refused) || total + refused.file.size > MAX_UPLOAD_TOTAL_BYTES) continue;
    total += refused.file.size;
    picked.push(refused);
  }
  return picked;
}
