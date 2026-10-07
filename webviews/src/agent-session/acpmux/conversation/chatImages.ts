import type { AcpmuxRow } from "../model";
import { MAX_DATA_URL_LENGTH } from "./Markdown";

/// An image a reply drew inline (a data URL, as Markdown.tsx draws one), for the image viewer.
export type ChatImage = { src: string; alt: string };

const FENCE = /^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:\n {0,3}\1[`~]*[ \t]*(?=\n|$)|$)/gm;
const CODE_SPAN = /(`+)[^`][\s\S]*?\1/g;
const IMAGE = /!\[([^\]]*)\]\((data:image\/(?:png|jpe?g|gif|webp|svg\+xml);[^()\s]+)\)/gi;

/// Every inline image of the chat's replies, oldest first, each source once. Code (fenced or
/// inline) is not an image, and a data URL over MAX_DATA_URL_LENGTH never draws, so neither is listed.
export function chatImages(rows: readonly AcpmuxRow[]): ChatImage[] {
  const images: ChatImage[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (row.kind !== "assistant" || !row.text?.includes("](data:image/")) continue;
    const prose = row.text.replace(FENCE, "").replace(CODE_SPAN, "");
    for (const match of prose.matchAll(IMAGE)) {
      const src = match[2]!;
      if (src.length > MAX_DATA_URL_LENGTH || seen.has(src)) continue;
      seen.add(src);
      images.push({ src, alt: match[1]! });
    }
  }
  return images;
}
