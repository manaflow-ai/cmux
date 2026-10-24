import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { pasteName, type PasteRange } from "./promptCollapse";

type RawPart = Record<string, unknown>;

const isRecord = (value: unknown): value is RawPart =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const positiveInteger = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value) && value > 0;

/**
 * Normalizes the provisional `inlineParts` row field. ACP calls the discriminator `type` in
 * several places, while the transcript model uses `kind`; accepting both keeps this adapter at
 * the boundary and leaves the composer and daemon serializers free to settle on one spelling.
 */
export function normalizePromptContentPart(value: unknown): PromptContentPart | undefined {
  if (!isRecord(value)) return undefined;
  const kind = typeof value.kind === "string" ? value.kind : value.type;
  if (kind === "text" && typeof value.text === "string") {
    if (value.pasted === true)
      return { kind: "pasted", name: pasteName(value.text), text: value.text };
    return {
      kind: "text",
      text: value.text,
      ...(Array.isArray(value.pasted) && { pasted: value.pasted as PasteRange[] }),
    };
  }
  if (kind === "image" && typeof value.mimeType === "string") {
    const image: PromptImage & { kind: "image" } = {
      kind: "image",
      id: typeof value.id === "string" ? value.id : `inline-image-${String(value.name ?? "attachment")}`,
      mimeType: value.mimeType,
      ...(typeof value.name === "string" && { name: value.name }),
      ...(positiveInteger(value.width) && { width: value.width }),
      ...(positiveInteger(value.height) && { height: value.height }),
      ...(typeof value.src === "string" && { src: value.src }),
      ...(typeof value.data === "string" && { src: `data:${value.mimeType};base64,${value.data}` }),
    };
    return image;
  }
  if (
    (kind === "file" || kind === "document" || kind === "audio" || kind === "recording" || kind === "pasted" || kind === "resource_link") &&
    (typeof value.name === "string" || typeof value.uri === "string" || kind === "audio" || kind === "recording")
  ) {
    return {
      kind: kind === "resource_link" ? "file" : kind,
      name: typeof value.name === "string" && value.name.length > 0 ? value.name : typeof value.uri === "string" ? value.uri : kind,
      ...(typeof value.id === "string" && { id: value.id }),
      ...(typeof value.mimeType === "string" && { mimeType: value.mimeType }),
      ...(positiveInteger(value.size) && { size: value.size }),
      ...(typeof value.text === "string" && { text: value.text }),
      ...(positiveInteger(value.pageCount) && { pageCount: value.pageCount }),
      ...(typeof value.uri === "string" && { uri: value.uri }),
    };
  }
  return undefined;
}

/**
 * Returns a prompt's ordered parts when the row carries them. An absent or empty field deliberately
 * returns an empty array: UserBubble then uses its established `images`-above-text fallback for
 * persisted rows written before inline content was recorded.
 */
export function promptContentParts(row: Pick<AcpmuxRow, "inlineParts">): PromptContentPart[] {
  if (!row.inlineParts?.length) return [];
  return row.inlineParts.flatMap((part) => {
    const normalized = normalizePromptContentPart(part);
    return normalized ? [normalized] : [];
  });
}
