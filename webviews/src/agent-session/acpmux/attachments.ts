/// Files the composer attaches to a prompt. Images, PDFs and dictation's voice recordings go to
/// the agent as ACP content blocks. A text file is written into the prompt's text. Any other file (a
/// binary, a large text file) or folder goes as a link: in a chat on this Mac to where it is (the
/// host knows a dropped or pasted file's path, `chat.attach.dropped`; the page does not), else to
/// the copy the chat's host saves (`chat.upload`).
import { liftInlineImages } from "./inlineImages";
import { pastedTextBlocks } from "./pastedText";

import type { StringKey } from "./i18n";

export type ComposerAttachment = {
  id: string;
  /** `pasted`: a large paste kept as a chip (pastedText.ts), its `text` sent as a text block of its own. */
  kind: "image" | "text" | "document" | "link" | "audio" | "pasted";
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
};

export type AttachmentError = { name: string; reason: "tooLarge" | "unsupported" | "imagesUnsupported" | "tooMany" };
/// A refusal with the file it refuses, so a caller can send that file another way (a chat's upload).
export type RefusedFile = AttachmentError & { file: File; unreadable?: boolean };

export type PromptBlock =
  | { type: "text"; text: string; _meta?: { cmux: { pasted: true } } }
  | { type: "image"; mimeType: string; data: string; name?: string }
  | { type: "document"; mimeType: "application/pdf"; data: string; name?: string }
  | { type: "resource_link"; uri: string; name: string }
  | { type: "audio"; mimeType: string; data: string };

/** Anthropic's per-image limit. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
/** The longest side an attached image keeps: the models scale anything larger down to about this
 * anyway, so more pixels only grow the prompt (a six-screenshot prompt passed acpmux's 16 MiB frame
 * limit and reset the chat's connection, 2026-10-20). */
export const MAX_IMAGE_SIDE = 2000;
/** The bytes one attached image may have: past this it is re-encoded (as JPEG) or scaled down. */
export const IMAGE_BUDGET_BYTES = 1536 * 1024;
/** The bytes a PDF may have to go as a document block: its base64 (13.4 MiB) stays under acpmux's
 * 15 MiB bound on one message (#23247), below the WebSocket's 16 MiB frame, with room for the rest
 * of the prompt; the same cap as a file sent to an ssh peer (`_acpmux/file_put`). A larger PDF goes
 * as a link to its copy (intakeFiles.ts). */
export const MAX_DOCUMENT_BYTES = 10 * 1024 * 1024;
/** A text file this large is already a lot of prompt. */
export const MAX_TEXT_BYTES = 256 * 1024;
export const MAX_ATTACHMENTS = 10;
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
/// Pictures the models do not take as they are (an iPhone's HEIC, TIFF, BMP, AVIF) but the engine
/// can decode: they go as PNG or JPEG. One it cannot decode goes as a file instead.
const CONVERTIBLE_TYPES = new Set(["image/heic", "image/heif", "image/tiff", "image/bmp", "image/avif"]);
const CONVERTIBLE_NAME = /\.(heic|heif|tiff?|bmp|avif)$/i;

/// Whether `file` is a picture the composer attaches as an image (as it is, or converted), by its
/// type or name alone: what its chip looks like before its bytes are read.
export function isImageFile(file: File): boolean {
  return (
    IMAGE_TYPES.has(file.type) || CONVERTIBLE_TYPES.has(file.type) || (!file.type && CONVERTIBLE_NAME.test(file.name))
  );
}

function isPdf(file: File): boolean {
  return file.type === "application/pdf" || /\.pdf$/i.test(file.name);
}

/// Reads `files` for a composer that already holds `held` attachments.
export async function readAttachments(
  files: File[],
  held: number,
  allowImages: boolean,
): Promise<{ attachments: ComposerAttachment[]; errors: RefusedFile[] }> {
  const attachments: ComposerAttachment[] = [];
  const errors: RefusedFile[] = [];
  for (const file of files) {
    if (held + attachments.length >= MAX_ATTACHMENTS) {
      errors.push({ name: file.name, reason: "tooMany", file });
      continue;
    }
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

export async function readAttachment(file: File, allowImages: boolean): Promise<ComposerAttachment | AttachmentError> {
  const name = file.name || "file";
  const id = crypto.randomUUID();
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
    const fitted = await fitImage(file);
    // An image the engine cannot decode or scale goes as it is when the API takes it.
    if (fitted === "fits" || (fitted === undefined && file.size <= MAX_IMAGE_BYTES))
      return {
        id,
        kind: "image",
        name,
        mimeType: file.type,
        size: file.size,
        data: base64(new Uint8Array(await file.arrayBuffer())),
      };
    if (!fitted) return { name, reason: "tooLarge" };
    return {
      id,
      kind: "image",
      name: name.replace(/(\.[^./]*)?$/, fitted.mimeType === "image/jpeg" ? ".jpg" : ".png"),
      mimeType: fitted.mimeType,
      size: fitted.bytes.length,
      data: base64(fitted.bytes),
    };
  }
  if (CONVERTIBLE_TYPES.has(file.type) || (!file.type && CONVERTIBLE_NAME.test(name))) {
    if (!allowImages) return { name, reason: "imagesUnsupported" };
    const converted = await fitImage(file, true);
    if (!converted || converted === "fits") return { name, reason: "unsupported" };
    return {
      id,
      kind: "image",
      name: name.replace(/(\.[^./]*)?$/, converted.mimeType === "image/jpeg" ? ".jpg" : ".png"),
      mimeType: converted.mimeType,
      size: converted.bytes.length,
      data: base64(converted.bytes),
    };
  }
  if (file.size > MAX_TEXT_BYTES) return { name, reason: "tooLarge" };
  const text = decodeText(new Uint8Array(await file.arrayBuffer()));
  if (text === undefined) return { name, reason: "unsupported" };
  return { id, kind: "text", name, mimeType: file.type || "text/plain", size: file.size, text };
}

/// The steps an image that does not fit takes, in order: its longest side, then the JPEG quality.
/// A PNG source tries PNG at each side first (a screenshot's text stays sharp). The last step is
/// far under MAX_IMAGE_BYTES for any real picture, so an image is not refused for its size.
const FIT_STEPS = [
  { side: MAX_IMAGE_SIDE, quality: 0.9 },
  { side: MAX_IMAGE_SIDE, quality: 0.8 },
  { side: 1600, quality: 0.8 },
  { side: 1200, quality: 0.75 },
  { side: 800, quality: 0.7 },
] as const;

/// An image whose longest side is over MAX_IMAGE_SIDE or whose bytes are over IMAGE_BUDGET_BYTES,
/// scaled and re-encoded by FIT_STEPS until it is under the budget: as PNG when that fits, else as
/// JPEG (on white, which has no alpha). A JPEG source skips the PNG tries; an animated GIF or WebP
/// keeps its first frame. "fits" for an image that is already within both bounds (an animated GIF
/// stays animated), unless `convert` (a type the models do not take) re-encodes it anyway;
/// undefined when the engine cannot decode or scale it.
async function fitImage(
  file: Blob,
  convert = false,
): Promise<{ mimeType: "image/png" | "image/jpeg"; bytes: Uint8Array } | "fits" | undefined> {
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas !== "function") return undefined;
  let bitmap: ImageBitmap | undefined;
  try {
    bitmap = await createImageBitmap(file);
    const longest = Math.max(bitmap.width, bitmap.height, 1);
    if (!convert && longest <= MAX_IMAGE_SIDE && file.size <= IMAGE_BUDGET_BYTES) return "fits";
    let last: Blob | undefined;
    let triedPng = 0;
    for (const step of FIT_STEPS) {
      const scale = Math.min(1, step.side / longest);
      const width = Math.max(1, Math.round(bitmap.width * scale));
      const height = Math.max(1, Math.round(bitmap.height * scale));
      if (file.type !== "image/jpeg" && triedPng !== width) {
        triedPng = width;
        const canvas = new OffscreenCanvas(width, height);
        const context = canvas.getContext("2d");
        if (!context) return undefined;
        context.drawImage(bitmap, 0, 0, width, height);
        const png = await canvas.convertToBlob({ type: "image/png" });
        if (png.size <= IMAGE_BUDGET_BYTES)
          return { mimeType: "image/png", bytes: new Uint8Array(await png.arrayBuffer()) };
      }
      const flat = new OffscreenCanvas(width, height);
      const context = flat.getContext("2d");
      if (!context) return undefined;
      context.fillStyle = "#fff";
      context.fillRect(0, 0, width, height);
      context.drawImage(bitmap, 0, 0, width, height);
      last = await flat.convertToBlob({ type: "image/jpeg", quality: step.quality });
      if (last.size <= IMAGE_BUDGET_BYTES)
        return { mimeType: "image/jpeg", bytes: new Uint8Array(await last.arrayBuffer()) };
    }
    // Past every step (noise no encoder shrinks): the smallest try, which the API still takes.
    return last && Math.ceil(last.size / 3) * 4 <= MAX_IMAGE_BYTES
      ? { mimeType: "image/jpeg", bytes: new Uint8Array(await last.arrayBuffer()) }
      : undefined;
  } catch {
    return undefined;
  } finally {
    bitmap?.close();
  }
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

/// A thumbnail of an image attachment `height`px tall (as a data: URL), in the image's own shape
/// between 0.7:1 and 2:1, its center cropped only past those bounds, so a wide screenshot shows as
/// itself rather than a sliver of its text (Leo, 2026-10-14) and a chip never hands a
/// multi-megabyte image to a small <img>, with the image's natural size (its hover name says it).
/// Undefined when the engine cannot decode the image or has no OffscreenCanvas; the chip then draws
/// the image itself.
export async function thumbnail(
  image: { mimeType: string; data: string },
  height = 160,
): Promise<{ url: string; width: number; height: number } | undefined> {
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas !== "function") return undefined;
  try {
    const bytes = Uint8Array.from(atob(image.data), (char) => char.charCodeAt(0));
    const bitmap = await createImageBitmap(new Blob([bytes], { type: image.mimeType }));
    if (!bitmap.width || !bitmap.height) {
      bitmap.close();
      return undefined;
    }
    const ratio = Math.min(2, Math.max(0.7, bitmap.width / bitmap.height));
    const [sourceWidth, sourceHeight] =
      bitmap.width / bitmap.height > ratio
        ? [bitmap.height * ratio, bitmap.height]
        : [bitmap.width, bitmap.width / ratio];
    const canvas = new OffscreenCanvas(Math.round(height * ratio), height);
    const context = canvas.getContext("2d");
    if (!context) {
      bitmap.close();
      return undefined;
    }
    context.drawImage(
      bitmap,
      (bitmap.width - sourceWidth) / 2,
      (bitmap.height - sourceHeight) / 2,
      sourceWidth,
      sourceHeight,
      0,
      0,
      canvas.width,
      canvas.height,
    );
    const natural = { width: bitmap.width, height: bitmap.height };
    bitmap.close();
    const blob = await canvas.convertToBlob({ type: "image/png" });
    return { url: `data:image/png;base64,${base64(new Uint8Array(await blob.arrayBuffer()))}`, ...natural };
  } catch {
    return undefined;
  }
}

export function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return btoa(binary);
}

/// The prompt's text with each text file appended as a fenced block under its name.
export function promptText(text: string, attachments: ComposerAttachment[]): string {
  const files = attachments
    .filter((attachment) => attachment.kind === "text")
    .map((attachment) => {
      const body = attachment.text ?? "";
      const fence = "`".repeat(Math.max(3, longestBacktickRun(body) + 1));
      return `${attachment.name}\n${fence}${fenceLanguage(attachment.name)}\n${body}${body.endsWith("\n") ? "" : "\n"}${fence}`;
    });
  return [text, ...files].filter(Boolean).join("\n\n");
}

/// ACP prompt blocks: the text (with text files) first, then each pasted text (pastedText.ts), then
/// each image, PDF, recording and file or folder link.
/// A `data:` image written into the text goes as an image block, never as text (inlineImages.ts).
export function promptBlocks(input: string, chips: ComposerAttachment[]): PromptBlock[] {
  const { text, attachments } = liftInlineImages(input, chips);
  const blocks: PromptBlock[] = [];
  const body = promptText(text, attachments);
  if (body) blocks.push({ type: "text", text: body });
  blocks.push(...pastedTextBlocks(attachments));
  for (const attachment of attachments)
    if (attachment.kind === "image" && attachment.data)
      blocks.push({ type: "image", mimeType: attachment.mimeType, data: attachment.data, name: attachment.name });
    else if (attachment.kind === "document" && attachment.data)
      blocks.push({ type: "document", mimeType: "application/pdf", data: attachment.data, name: attachment.name });
    else if (attachment.kind === "link" && attachment.path)
      blocks.push({ type: "resource_link", uri: fileUri(attachment.path), name: attachment.name });
    else if (attachment.kind === "audio" && attachment.data)
      blocks.push({ type: "audio", mimeType: attachment.mimeType, data: attachment.data });
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
    return new File([bytes], `image.${mimeType === "image/jpeg" ? "jpg" : mimeType.slice(6)}`, { type: mimeType });
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
