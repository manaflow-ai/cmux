/// Dropped files go to session storage and are linked from the prompt (composer/intakeFiles.ts).
/// Images get a metadata-free preview as an ACP image block plus their original session path.
/// Existing document/text chips remain readable for persisted drafts from older versions.
import { base64 } from "./composer/imageWork";
import { keepThumb, prepareImageOffThread, thumbnailOffThread } from "./composer/imagePool";
import { liftInlineImages } from "./inlineImages";
import { PASTE_FILE_CHARS, pastedTextBlocks } from "./pastedText";

import type { StringKey } from "./i18n";
import type { VideoInfo } from "./composer/videoAttachments";

export type ComposerAttachment = {
  id: string;
  /** `pasted`: a large paste kept as a chip (pastedText.ts), its `text` sent as a text block of its own. */
  kind: "image" | "text" | "document" | "link" | "audio" | "pasted";
  /** Placed in the draft by the composer: its INLINE_ATTACHMENT_MARK is in the text, in order. */
  inline?: boolean;
  name: string;
  mimeType: string;
  size: number;
  /** Base64 image, PDF or audio bytes, without the data: prefix. */
  data?: string;
  /** A text file's contents, or a pasted chip's text. */
  text?: string;
  /** The PDF page count when its catalog can be counted cheaply. */
  pageCount?: number;
  /** A shell mode command's chip (shell/shellRuns.ts): its text is the run's output, filled when the prompt goes. */
  shellRun?: string;
  /** A link's file or folder on this computer (Attach files or folders): the agent reads it there. */
  path?: string;
  /** A file the composer could not attach that the chat's host saved for the agent: its chip says it goes as a path. */
  saved?: boolean;
  /** The original image on the session's machine; the inline bytes are a metadata-free preview. */
  originalPath?: string;
  originalName?: string;
  /** A video link's poster, length and key frames, as the host read them (composer/videoAttachments.ts). */
  video?: VideoInfo;
};

export type AttachmentError = {
  name: string;
  reason: "tooLarge" | "unsupported" | "imagesUnsupported";
};
/// A refusal with the file it refuses, so a caller can send that file another way (a chat's upload).
export type RefusedFile = AttachmentError & { file: File; unreadable?: boolean };

export type PromptBlock =
  | { type: "text"; text: string; _meta?: { cmux: { pasted: true } } }
  | { type: "image"; mimeType: string; data: string; name?: string }
  | { type: "document"; mimeType: "application/pdf"; data: string; name?: string }
  | { type: "resource_link"; uri: string; name: string }
  | { type: "audio"; mimeType: string; data: string };

/** The replacement character stored in the editor for one inline attachment. */
export const INLINE_ATTACHMENT_MARK = "\uFFFC";

/// The composer's draft names each attachment placed in its text by id, between two marks: the
/// editor's inline node (composer/inlineNode.ts) is written so, a draft read back (a chat reopened,
/// a relaunch) gets the same node back, and the prompt goes so (`placeInline`). The id is
/// percent-encoded to letters, digits, `.`, `-` and `%`, so any chip's id (a UUID, a copy's `~`
/// suffix, a link's `link:/path with spaces`) reads back whole and markdown finds no syntax in it
/// (a `~` or `_` would be GFM strikethrough or emphasis). Older drafts wrote a UUID or a copy's
/// `uuid~suffix` as it is; those still read. A lone U+FFFC is the person's text.
export const INLINE_TOKEN = /\uFFFC([\w.~%-]+)\uFFFC/g;
const TOKEN_AT = /\uFFFC([\w.~%-]+)\uFFFC/y;

const encodeInlineId = (id: string) =>
  encodeURIComponent(id).replace(
    /[^A-Za-z0-9.%-]/g,
    (char) => `%${char.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`,
  );

/// A token's id as the chip has it; an id that does not decode (a stray `%`) is taken as written.
export function decodeInlineId(raw: string): string {
  if (!raw.includes("%")) return raw;
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

export function inlineToken(id: string): string {
  return `${INLINE_ATTACHMENT_MARK}${encodeInlineId(id)}${INLINE_ATTACHMENT_MARK}`;
}

/// The id of a copy pasted beside the attachment `id` names (composer/inlineNode.ts): that whole id,
/// whatever it holds (a path's own `~`), then `~copy-` and eight hex digits of its own.
export const inlineCopyId = (id: string) => `${id}~copy-${crypto.randomUUID().slice(0, 8)}`;

/// An older composer gave a UUID's copy `uuid~` and eight hex digits.
const LEGACY_COPY = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(~[0-9a-f]{8})$/;

/// The id of the attachment a copy was made from, the copy before it for a copy of a copy; undefined
/// for an id no copy was given.
export function inlineCopyParent(id: string): string | undefined {
  const copy = /~copy-[0-9a-f]{8}$/.exec(id)?.[0] ?? LEGACY_COPY.exec(id)?.[1];
  return copy === undefined ? undefined : id.slice(0, id.length - copy.length);
}

/// Whether `id` is one of the attachments a text's tokens are read against.
export type InlineKnownIds = (id: string) => boolean;

/// How a prompt's tokens are read beyond its attachments: `dropped`, the ids of attachments taken
/// out of it before it goes (a recording the model cannot hear), whose tokens go as nothing.
export type InlineReadOptions = { dropped?: InlineKnownIds };

/// The ids of the attachments placed in `text`, in its order, each once (its first place). Read
/// against `known` (the attachments' ids), a U+FFFC the person wrote before a word and a place stays
/// their text, as `placeInline` reads it. With no ids every token-shaped run is taken for a place:
/// mark `a` mark `b` mark could then be either token, and only the ids tell.
export function inlineTokenIds(text: string, known: InlineKnownIds = () => true): string[] {
  if (!text.includes(INLINE_ATTACHMENT_MARK)) return [];
  return inlineRuns(text, known).flatMap((run) => (run.type === "token" ? [run.id] : []));
}

/// A token-shaped run of a text (`inlineTokenSpans`): `known`, of an attachment's id; `place`, that
/// attachment's place (its first token); otherwise a token whose attachment is not there (gone, or
/// a second of one id).
export type InlineTokenSpan = { from: number; to: number; id: string; place: boolean; known: boolean };

const NONE_PLACED: ReadonlySet<string> = new Set();

/// The tokens in `text`, in order, read against `opens`: whether a token of `id` is an attachment's
/// place, given the ids placed before it. Every other U+FFFC is the person's text. A mark that opens
/// a token-shaped run whose closing mark opens a known id's token is the person's too, so their
/// U+FFFC before a place (`x `, U+FFFC, `before`, then the token) never takes the place's opening
/// mark, nor the opening mark of a second token of a placed id: a token is told from text by the
/// ids alone (`opens` with nothing placed), never by what was placed before it. Read against no
/// ids, mark `a` mark `b` mark could be either token: only the ids tell.
export function inlineTokenSpans(
  text: string,
  opens: (id: string, placed: ReadonlySet<string>) => boolean,
): InlineTokenSpan[] {
  const spans: InlineTokenSpan[] = [];
  if (!text.includes(INLINE_ATTACHMENT_MARK)) return spans;
  const placed = new Set<string>();
  const known = (id: string) => opens(id, NONE_PLACED);
  const tokenAt = (at: number) => {
    TOKEN_AT.lastIndex = at;
    const match = TOKEN_AT.exec(text);
    return match ? { id: decodeInlineId(match[1]!), end: at + match[0].length } : undefined;
  };
  const opensKnown = (at: number) => {
    const token = tokenAt(at);
    return token !== undefined && known(token.id);
  };
  for (let at = text.indexOf(INLINE_ATTACHMENT_MARK); at >= 0;) {
    const token = tokenAt(at);
    const isKnown = token !== undefined && known(token.id);
    if (token && (isKnown || !opensKnown(token.end - 1))) {
      const place = isKnown && opens(token.id, placed);
      spans.push({ from: at, to: token.end, id: token.id, place, known: isKnown });
      if (place) placed.add(token.id);
      at = text.indexOf(INLINE_ATTACHMENT_MARK, token.end);
    } else at = text.indexOf(INLINE_ATTACHMENT_MARK, at + 1);
  }
  return spans;
}

type InlineRun = { type: "text"; text: string } | { type: "token"; id: string };

/// `text` read against `known` (`inlineTokenSpans`): the first token of each known id is its place,
/// and every U+FFFC that is no token's is the person's text. A text that places an attachment by id
/// is the composer's, so its other tokens are stale (a second of one id, one whose attachment is
/// gone) and go as nothing. In a text that places none, a token-shaped run is the person's text
/// unless `dropped` names its id: the text alone cannot tell a stale token from words the person
/// wrote between two U+FFFC, and their words are never taken for one.
function inlineRuns(text: string, known: InlineKnownIds, dropped?: InlineKnownIds): InlineRun[] {
  if (!text.includes(INLINE_ATTACHMENT_MARK)) return text ? [{ type: "text", text }] : [];
  // Removed IDs still resolve shared delimiters; they never become attachment placements.
  const spans = inlineTokenSpans(text, (id, placed) => (known(id) || dropped?.(id) === true) && !placed.has(id));
  const composers = spans.some((span) => known(span.id));
  const runs: InlineRun[] = [];
  let words = "";
  let start = 0;
  for (const span of spans) {
    if (!span.known && !composers && !dropped?.(span.id)) continue;
    words += text.slice(start, span.from);
    start = span.to;
    if (!span.place || !known(span.id)) continue;
    if (words) runs.push({ type: "text", text: words });
    words = "";
    runs.push({ type: "token", id: span.id });
  }
  words += text.slice(start);
  if (words) runs.push({ type: "text", text: words });
  return runs;
}

const idsOf = (attachments: readonly { id: string }[]): InlineKnownIds => {
  const ids = new Set(attachments.map((attachment) => attachment.id));
  return (id) => ids.has(id);
};

const placesSome = (runs: readonly InlineRun[]) => runs.some((run) => run.type === "token");
const wordsOf = (runs: readonly InlineRun[]) => runs.map((run) => (run.type === "text" ? run.text : "")).join("");

/// Whether `input` places any of `chips` by id (`inlineToken`).
const placesById = (input: string, chips: readonly ComposerAttachment[]) =>
  input.includes(INLINE_ATTACHMENT_MARK) && placesSome(inlineRuns(input, idsOf(chips)));

/// Whether `input` was written by an older composer: one bare mark per `inline` attachment, in order.
const legacyMarks = (input: string, chips: readonly ComposerAttachment[]) => {
  const inline = chips.filter((attachment) => attachment.inline).length;
  if (!inline || !input.includes(INLINE_ATTACHMENT_MARK)) return false;
  return input.split(INLINE_ATTACHMENT_MARK).length - 1 === inline;
};

/** Whether `input` places some of `chips` in its text: by id (`inlineToken`), or, as an older
 * composer wrote it, one bare mark per `inline` attachment in order. Otherwise every U+FFFC is the
 * person's own text (a pasted object character), kept as written. */
export function hasInlineMarks(input: string, chips: readonly ComposerAttachment[]): boolean {
  return placesById(input, chips) || legacyMarks(input, chips);
}

/// The draft as it goes: each placed attachment keeps its token (`inlineToken`, by id, so the
/// person's own U+FFFC beside it stays text), those attachments first in the text's order and
/// `inline`, then the strip's in their order. A token whose attachment is gone, or a second of one
/// id, goes as nothing (`inlineRuns`), as does one of an attachment `options.dropped` names.
export function placeInline(
  text: string,
  attachments: readonly ComposerAttachment[],
  options: InlineReadOptions = {},
): { text: string; attachments: ComposerAttachment[] } {
  const byId = new Map(attachments.map((attachment) => [attachment.id, attachment]));
  const placed: ComposerAttachment[] = [];
  let out = "";
  for (const run of inlineRuns(text, (id) => byId.has(id), options.dropped)) {
    if (run.type === "text") out += run.text;
    else {
      placed.push(byId.get(run.id)!);
      out += inlineToken(run.id);
    }
  }
  const placedSet = new Set(placed);
  const strip = attachments
    .filter((attachment) => !placedSet.has(attachment))
    .map(({ inline: _, ...attachment }) => attachment);
  return { text: out, attachments: [...placed.map((attachment) => ({ ...attachment, inline: true })), ...strip] };
}

/// `attachments` with the ones placed in the text (`ids`, in its order, each by its first place, as
/// the prompt goes) in the text's order, each in the slot one of them held: the strip shows them as
/// the prompt reads. The same array when it already does.
export function orderedByMarks<T extends { id: string }>(attachments: readonly T[], ids: readonly string[]): T[] {
  const rank = new Map<string, number>();
  for (const id of ids) if (!rank.has(id)) rank.set(id, rank.size);
  const slots = attachments.flatMap((attachment, index) => (rank.has(attachment.id) ? [index] : []));
  if (slots.length < 2) return attachments as T[];
  const inOrder = slots.map((slot) => attachments[slot]!).sort((a, b) => rank.get(a.id)! - rank.get(b.id)!);
  if (inOrder.every((attachment, index) => attachment === attachments[slots[index]!])) return attachments as T[];
  const next = [...attachments];
  slots.forEach((slot, index) => {
    next[slot] = inOrder[index]!;
  });
  return next;
}

/// A prompt coming back to the composer (Edit, a failed send, a queued prompt taken back to edit)
/// in the shape it went (`placeInline`), its attachments losing `inline` (the composer's own say
/// nothing; `placeInline` sets it when the prompt goes). A prompt that places them by id comes back
/// as it is, so binding twice changes nothing. One an older composer sent, with a bare mark per
/// `inline` attachment in order, gets each mark's attachment's token. Marks that match neither are
/// the person's text and stay as they are.
export function bindMarks(
  text: string,
  attachments: readonly ComposerAttachment[],
): { text: string; attachments: ComposerAttachment[] } {
  const own = attachments.map(({ inline: _, ...attachment }) => attachment);
  if (placesById(text, attachments) || !legacyMarks(text, attachments)) return { text, attachments: own };
  const placed = attachments.filter((attachment) => attachment.inline);
  let next = 0;
  return { text: text.replaceAll(INLINE_ATTACHMENT_MARK, () => inlineToken(placed[next++]!.id)), attachments: own };
}

/// `text` without its attachments' places: for a host that keeps a draft's text and not its
/// attachments (a new chat's `chat.unsentDraft`), where no mark could find its attachment again.
/// Read against `known` (the attachments' ids) as `placeInline` reads it: the person's U+FFFC stays,
/// and a text that places none of them is theirs as written. With no ids every token-shaped run goes.
export function withoutInlineTokens(text: string, known: InlineKnownIds = () => true): string {
  return text.includes(INLINE_ATTACHMENT_MARK) ? wordsOf(inlineRuns(text, known)) : text;
}

export type OrderedDraftPart = { type: "text"; text: string } | { type: "attachment"; attachment: ComposerAttachment };

/** Anthropic's per-image limit; a preview past it is scaled down further (composer/imageWork.ts). */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export { IMAGE_BUDGET_BYTES, MAX_IMAGE_SIDE, base64 } from "./composer/imageWork";
/** The bytes a PDF may have to go as a document block: its base64 (13.4 MiB) stays under acpmux's
 * 15 MiB bound on one message (#23247), below the WebSocket's 16 MiB frame, with room for the rest
 * of the prompt; the same cap as a file sent to an ssh peer (`_acpmux/file_put`). A larger PDF goes
 * as a link to its copy (intakeFiles.ts). */
export const MAX_DOCUMENT_BYTES = 10 * 1024 * 1024;
/** A text file this large is already a lot of prompt. */
export const MAX_TEXT_BYTES = 256 * 1024;
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
/// Pictures the models do not take as they are (an iPhone's HEIC, TIFF, BMP, AVIF) but the engine
/// can decode: they go as PNG or JPEG. One it cannot decode goes as a file instead.
const CONVERTIBLE_TYPES = new Set(["image/heic", "image/heif", "image/tiff", "image/bmp", "image/avif"]);
const CONVERTIBLE_NAME = /\.(heic|heif|tiff?|bmp|avif)$/i;

/// Whether `file` is a picture the composer attaches as an image (as it is, or converted), by its
/// type or name alone: what its chip looks like before its bytes are read.
export function isImageFile(file: Pick<File, "name" | "type">): boolean {
  return (
    IMAGE_TYPES.has(file.type) || CONVERTIBLE_TYPES.has(file.type) || (!file.type && CONVERTIBLE_NAME.test(file.name))
  );
}

function isPdf(file: File): boolean {
  return file.type === "application/pdf" || /\.pdf$/i.test(file.name);
}

/// Reads every file in a batch for the composer; per-file size and type rules still apply.
export async function readAttachments(
  files: File[],
  allowImages: boolean,
): Promise<{ attachments: ComposerAttachment[]; errors: RefusedFile[] }> {
  const attachments: ComposerAttachment[] = [];
  const errors: RefusedFile[] = [];
  for (const file of files) {
    // A dropped folder arrives as a File whose bytes cannot be read.
    const result = await readAttachment(file, allowImages).catch((): RefusedFile => ({
      name: file.name,
      reason: "unsupported",
      file,
      unreadable: true,
    }));
    if ("reason" in result) errors.push({ ...result, file });
    else attachments.push(result);
  }
  return { attachments, errors };
}

export async function readAttachment(
  file: File,
  allowImages: boolean,
  id: string = crypto.randomUUID(),
): Promise<ComposerAttachment | AttachmentError> {
  const name = file.name || "file";
  if (isPdf(file)) {
    if (file.size > MAX_DOCUMENT_BYTES) return { name, reason: "tooLarge" };
    const bytes = new Uint8Array(await file.arrayBuffer());
    return {
      id,
      kind: "document",
      name,
      mimeType: "application/pdf",
      size: file.size,
      data: base64(bytes),
      pageCount: pdfPageCount(bytes),
    };
  }
  if (IMAGE_TYPES.has(file.type)) {
    if (!allowImages) return { name, reason: "imagesUnsupported" };
    // A picture the engine cannot decode is not a picture after all: it goes as a file.
    return (await imageChip(file, id, name)) ?? { name, reason: "unsupported" };
  }
  if (CONVERTIBLE_TYPES.has(file.type) || (!file.type && CONVERTIBLE_NAME.test(name))) {
    if (!allowImages) return { name, reason: "imagesUnsupported" };
    return (await imageChip(file, id, name)) ?? { name, reason: "unsupported" };
  }
  if (file.size > MAX_TEXT_BYTES) return { name, reason: "tooLarge" };
  const text = decodeText(new Uint8Array(await file.arrayBuffer()));
  if (text === undefined) return { name, reason: "unsupported" };
  return { id, kind: "text", name, mimeType: file.type || "text/plain", size: file.size, text };
}

/// An image's chip: its metadata-free preview, made off the main thread (composer/imagePool.ts),
/// with its thumbnail kept for the chip. Undefined when the engine cannot decode it.
async function imageChip(file: File, id: string, name: string): Promise<ComposerAttachment | undefined> {
  const prepared = await prepareImageOffThread(file);
  if (!prepared) return undefined;
  if (prepared.thumb) keepThumb(id, prepared.thumb);
  return {
    id,
    kind: "image",
    name: name.replace(/(\.[^./]*)?$/, prepared.mimeType === "image/jpeg" ? ".jpg" : ".png"),
    mimeType: prepared.mimeType,
    size: Math.floor((prepared.data.length * 3) / 4) - (prepared.data.match(/=*$/)?.[0].length ?? 0),
    data: prepared.data,
  };
}

/// UTF-8 text without NUL bytes, else undefined (a binary file).
export function decodeText(bytes: Uint8Array): string | undefined {
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return text.includes("\u0000") ? undefined : text;
  } catch {
    return undefined;
  }
}

/// A thumbnail of a staged image (composer/imageWork.ts), made off the main thread. Undefined when
/// the engine cannot decode the image; the chip then draws the image itself.
export const thumbnail = thumbnailOffThread;

/// The prompt's text with each text file appended as a fenced block under its name.
/// Its tokens read as `orderedDraftParts` reads them.
export function promptText(text: string, attachments: ComposerAttachment[], options: InlineReadOptions = {}): string {
  const runs = inlineRuns(text, idsOf(attachments), options.dropped);
  const visibleText =
    !placesSome(runs) && legacyMarks(text, attachments) ? text.replaceAll(INLINE_ATTACHMENT_MARK, "") : wordsOf(runs);
  const files = attachments
    .filter((attachment) => attachment.kind === "text")
    .map((attachment) => {
      const body = attachment.text ?? "";
      const fence = "`".repeat(Math.max(3, longestBacktickRun(body) + 1));
      return `${attachment.name}\n${fence}${fenceLanguage(attachment.name)}\n${body}${body.endsWith("\n") ? "" : "\n"}${fence}`;
    });
  const notes = attachments
    .filter((attachment) => attachment.kind === "link" && attachment.mimeType)
    .map(
      (attachment) =>
        // l10n-allow: text for the agent, sent in the prompt, not UI.
        `Attached file: ${attachment.name} (${attachment.mimeType}, ${attachment.size} bytes). Read the linked file with your tools.`,
    );
  return [visibleText, ...files, ...notes].filter(Boolean).join("\n\n");
}

/// ACP prompt blocks: the text (with text files) first, then each pasted text (pastedText.ts), then
/// each image, PDF, recording and file or folder link.
/// A `data:` image written into the text goes as an image block, never as text (inlineImages.ts).
/** The editor's ordered runs: each attachment at its token, by id (`placeInline`), or at its bare
 * mark as an older composer wrote it; the person's own U+FFFC stays text, and a stale token (or one
 * of an attachment `options.dropped` names) goes as nothing (`inlineRuns`). Attachments not placed
 * go after the text, in their order. */
export function orderedDraftParts(
  input: string,
  chips: readonly ComposerAttachment[],
  options: InlineReadOptions = {},
): OrderedDraftPart[] {
  const byId = new Map(chips.map((attachment) => [attachment.id, attachment]));
  const runs = inlineRuns(input, (id) => byId.has(id), options.dropped);
  if (placesSome(runs)) {
    const placed = new Set<string>();
    const parts = runs.map((run): OrderedDraftPart => {
      if (run.type === "text") return run;
      placed.add(run.id);
      return { type: "attachment", attachment: byId.get(run.id)! };
    });
    for (const attachment of chips) if (!placed.has(attachment.id)) parts.push({ type: "attachment", attachment });
    return parts;
  }
  if (!legacyMarks(input, chips)) {
    const words = wordsOf(runs);
    return words
      ? [
          { type: "text", text: words },
          ...chips.map((attachment): OrderedDraftPart => ({ type: "attachment", attachment })),
        ]
      : chips.map((attachment): OrderedDraftPart => ({ type: "attachment", attachment }));
  }
  const parts: OrderedDraftPart[] = [];
  const inline = chips.filter((attachment) => attachment.inline);
  let start = 0;
  let next = 0;
  for (let at = input.indexOf(INLINE_ATTACHMENT_MARK); at >= 0; at = input.indexOf(INLINE_ATTACHMENT_MARK, at + 1)) {
    const text = input.slice(start, at);
    if (text) parts.push({ type: "text", text });
    const attachment = inline[next++];
    if (attachment) parts.push({ type: "attachment", attachment });
    start = at + INLINE_ATTACHMENT_MARK.length;
  }
  const tail = input.slice(start);
  if (tail) parts.push({ type: "text", text: tail });
  // The attachments not placed in the text (the strip's) go after it, in their order.
  for (const attachment of chips) if (!attachment.inline) parts.push({ type: "attachment", attachment });
  return parts;
}

export function attachmentBlocks(attachment: ComposerAttachment): PromptBlock[] {
  const blocks: PromptBlock[] = [];
  if (attachment.kind === "image" && attachment.data)
    blocks.push({ type: "image", mimeType: attachment.mimeType, data: attachment.data, name: attachment.name });
  else if (attachment.kind === "document" && attachment.data)
    blocks.push({ type: "document", mimeType: "application/pdf", data: attachment.data, name: attachment.name });
  else if (attachment.kind === "audio" && attachment.data)
    blocks.push({ type: "audio", mimeType: attachment.mimeType, data: attachment.data });
  else if (attachment.kind === "link" && attachment.path)
    blocks.push({ type: "resource_link", uri: fileUri(attachment.path), name: attachment.name });
  if (attachment.kind === "image" && attachment.originalPath)
    blocks.push({
      type: "resource_link",
      uri: fileUri(attachment.originalPath),
      name: attachment.originalName ?? attachment.name,
    });
  return blocks;
}

/** ACP content in the same order as the editor. Unmarked legacy drafts keep their old shape. */
export function promptBlocks(
  input: string,
  chips: ComposerAttachment[],
  options: InlineReadOptions = {},
): PromptBlock[] {
  const { text, attachments } = liftInlineImages(input, chips);
  const runs = inlineRuns(text, idsOf(attachments), options.dropped);
  if (!placesSome(runs) && !legacyMarks(text, attachments)) {
    const blocks: PromptBlock[] = [];
    const body = promptText(text, attachments, options);
    if (body) blocks.push({ type: "text", text: body });
    blocks.push(...pastedTextBlocks(attachments));
    for (const attachment of attachments) blocks.push(...attachmentBlocks(attachment));
    return blocks;
  }
  const blocks: PromptBlock[] = [];
  for (const part of orderedDraftParts(text, attachments, options)) {
    if (part.type === "text") {
      if (part.text) blocks.push({ type: "text", text: part.text });
      continue;
    }
    if (part.attachment.kind === "text") {
      const body = promptText("", [part.attachment]);
      if (body) blocks.push({ type: "text", text: body });
    } else if (part.attachment.kind === "pasted" && part.attachment.text) {
      blocks.push({ type: "text", text: part.attachment.text, _meta: { cmux: { pasted: true } } });
    } else blocks.push(...attachmentBlocks(part.attachment));
  }
  return blocks;
}

/// A file or folder on this computer that a link chip names (``linkAttachment``).
export type LinkItem = { path: string; folder: boolean };

/// How files came in from the person's own gesture, for the host's record of where they are
/// (`chat.attach.dropped`): a drop on the page, or a paste.
export type DroppedKind = "drop" | "paste";

/// The files and folders of the host's `{items: [{path, folder}]}` answer (`chat.attach.choose`,
/// `chat.attach.dropped`), in order: absolute paths only, a folder only when the host says so.
export function linkItems(value: unknown): LinkItem[] {
  const items = (value as { items?: unknown } | null | undefined)?.items;
  if (!Array.isArray(items)) return [];
  return items.flatMap((item: unknown) => {
    const { path, folder } = (item ?? {}) as { path?: unknown; folder?: unknown };
    return typeof path === "string" && path.startsWith("/") ? [{ path, folder: folder === true }] : [];
  });
}

/// A link chip for a file or folder on this computer (the host's panel chose it,
/// `chat.attach.choose`, or the person dropped or pasted it): named by its last component, a
/// folder's with a trailing slash.
export function linkAttachment(path: string, folder: boolean): ComposerAttachment {
  const trimmed = path.replace(/\/+$/, "") || "/";
  const name = trimmed.slice(trimmed.lastIndexOf("/") + 1) || trimmed;
  return {
    id: `link:${trimmed}`,
    kind: "link",
    name: folder ? `${name}/` : name,
    mimeType: "",
    size: 0,
    path: trimmed,
  };
}

/// A link chip for a file the composer could not attach that the chat's host saved at `path` (`chat.upload`):
/// named as the person's file was, it goes as a resource_link to where the agent can read it.
export function savedAttachment(path: string, name: string): ComposerAttachment {
  const link = linkAttachment(path, false);
  return { ...link, name: name || link.name, saved: true };
}

/// `file://` and the path, each segment percent-encoded.
function fileUri(path: string): string {
  return `file://${path.split("/").map(encodeURIComponent).join("/")}`;
}

/// Whether a session takes voice input through its picked model: the harness advertises ACP
/// `promptCapabilities.audio`, and, when its model options name their input modalities
/// (`_meta.inputModalities`, cmux-codex-acp), the picked model lists `audio`; a model without a
/// list there takes none, as the harness itself rules. A harness that names no modalities at all
/// is taken at its word. A Codex model that does not hear audio would only be told the recording
/// could not be read.
export function takesAudio(promptCapabilities: unknown, configOptions: unknown): boolean {
  if ((promptCapabilities as { audio?: unknown } | undefined)?.audio !== true) return false;
  const model = Array.isArray(configOptions)
    ? (configOptions as { category?: unknown; currentValue?: unknown; options?: unknown }[]).find(
        (option) => option?.category === "model",
      )
    : undefined;
  const options = Array.isArray(model?.options)
    ? (model.options as { value?: unknown; _meta?: { inputModalities?: unknown } }[])
    : [];
  if (!options.some((option) => Array.isArray(option?._meta?.inputModalities))) return true;
  const modalities = options.find((option) => option?.value === model?.currentValue)?._meta?.inputModalities;
  return Array.isArray(modalities) && modalities.includes("audio");
}

/// The largest recording a prompt carries: the host stops keeping audio at two minutes (3.84 MB
/// of 16 kHz PCM), so this only backs that cap up. A bigger clip would go out as one huge JSON
/// line that the model's API refuses; the transcript goes alone instead.
export const MAX_AUDIO_BYTES = 4 * 1024 * 1024;

/// A dictation session's recording as a chip, for a harness that takes voice input
/// (`promptCapabilities.audio`): it goes with the prompt beside the transcript. Undefined past
/// `MAX_AUDIO_BYTES`.
export function audioAttachment(
  audio: { mimeType: string; data: string },
  name: string,
): ComposerAttachment | undefined {
  const padding = audio.data.endsWith("==") ? 2 : audio.data.endsWith("=") ? 1 : 0;
  const size = Math.floor((audio.data.length * 3) / 4) - padding;
  if (size > MAX_AUDIO_BYTES) return undefined;
  return {
    id: crypto.randomUUID(),
    kind: "audio",
    name,
    mimeType: audio.mimeType,
    size,
    data: audio.data,
  };
}

/// The notice for a recording that goes no further than its transcript: the host left it out
/// (`DictationUpdate.audioOmitted`), or `audioAttachment` refused it past `MAX_AUDIO_BYTES`
/// (`tooLarge`). The byte cap only backs up the host's two-minute stop, so both read the same.
export function recordingLeftOutNotice(reason: "tooLong" | "tooLarge" | "narrowband"): StringKey {
  return reason === "narrowband" ? "dictation.recordingNarrowband" : "dictation.recordingTooLong";
}

/** Counts PDF page objects without parsing or rendering the document. */
function pdfPageCount(bytes: Uint8Array): number | undefined {
  try {
    const source = new TextDecoder("latin1").decode(bytes);
    const count = [...source.matchAll(/\/Type\s*\/Page(?:\s|\/|>)/g)].length;
    return count > 0 ? count : undefined;
  } catch {
    return undefined;
  }
}

function longestBacktickRun(text: string): number {
  let longest = 0;
  for (const run of text.match(/`+/g) ?? []) longest = Math.max(longest, run.length);
  return longest;
}

function fenceLanguage(name: string): string {
  const dot = name.lastIndexOf(".");
  const extension = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
  return /^[a-z0-9+#-]{1,12}$/.test(extension) ? extension : "";
}

/// The files in a drop or paste.
export function filesFrom(transfer: DataTransfer | null): File[] {
  return transfer ? [...transfer.files] : [];
}

/// Whether a paste of files carries no text but their own names: files copied in a file manager
/// also put each one's name (or path, or a file: URL list) on the clipboard as text, which the
/// field must not take as a prompt. As the Home channel's composer decides (home-channels/Composer.tsx).
export function pasteIsOnlyFileNames(transfer: DataTransfer): boolean {
  if (transfer.files.length === 0) return false;
  const text = transfer.getData("text/plain");
  const names = [...transfer.files].map((file) => file.name);
  return !text || [...transfer.types].includes("text/uri-list") || names.some((name) => text.includes(name));
}

/// Smaller than this is a page's spacer or icon, not an image someone copied.
const MIN_HTML_IMAGE_BYTES = 256;

/// The `data:` images of pasted HTML (an image copied from a page or a transcript with no file on
/// the clipboard), as files the composer attaches: never markup in the prompt. Only the types an
/// agent takes, and nothing as small as a spacer GIF.
export function htmlImageFiles(html: string): File[] {
  if (!html || !/<img[\s>]/i.test(html)) return [];
  const files: File[] = [];
  for (const tag of html.match(/<img\b[^<>]*>/gi) ?? []) {
    const source = /\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i.exec(tag);
    const uri = /^data:(image\/[a-z0-9.+-]+)(?:;[^,;]+)*;base64,([a-z0-9+/=\s]+)$/i.exec(
      (source?.[1] ?? source?.[2] ?? source?.[3] ?? "").trim(),
    );
    const file = uri && imageFile(uri[1]!.toLowerCase(), uri[2]!);
    if (file) files.push(file);
  }
  return files;
}

/// The markdown `data:` images of pasted text (a prompt copied from a bubble that went out with
/// them), as files the composer attaches; `text` is what the field gets in their place.
export function textImageFiles(plain: string): { text: string; files: File[] } {
  // Text past what a prompt carries goes as a file whole (pastedChips.ts): no image is lifted out
  // of it, and scanning 100 MB for one held the paste's task 24 ms (about 70 ms on the CI runner).
  if (plain.length > PASTE_FILE_CHARS) return { text: plain, files: [] };
  const lifted = liftInlineImages(plain);
  if (!lifted.attachments.length) return { text: plain, files: [] };
  // An image written into a prompt was meant: no size floor.
  const files = lifted.attachments.flatMap((chip) => imageFile(chip.mimeType, chip.data ?? "", 1) ?? []);
  return { text: lifted.text, files };
}

/// The images a paste carries other than as files (an HTML `<img>`'s, else the plain text's), and
/// the plain text without its markdown images when it had any.
export function pastedImageFiles(transfer: DataTransfer | null): { text?: string; files: File[] } {
  const plain = transfer?.getData("text/plain") ?? "";
  const fromText = textImageFiles(plain);
  const text = fromText.text === plain ? undefined : fromText.text;
  const html = htmlImageFiles(transfer?.getData("text/html") ?? "");
  return { text, files: html.length ? html : fromText.files };
}

/// A file of base64 `data` of an image type an agent takes; none for another type, data that is not
/// base64, or an image smaller than `minimum` bytes (a spacer).
function imageFile(mimeType: string, data: string, minimum = MIN_HTML_IMAGE_BYTES): File | undefined {
  if (!IMAGE_TYPES.has(mimeType)) return undefined;
  try {
    const binary = atob(data.replace(/\s+/g, ""));
    if (binary.length < minimum) return undefined;
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    return new File([bytes], `image.${mimeType === "image/jpeg" ? "jpg" : mimeType.slice(6)}`, {
      type: mimeType,
    });
  } catch {
    // Not base64 after all: nothing to attach.
    return undefined;
  }
}

/// Whether a drag carries files, so the page takes the drop instead of navigating to it.
export function dragHasFiles(transfer: DataTransfer | null): boolean {
  return Boolean(transfer && [...transfer.types].includes("Files"));
}

/** Installs the document-level file-drop contract used by the composer. `onActiveChange` gets the
 *  drag event that changed it (none on a reset), so the drop overlay (composer/dropOverlayState.ts)
 *  can read what the drag holds and where the pointer is, and refuse it (`dropEffect`). */
export function installFileDropLifecycle(
  onDrop: (files: File[]) => void,
  onActiveChange: (active: boolean, event?: DragEvent) => void,
  target: Document = document,
  view: Window = window,
): () => void {
  let depth = 0;
  const reset = () => {
    depth = 0;
    onActiveChange(false);
  };
  const enter = (event: DragEvent) => {
    if (!dragHasFiles(event.dataTransfer)) return;
    event.preventDefault();
    depth += 1;
    onActiveChange(true, event);
  };
  const over = (event: DragEvent) => {
    if (!dragHasFiles(event.dataTransfer)) return;
    event.preventDefault();
    onActiveChange(true, event);
  };
  const leave = (event: DragEvent) => {
    if (!dragHasFiles(event.dataTransfer)) return;
    depth = Math.max(0, depth - 1);
    if (depth === 0) onActiveChange(false, event);
  };
  const drop = (event: DragEvent) => {
    if (!dragHasFiles(event.dataTransfer)) return;
    event.preventDefault();
    const files = filesFrom(event.dataTransfer);
    reset();
    onDrop(files);
  };
  target.addEventListener("dragenter", enter);
  target.addEventListener("dragover", over);
  target.addEventListener("dragleave", leave);
  target.addEventListener("drop", drop);
  target.addEventListener("dragend", reset);
  view.addEventListener("blur", reset);
  return () => {
    target.removeEventListener("dragenter", enter);
    target.removeEventListener("dragover", over);
    target.removeEventListener("dragleave", leave);
    target.removeEventListener("drop", drop);
    target.removeEventListener("dragend", reset);
    view.removeEventListener("blur", reset);
  };
}
