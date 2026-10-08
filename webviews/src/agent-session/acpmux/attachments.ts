/// Files the composer attaches to a prompt. Images go to the agent as ACP
/// image blocks. A text file is written into the prompt's text, because the
/// web view never learns a dropped file's path and the Claude adapter does not
/// pass resource blocks yet; other files are refused.

export type ComposerAttachment = {
  id: string;
  kind: "image" | "text";
  name: string;
  mimeType: string;
  size: number;
  /** Base64 image bytes, without the data: prefix. */
  data?: string;
  /** A text file's contents. */
  text?: string;
  /** A shell mode command's chip (shell/shellRuns.ts): its text is the run's output, filled when the prompt goes. */
  shellRun?: string;
  /** A location row move's chip (shell/chatMoves.ts); a newer move replaces it. */
  move?: boolean;
};

export type AttachmentError = { name: string; reason: "tooLarge" | "unsupported" | "imagesUnsupported" | "tooMany" };

export type PromptBlock = { type: "text"; text: string } | { type: "image"; mimeType: string; data: string };

/** Anthropic's per-image limit. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
/** A text file this large is already a lot of prompt. */
export const MAX_TEXT_BYTES = 256 * 1024;
export const MAX_ATTACHMENTS = 10;
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

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

function base64(bytes: Uint8Array): string {
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

/// ACP prompt blocks: the text (with text files) first, then each image.
export function promptBlocks(text: string, attachments: ComposerAttachment[]): PromptBlock[] {
  const blocks: PromptBlock[] = [];
  const body = promptText(text, attachments);
  if (body) blocks.push({ type: "text", text: body });
  for (const attachment of attachments)
    if (attachment.kind === "image" && attachment.data)
      blocks.push({ type: "image", mimeType: attachment.mimeType, data: attachment.data });
  return blocks;
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
