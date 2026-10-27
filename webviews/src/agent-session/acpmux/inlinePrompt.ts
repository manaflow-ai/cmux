import {
  attachmentBlocks,
  hasInlineMarks,
  inlineToken,
  orderedDraftParts,
  promptText,
  type ComposerAttachment,
  type PromptBlock,
} from "./attachments";
import type { AcpmuxRow, PromptContentPart } from "./model";
import { parseVideoInfo } from "./composer/videoAttachments";
type DisplayPart = {
  kind: string;
  blockIndex: number;
  name: string;
  mimeType?: string;
  size?: number;
  pageCount?: number;
  companionOf?: number;
};
export function inlinePrompt(input: string, attachments: ComposerAttachment[]) {
  if (!hasInlineMarks(input, attachments)) return undefined;
  const parts: PromptContentPart[] = [];
  const display: DisplayPart[] = [];
  let blockIndex = 0;
  for (const run of orderedDraftParts(input, attachments)) {
    if (run.type === "text") {
      if (run.text) {
        parts.push({ kind: "text", text: run.text });
        blockIndex += 1;
      }
      continue;
    }
    const a = run.attachment;
    const kind = a.kind === "link" || a.kind === "text" ? "file" : a.kind;
    const text = a.kind === "text" ? promptText("", [a]) : a.kind === "pasted" ? a.text : undefined;
    const blocks: PromptBlock[] = text ? [{ type: "text", text }] : attachmentBlocks(a);
    if (!blocks.length) continue;
    display.push({
      kind,
      blockIndex,
      name: a.name,
      ...(a.mimeType ? { mimeType: a.mimeType } : {}),
      size: a.size,
      ...(a.pageCount ? { pageCount: a.pageCount } : {}),
    });
    if (a.kind === "image")
      parts.push({
        kind: "image",
        id: a.id,
        attachmentId: a.id,
        blockIndex,
        mimeType: a.mimeType,
        name: a.name,
        ...(a.data ? { src: `data:${a.mimeType};base64,${a.data}` } : {}),
      });
    else {
      const first = blocks[0];
      parts.push({
        kind,
        attachmentId: a.id,
        name: a.name,
        mimeType: a.mimeType,
        size: a.size,
        ...(text ? { text } : {}),
        ...(a.pageCount ? { pageCount: a.pageCount } : {}),
        ...("uri" in first ? { uri: first.uri } : {}),
        ...(a.video ? { video: a.video } : {}),
      } as PromptContentPart);
    }
    if (a.kind === "image" && blocks[1]?.type === "resource_link") {
      const original = blocks[1];
      parts.push({ kind: "file", name: original.name, uri: original.uri, companionOf: blockIndex });
      display.push({ kind: "file", blockIndex: blockIndex + 1, name: original.name, companionOf: blockIndex });
    }
    blockIndex += blocks.length;
  }
  return { parts, display };
}
export function normalizePromptContentPart(value: unknown): PromptContentPart | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const kind = raw.kind ?? raw.type;
  if (kind === "text" && typeof raw.text === "string")
    return raw.pasted === true
      ? { kind: "pasted", name: "Pasted text", text: raw.text }
      : { kind: "text", text: raw.text };
  if (kind === "image" && typeof raw.mimeType === "string" && typeof raw.id === "string")
    return {
      kind,
      id: raw.id,
      mimeType: raw.mimeType,
      ...(typeof raw.name === "string" ? { name: raw.name } : {}),
      ...(raw.persisted === false ? { persisted: false } : {}),
      ...(Number.isSafeInteger(raw.blockIndex) && Number(raw.blockIndex) >= 0
        ? { blockIndex: Number(raw.blockIndex) }
        : {}),
      ...(typeof raw.width === "number" ? { width: raw.width } : {}),
      ...(typeof raw.height === "number" ? { height: raw.height } : {}),
    };
  if (!["file", "document", "audio", "pasted", "resource_link"].includes(String(kind))) return undefined;
  return {
    kind: kind === "resource_link" ? "file" : kind,
    name: typeof raw.name === "string" ? raw.name : String(kind),
    ...(typeof raw.uri === "string" ? { uri: raw.uri } : {}),
    ...(typeof raw.text === "string" ? { text: raw.text } : {}),
    ...(typeof raw.mimeType === "string" ? { mimeType: raw.mimeType } : {}),
    ...(typeof raw.size === "number" ? { size: raw.size } : {}),
    ...(typeof raw.pageCount === "number" ? { pageCount: raw.pageCount } : {}),
    ...(Number.isSafeInteger(raw.companionOf) && Number(raw.companionOf) >= 0
      ? { companionOf: Number(raw.companionOf) }
      : {}),
  } as PromptContentPart;
}
export function recordedPromptParts(msg: any, known?: readonly PromptContentPart[]): PromptContentPart[] | undefined {
  if (!Array.isArray(msg?.inlineParts)) return undefined;
  const parts: PromptContentPart[] = msg.inlineParts.flatMap((part: unknown) => {
    const normalized = normalizePromptContentPart(part);
    return normalized ? [normalized] : [];
  });
  return parts.map((part, index) => {
    const old = known?.[index];
    if (part.kind === "file") {
      const file = known?.find((candidate) => candidate.kind === "file" && candidate.uri === part.uri);
      const video = file?.kind === "file" ? parseVideoInfo(file.video) : undefined;
      return {
        ...part,
        ...(video ? { video } : {}),
        ...(old?.kind === "file" &&
        old.uri === part.uri &&
        old.companionOf !== undefined &&
        part.companionOf === undefined
          ? { companionOf: old.companionOf }
          : {}),
      };
    }
    return part.kind === "image" && old?.kind === "image"
      ? {
          ...part,
          attachmentId: old.attachmentId,
          ...(part.blockIndex === undefined && old.blockIndex !== undefined ? { blockIndex: old.blockIndex } : {}),
        }
      : part;
  });
}
/// Move complete attachment tokens across a plain-text edit. Literal U+FFFC stays ordinary text.
export function carryInline(input: string, text: string, attachments: ComposerAttachment[]): string {
  let plain = "";
  const marks: { at: number; token: string }[] = [];
  for (const run of orderedDraftParts(input, attachments)) {
    if (run.type === "text") plain += run.text;
    else if (run.attachment.kind === "pasted") plain += run.attachment.text ?? "";
    else if (run.attachment.kind === "text") plain += promptText("", [run.attachment]);
    else marks.push({ at: plain.length, token: inlineToken(run.attachment.id) });
  }
  let head = 0,
    tail = 0;
  while (head < plain.length && head < text.length && plain[head] === text[head]) head += 1;
  while (
    tail < plain.length - head &&
    tail < text.length - head &&
    plain[plain.length - 1 - tail] === text[text.length - 1 - tail]
  )
    tail += 1;
  let out = "",
    from = 0;
  for (const mark of marks) {
    const at = Math.max(
      from,
      mark.at <= head
        ? mark.at
        : mark.at >= plain.length - tail
          ? mark.at + text.length - plain.length
          : text.length - tail,
    );
    out += text.slice(from, at) + mark.token;
    from = at;
  }
  return out + text.slice(from);
}
export async function restoreInline(
  row: AcpmuxRow,
  text: string,
  read: (id: string) => Promise<{ mimeType: string; data: string } | undefined>,
) {
  const attachments: ComposerAttachment[] = [];
  let input = "";
  for (const [index, part] of (row.inlineParts ?? []).entries()) {
    if (part.kind === "text") {
      input += part.text;
      continue;
    }
    if (part.kind === "file" && part.text && !part.uri) {
      input += part.text;
      continue;
    }
    if (
      part.kind === "file" &&
      part.companionOf !== undefined &&
      row.inlineParts?.some((image) => image.kind === "image" && image.blockIndex === part.companionOf)
    )
      continue;
    const id = `sent-${row.id}-${index}`;
    let attachment: ComposerAttachment;
    if (part.kind === "image") {
      const data = await read(part.id);
      if (!data) throw new Error(`Attachment unavailable: ${part.name ?? part.id}`);
      const companion =
        part.blockIndex === undefined
          ? undefined
          : row.inlineParts?.find((file) => file.kind === "file" && file.companionOf === part.blockIndex);
      attachment = {
        id,
        kind: "image",
        name: part.name ?? "image",
        ...data,
        size: Math.floor((data.data.length * 3) / 4),
        ...(companion?.kind === "file" && companion.uri
          ? { originalPath: localPath(companion.uri), originalName: companion.name }
          : {}),
      };
    } else if (part.kind === "file" && part.uri) {
      attachment = {
        id,
        kind: "link",
        name: part.name,
        mimeType: part.mimeType ?? "",
        size: part.size ?? 0,
        path: localPath(part.uri),
        ...(part.video ? { video: part.video } : {}),
      };
    } else if (part.kind === "pasted" && part.text)
      attachment = {
        id,
        kind: "pasted",
        name: part.name,
        mimeType: "text/plain",
        size: part.text.length,
        text: part.text,
      };
    else throw new Error(`Attachment unavailable: ${part.name}`);
    attachments.push(attachment);
    input += inlineToken(id);
  }
  if (text === (row.resend ?? row.text)) return { input, attachments };
  return { input: carryInline(input, text, attachments), attachments: attachments.filter((a) => a.kind !== "pasted") };
}
function localPath(value: string): string {
  const uri = new URL(value);
  if (uri.protocol !== "file:" || (uri.hostname && uri.hostname !== "localhost"))
    throw new Error("Attachment is not a local file");
  return decodeURIComponent(uri.pathname);
}

/** Display metadata for strip-mode file links. It follows the actual ACP block indexes, so
 * acpmux persists the same filename and byte count without changing the prompt or its order. */
export function stripFileDisplay(
  blocks: readonly PromptBlock[],
  attachments: readonly ComposerAttachment[],
): DisplayPart[] {
  const originals = new Map<string, ComposerAttachment[]>();
  for (const image of attachments) {
    if (image.kind !== "image") continue;
    for (const block of attachmentBlocks(image)) {
      if (block.type !== "resource_link") continue;
      originals.set(block.uri, [...(originals.get(block.uri) ?? []), image]);
    }
  }
  const files = new Map(
    attachments.flatMap((file) =>
      file.kind === "link" && !file.mimeType.startsWith("video/")
        ? attachmentBlocks(file).flatMap((block) =>
            block.type === "resource_link" ? [[block.uri, file] as const] : [],
          )
        : [],
    ),
  );
  return blocks.flatMap((block, blockIndex): DisplayPart[] => {
    const previous = blocks[blockIndex - 1];
    if (
      block.type === "resource_link" &&
      previous?.type === "image" &&
      originals
        .get(block.uri)
        ?.some(
          (image) =>
            image.data === previous.data && image.name === previous.name && image.mimeType === previous.mimeType,
        )
    )
      return [{ kind: "file", blockIndex, name: block.name, companionOf: blockIndex - 1 }];
    const file = block.type === "resource_link" ? files.get(block.uri) : undefined;
    return file
      ? [
          {
            kind: "file",
            blockIndex,
            name: file.name,
            ...(file.mimeType ? { mimeType: file.mimeType } : {}),
            ...(file.mimeType || file.size > 0 ? { size: file.size } : {}),
          },
        ]
      : [];
  });
}
