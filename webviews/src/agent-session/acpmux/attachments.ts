/// Files the composer attaches to a prompt. Images and PDFs go to the agent as
/// ACP content blocks. A text file is written into the prompt's text because
/// the web view never learns a dropped file's path; other files are refused.

export type ComposerAttachment = {
  id: string;
  kind: "image" | "text" | "document" | "link";
  name: string;
  mimeType: string;
  size: number;
  /** Base64 image bytes, without the data: prefix. */
  data?: string;
  /** A text file's contents. */
  text?: string;
  /** The PDF page count when its catalog can be counted cheaply. */
  pageCount?: number;
  /** A shell mode command's chip (shell/shellRuns.ts): its text is the run's output, filled when the prompt goes. */
  shellRun?: string;
  /** A link's file or folder on this computer (Attach files or folders): the agent reads it there. */
  path?: string;
};

export type AttachmentError = { name: string; reason: "tooLarge" | "unsupported" | "imagesUnsupported" | "tooMany" };

export type PromptBlock =
  | { type: "text"; text: string }
  | { type: "image"; mimeType: string; data: string; name?: string }
  | { type: "document"; mimeType: "application/pdf"; data: string; name?: string }
  | { type: "resource_link"; uri: string; name: string };

/** Anthropic's per-image limit. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
/** Keep PDF prompts bounded while leaving room for the rest of the request. */
export const MAX_DOCUMENT_BYTES = 20 * 1024 * 1024;
/** A text file this large is already a lot of prompt. */
export const MAX_TEXT_BYTES = 256 * 1024;
export const MAX_ATTACHMENTS = 10;
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

function isPdf(file: File): boolean {
  return file.type === "application/pdf" || /\.pdf$/i.test(file.name);
}

/// Reads `files` for a composer that already holds `held` attachments.
export async function readAttachments(
  files: File[],
  held: number,
  allowImages: boolean,
): Promise<{ attachments: ComposerAttachment[]; errors: AttachmentError[] }> {
  const attachments: ComposerAttachment[] = [];
  const errors: AttachmentError[] = [];
  for (const file of files) {
    if (held + attachments.length >= MAX_ATTACHMENTS) {
      errors.push({ name: file.name, reason: "tooMany" });
      continue;
    }
    // A dropped folder arrives as a File whose bytes cannot be read.
    const result = await readAttachment(file, allowImages).catch((): AttachmentError => ({
      name: file.name,
      reason: "unsupported",
    }));
    if ("reason" in result) errors.push(result);
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
    if (file.size > MAX_IMAGE_BYTES) return { name, reason: "tooLarge" };
    return {
      id,
      kind: "image",
      name,
      mimeType: file.type,
      size: file.size,
      data: base64(new Uint8Array(await file.arrayBuffer())),
    };
  }
  if (file.size > MAX_TEXT_BYTES) return { name, reason: "tooLarge" };
  const text = decodeText(new Uint8Array(await file.arrayBuffer()));
  if (text === undefined) return { name, reason: "unsupported" };
  return { id, kind: "text", name, mimeType: file.type || "text/plain", size: file.size, text };
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
/// multi-megabyte image to a small <img>. Undefined when the engine cannot decode the image or has
/// no OffscreenCanvas; the chip then draws the image itself.
export async function thumbnail(image: { mimeType: string; data: string }, height = 160): Promise<string | undefined> {
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
    bitmap.close();
    const blob = await canvas.convertToBlob({ type: "image/png" });
    return `data:image/png;base64,${base64(new Uint8Array(await blob.arrayBuffer()))}`;
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

/// ACP prompt blocks: the text (with text files) first, then each image, PDF and file or folder link.
export function promptBlocks(text: string, attachments: ComposerAttachment[]): PromptBlock[] {
  const blocks: PromptBlock[] = [];
  const body = promptText(text, attachments);
  if (body) blocks.push({ type: "text", text: body });
  for (const attachment of attachments)
    if (attachment.kind === "image" && attachment.data)
      blocks.push({ type: "image", mimeType: attachment.mimeType, data: attachment.data, name: attachment.name });
    else if (attachment.kind === "document" && attachment.data)
      blocks.push({ type: "document", mimeType: "application/pdf", data: attachment.data, name: attachment.name });
    else if (attachment.kind === "link" && attachment.path)
      blocks.push({ type: "resource_link", uri: fileUri(attachment.path), name: attachment.name });
  return blocks;
}

/// A link chip for a file or folder the host's panel chose (`chat.attach.choose`): named by its
/// last component, a folder's with a trailing slash.
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

/// `file://` and the path, each segment percent-encoded.
function fileUri(path: string): string {
  return `file://${path.split("/").map(encodeURIComponent).join("/")}`;
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

/// Whether a drag carries files, so the page takes the drop instead of navigating to it.
export function dragHasFiles(transfer: DataTransfer | null): boolean {
  return Boolean(transfer && [...transfer.types].includes("Files"));
}

/** Installs the document-level file-drop contract used by the composer. */
export function installFileDropLifecycle(
  onDrop: (files: File[]) => void,
  onActiveChange: (active: boolean) => void,
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
    onActiveChange(true);
  };
  const over = (event: DragEvent) => {
    if (!dragHasFiles(event.dataTransfer)) return;
    event.preventDefault();
    onActiveChange(true);
  };
  const leave = (event: DragEvent) => {
    if (!dragHasFiles(event.dataTransfer)) return;
    depth = Math.max(0, depth - 1);
    if (depth === 0) onActiveChange(false);
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
