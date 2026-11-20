// Which reply text shows images as thumbnails (Leo 2026-10-21: "you should've just added images or
// some kind of link inline"). Agents show UI with screenshots instead of describing it:
// - a paragraph of only images (`![before](/tmp/a.png) ![after](/tmp/b.png)`, bare image paths or
//   https image addresses, one per line or side by side, each optionally labelled `Before:`) draws
//   as a row of thumbnails, so a before/after pair sits side by side;
// - an image path or https image address inside a sentence stays a chip there, and its thumbnail
//   draws under the paragraph.
// The page only decides what is an image; the host loads each one under its usual rules
// (chips/ReplyImage.tsx).
import { isDeniedPath, isImagePath, isImageUrl, linkPath, textLinks } from "../chips/paths";

/** One thumbnail: its source as written, its alt text, and the label written before it. */
export type ThumbItem = { src: string; alt: string; label?: string };

// One image of an image-only paragraph: an optional label of one to three words ending in `:`
// (`Before:`, `**After:**`, `__After__:`, `Dark mode:`), then a Markdown image or a bare token
// that must itself be an image. A label is words only, so a sentence ending in `:` ("I saved it here: /tmp/a.png") is
// prose and keeps its text.
const IMAGE_TOKEN =
  /\s*(?:((?:\*\*|__)?[A-Za-z0-9][A-Za-z0-9'’-]*(?: [A-Za-z0-9'’-]+){0,2}(?:\*\*|__)?:(?:\*\*|__)?)\s+)?(?:!\[([^\]]*)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|(\S+))\s*/y;

/// The source a bare token draws as an image: an absolute, home or `./` path or `file://` URL of a
/// raster image, or an https image address. Anything else (a word, a deny-listed path) is undefined.
export function bareImageSource(token: string): string | undefined {
  if (/^https:\/\//i.test(token)) return isImageUrl(token) ? token : undefined;
  if (!/^(?:file:\/\/|~\/|\.{0,2}\/)/i.test(token) || !isImagePath(token)) return undefined;
  const path = linkPath(token);
  return path && isImagePath(path) && !isDeniedPath(path) ? token : undefined;
}

/// The images of a paragraph made only of images (and their labels), in reading order; undefined
/// when any other text is there.
export function imageOnlyItems(text: string): ThumbItem[] | undefined {
  if (!text.includes("/") && !text.includes("](")) return undefined;
  const items: ThumbItem[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    IMAGE_TOKEN.lastIndex = 0;
    let at = 0;
    while (at < line.length) {
      IMAGE_TOKEN.lastIndex = at;
      const match = IMAGE_TOKEN.exec(line);
      if (!match || match[0].length === 0) return undefined;
      const label = match[1]?.replace(/\*\*|__|:/g, "").trim() || undefined;
      const src = match[3] ?? bareImageSource(match[4]!);
      if (!src) return undefined;
      items.push({ src, alt: match[2] || label || "", ...(label ? { label } : {}) });
      at = IMAGE_TOKEN.lastIndex;
    }
  }
  return items.length ? items : undefined;
}

/// Image paths and https image addresses written in a sentence (not in code, and not the target of
/// a Markdown link or image, which draw on their own), each once, in reading order.
export function proseImages(text: string): ThumbItem[] {
  if (!text.includes("/")) return [];
  // Blank out code spans and link and image targets so their text is never read as prose.
  const prose = text
    .replace(/(`+)[^`]*?\1/g, (span) => " ".repeat(span.length))
    .replace(/!?\[[^\]]*\]\((?:[^()\s]|\([^()\s]*\))+\)/g, (link) => " ".repeat(link.length));
  const out: ThumbItem[] = [];
  const seen = new Set<string>();
  for (const link of textLinks(prose)) {
    if (link.location !== undefined) continue;
    const src = link.kind === "url" ? (isImageUrl(link.value) ? link.value : undefined) : imagePathOf(link.path);
    if (!src || seen.has(src)) continue;
    seen.add(src);
    out.push({ src, alt: "" });
  }
  return out;
}

function imagePathOf(path: string | undefined): string | undefined {
  return path && isImagePath(path) && !isDeniedPath(path) ? path : undefined;
}
