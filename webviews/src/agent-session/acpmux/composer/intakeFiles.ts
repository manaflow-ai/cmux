// What a pasted, dropped or chosen batch of files becomes. Images, PDFs and text files are chips
// the prompt carries as ACP blocks (attachments.ts). A file no block takes (a zip, a video, an
// unknown binary, one past a block's size, or an image for an agent that takes none) and a folder
// go as a resource_link, never as text in the prompt: in a chat on this Mac to where they are (the
// host's record of the drop or paste, `chat.attach.dropped`), else to the copy the chat's host
// saves when it saves files (`chat.upload`, cloudUploads.ts). A folder has no copy.
import {
  MAX_ATTACHMENTS,
  linkAttachment,
  linkItems,
  readAttachments,
  savedAttachment,
  type AttachmentError,
  type ComposerAttachment,
  type DroppedKind,
  type LinkItem,
  type RefusedFile,
} from "../attachments";
import { MAX_UPLOAD_FILE_BYTES, MAX_UPLOAD_TOTAL_BYTES, type UploadResult } from "../cloudUploads";
import { isVideoFile, videoPoster, type VideoPoster } from "./videoPoster";

/// The refusals a link stands in for.
const LINKABLE = new Set<AttachmentError["reason"]>(["unsupported", "tooLarge", "imagesUnsupported"]);

export type IntakeOptions = {
  /// The chips the composer already holds.
  held: number;
  allowImages: boolean;
  /// Where each file of the batch is on this Mac, in order, for a chat on this Mac (`chat.attach.dropped`);
  /// undefined or another count: the host does not know (the batch is not its drop or paste).
  localPaths?(files: File[]): Promise<LinkItem[] | undefined>;
  /// The chat's host saves what the composer can't attach; absent where nothing is saved (a capture,
  /// shell mode, a chat whose host takes no uploads).
  upload?(files: File[]): Promise<UploadResult>;
};

/// The chips `files` add, and the note for what none takes: a refusal, or the host's error text.
export async function intakeFiles(
  files: File[],
  options: IntakeOptions,
): Promise<{ attachments: ComposerAttachment[]; error?: AttachmentError | { text: string } }> {
  // Asked before the files are read (decoding and scaling photos can take seconds): the host's
  // record of the drop or paste lasts only a few.
  const paths = options.localPaths?.(files).catch(() => undefined);
  // A video's poster is drawn while the batch is read and saved; its link chip shows it.
  const posters = new Map<File, Promise<VideoPoster | undefined>>();
  for (const file of files) if (isVideoFile(file)) posters.set(file, videoPoster(file));
  const read = await readAttachments(files, options.held, options.allowImages);
  const local = await localLinks(files, read.errors, MAX_ATTACHMENTS - options.held - read.attachments.length, paths);
  const errors = read.errors.filter((refused) => !local.linked.has(refused));
  const room = MAX_ATTACHMENTS - options.held - read.attachments.length - local.linked.size;
  const sendable = options.upload ? savable(errors, room) : [];
  const sent = sendable.length > 0 ? await options.upload?.(sendable.map((refused) => refused.file)) : undefined;
  const linked = await withPosters(
    [...local.linked].map(([refused, link]) => [refused.file, link] as const),
    posters,
  );
  if (sent && "error" in sent) return { attachments: [...read.attachments, ...linked], error: { text: sent.error } };
  const saved = await withPosters(
    sent
      ? sent.paths.map((path, index) => {
          const file = sendable[index]?.file;
          return [file, savedAttachment(path, file?.name ?? "")] as const;
        })
      : [],
    posters,
  );
  // What the host did not link or save keeps its refusal; one it would have linked or saved but for
  // the composer's chip limit is refused for that limit.
  const full = sent !== undefined && saved.length >= room;
  const [first] = errors.filter((refused) => !sent || !sendable.includes(refused));
  const attachments = [...read.attachments, ...linked, ...saved];
  if (!first) return { attachments };
  const overLimit = (local.full && links(first)) || (full && saves(first));
  return { attachments, error: { name: first.name, reason: overLimit ? "tooMany" : first.reason } };
}

/// Each link chip with its file's video poster, when the file is a video the engine could draw.
async function withPosters(
  links: ReadonlyArray<readonly [File | undefined, ComposerAttachment]>,
  posters: Map<File, Promise<VideoPoster | undefined>>,
): Promise<ComposerAttachment[]> {
  return Promise.all(
    links.map(async ([file, link]) => {
      const made = file && (await posters.get(file));
      return made ? { ...link, ...made } : link;
    }),
  );
}

/// The refused files of the batch that go as links to where they are on this Mac, by the host's
/// answer for the whole batch (`paths`, matched to the files by position), while the composer has `room`;
/// `full` when one was left out for the limit. None when nothing refused could be linked, or the
/// host does not know the batch.
async function localLinks(
  files: File[],
  refusals: RefusedFile[],
  room: number,
  paths: Promise<LinkItem[] | undefined> | undefined,
): Promise<{ linked: Map<RefusedFile, ComposerAttachment>; full: boolean }> {
  const linked = new Map<RefusedFile, ComposerAttachment>();
  const wanted = refusals.filter(links);
  if (!paths || wanted.length === 0) return { linked, full: false };
  const items = await paths;
  if (!items || items.length !== files.length) return { linked, full: false };
  for (const refused of wanted) {
    if (linked.size >= room) return { linked, full: true };
    const item = items[files.indexOf(refused.file)];
    if (item) linked.set(refused, linkAttachment(item.path, item.folder));
  }
  return { linked, full: false };
}

/// Whether a refused file goes as a link to where it is: a refusal a link stands in for (a folder
/// too, whose bytes can't be read).
function links(refused: RefusedFile): boolean {
  return LINKABLE.has(refused.reason);
}

/// Whether the host can save a refused file: a refusal a link stands in for, with bytes to read
/// (not a folder), a name, and no larger than one upload takes.
function saves(refused: RefusedFile): boolean {
  return (
    links(refused) && !refused.unreadable && Boolean(refused.file.name) && refused.file.size <= MAX_UPLOAD_FILE_BYTES
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
