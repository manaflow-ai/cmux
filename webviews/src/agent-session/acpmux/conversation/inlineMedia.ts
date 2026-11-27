// Which reply text shows images and videos inline (Leo 2026-10-21: "you should've just added images or
// some kind of link inline"; 2026-11-22: "is there a way we can just watch the .mp4s in the app? i want
// that. in-app video player." and "shouldn't these, like the in-app videos, and probably gifs, be
// rendered in the app?"). Agents show UI with screenshots and clips instead of describing it:
// - a paragraph of only images or videos (`![before](/tmp/a.png) ![after](/tmp/b.png)`, bare paths or
//   https addresses, `[clip](https://…/a.mp4)` links, one per line or side by side, each optionally
//   labelled `Before:`) draws as a row of thumbnails, so a before/after pair sits side by side;
// - an image or video named inside a sentence (a bare path or address, a `code span` that is only
//   that path, or the target of a Markdown link) stays a chip there, and its thumbnail or player
//   draws under the paragraph.
// The page only decides what is an image or a video; the host loads each one under its usual rules
// (chips/ReplyImage.tsx, chips/ReplyMedia.tsx): a local file inside the chat's roots, a web file
// under `agentPane.images.remote`.
import { codePath, isDeniedPath, isImagePath, isImageUrl, isTemplatePath, linkPath, textLinks } from "../chips/paths";
import { mediaKind } from "../chips/mediaKind";

/** One thumbnail: its source as written, its alt text, and the label written before it. */
export type ThumbItem = { src: string; alt: string; label?: string };

// One item of an image-only paragraph: an optional label of one to three words ending in `:`
// (`Before:`, `**After:**`, `__After__:`, `Dark mode:`), then a Markdown image, a Markdown link to an
// image or video, or a bare token that must itself be one. A label is words only, so a sentence ending
// in `:` ("I saved it here: /tmp/a.png") is prose and keeps its text.
// Groups: 1 label, 2 `!` of an image, 3 its alt or link text, 4 its target, 5 a bare token.
const IMAGE_TOKEN =
  /\s*(?:((?:\*\*|__)?[A-Za-z0-9][A-Za-z0-9'’-]*(?: [A-Za-z0-9'’-]+){0,2}(?:\*\*|__)?:(?:\*\*|__)?)\s+)?(?:(!?)\[([^\]]*)\]\(((?:[^()\s]|\([^()\s]*\))+)\)|(\S+))\s*/y;

/// Whether `path` (no line suffix) is a local file the reply draws inline: a raster image or an SVG
/// (the host rebuilds an SVG without script before the page sees it), or a video.
function isInlinePath(path: string): boolean {
  if (isTemplatePath(path) || isDeniedPath(path)) return false;
  return isImagePath(path) || /\.svg$/i.test(path) || mediaKind(path) === "video";
}

/// Whether `url` is an https image or video address drawn inline (by its path's extension).
export function isInlineUrl(url: string): boolean {
  if (isImageUrl(url)) return true;
  try {
    const parsed = new URL(url);
    return (
      parsed.protocol === "https:" && !parsed.username && !parsed.password && mediaKind(parsed.pathname) === "video"
    );
  } catch {
    return false;
  }
}

/// The source a bare token draws as: an absolute, home or `./` path or `file://` URL of an image or
/// video, or an https image or video address. Anything else (a word, a deny-listed path) is undefined.
export function bareImageSource(token: string): string | undefined {
  if (/^https:\/\//i.test(token)) return isInlineUrl(token) ? token : undefined;
  // A `:12` line suffix names a line of a file to read, not a picture to look at.
  if (!/^(?:file:\/\/|~\/|\.{0,2}\/)/i.test(token) || /:\d+(?::\d+)?$/.test(token)) return undefined;
  const path = linkPath(token);
  return path && isInlinePath(path) ? token : undefined;
}

/// The images and videos of a paragraph made only of them (and their labels), in reading order;
/// undefined when any other text is there.
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
      // A Markdown image draws whatever it names (ReplyImage decides); a plain link only when its
      // target is an image or a video, else the paragraph is prose.
      const target = match[4];
      const src = target !== undefined ? (match[2] ? target : bareImageSource(target)) : bareImageSource(match[5]!);
      if (!src) return undefined;
      items.push({ src, alt: match[3] || label || "", ...(label ? { label } : {}) });
      at = IMAGE_TOKEN.lastIndex;
    }
  }
  return items.length ? items : undefined;
}

const CODE_SPAN = /(`+)([^`]*?)\1/g;
const MARKDOWN_LINK = /(!?)\[([^\]]*)\]\(((?:[^()\s]|\([^()\s]*\))+)\)/g;

/// Images and videos named in a sentence, each once, in reading order: bare paths and https
/// addresses, a code span that is only such a path, and the target of a Markdown link. A Markdown
/// image is not one (it draws on its own), nor a path with a line suffix or a code span holding a
/// command.
export function proseImages(text: string): ThumbItem[] {
  if (!text.includes("/")) return [];
  const found: Array<{ at: number; item: ThumbItem }> = [];
  // Code spans and link targets are read on their own, then blanked so the prose scan skips them.
  let prose = text.replace(CODE_SPAN, (span, _ticks: string, inner: string, at: number) => {
    const path = codePath(inner);
    // `src/app.ts:12` names a line of a file: a reference, not something to look at.
    if (path && !/:\d+(?::\d+)?$/.test(inner.trim()) && isInlinePath(path))
      found.push({ at, item: { src: path, alt: "" } });
    return " ".repeat(span.length);
  });
  prose = prose.replace(MARKDOWN_LINK, (link, bang: string, label: string, target: string, at: number) => {
    if (!bang) {
      const src = bareImageSource(target);
      if (src) found.push({ at, item: { src, alt: label } });
    }
    return " ".repeat(link.length);
  });
  for (const link of textLinks(prose)) {
    if (link.line !== undefined) continue;
    const src = link.kind === "url" ? (isInlineUrl(link.value) ? link.value : undefined) : inlinePathOf(link.path);
    if (src) found.push({ at: link.start, item: { src, alt: "" } });
  }
  found.sort((a, b) => a.at - b.at);
  const out: ThumbItem[] = [];
  const seen = new Set<string>();
  for (const { item } of found) {
    if (seen.has(item.src)) continue;
    seen.add(item.src);
    out.push(item);
  }
  return out;
}

function inlinePathOf(path: string | undefined): string | undefined {
  return path && isInlinePath(path) ? path : undefined;
}

/// Whether `items` are a before/after pair of videos the compare viewer plays side by side: exactly
/// two, both videos.
export function videoPair(items: ThumbItem[]): [ThumbItem, ThumbItem] | undefined {
  if (items.length !== 2) return undefined;
  const isVideo = (item: ThumbItem) => mediaKind(webPath(item.src)) === "video";
  return items.every(isVideo) ? [items[0]!, items[1]!] : undefined;
}

function webPath(src: string): string {
  try {
    return /^https:\/\//i.test(src) ? new URL(src).pathname : src;
  } catch {
    return src;
  }
}
