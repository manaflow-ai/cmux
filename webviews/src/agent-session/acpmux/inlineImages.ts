// A pasted image is an attachment chip, never prompt text (Leo 2026-10-20: two images copied in
// Chrome and pasted showed full size in the composer and went out as
// `![Screenshot · 778×696](data:image/png;base64,…)`; the bubble showed pages of base64, the agent
// read it as text and the chat's compaction failed). The field no longer makes image nodes from a
// paste (MarkdownField.tsx); these are the checks behind it: a markdown image of base64 data in a
// prompt goes to the agent as an image, and a bubble never draws a `data:` URI. A `data:` URI the
// person wrote as text (in code, a source map, a CSS `url()`) stays as written.
import type { ComposerAttachment } from "./attachments";

/// The image types an agent takes as an image block (`attachments.ts` IMAGE_TYPES).
const LIFTED_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
/// A markdown image whose source is a base64 `data:` URI, with its optional title.
const MARKDOWN_DATA_IMAGE =
  /!\[([^\]\n]*)\]\(\s*<?data:([a-z]+\/[a-z0-9.+-]+)((?:;[a-z0-9-]+=[^;,\s)]+)*);base64,([a-z0-9+/=]+(?:\s+[a-z0-9+/=]+)*)>?(?:\s*(?:"[^"\n]*"|'[^'\n]*'))?\s*\)/gi;
/// A bare base64 `data:` URI anywhere in text.
const BARE_DATA_URI = /data:([a-z]+\/[a-z0-9.+-]+)(?:;[a-z0-9-]+=[^;,\s)"'>]+)*;base64,[a-z0-9+/=]+/gi;
/// Code in markdown: a fenced block (to its closing fence or the end) or an inline span.
const CODE = /(^|\n)(`{3,}(?!`)|~{3,}(?!~))[^\n]*\n[\s\S]*?(?:\n\2[^\n]*(?=\n|$)|$)|`[^`\n]+`/g;

/// Whether `text` holds a base64 `data:` URI.
export function hasDataUri(text: string): boolean {
  BARE_DATA_URI.lastIndex = 0;
  return BARE_DATA_URI.test(text);
}

/// Applies `edit` to the parts of `text` outside code.
function outsideCode(text: string, edit: (prose: string) => string): string {
  let out = "";
  let at = 0;
  for (const code of text.matchAll(CODE)) {
    out += edit(text.slice(at, code.index)) + code[0];
    at = code.index + code[0].length;
  }
  return out + edit(text.slice(at));
}

/// `text` without its markdown images of base64 data outside code, each one as an image chip after
/// `attachments` (in the order they were written). Only the types an agent takes are lifted; any
/// other is left as written.
export function liftInlineImages(
  text: string,
  attachments: ComposerAttachment[] = [],
): { text: string; attachments: ComposerAttachment[] } {
  if (!text.includes("data:")) return { text, attachments };
  const lifted: ComposerAttachment[] = [];
  const rest = outsideCode(text, (prose) =>
    prose.replace(MARKDOWN_DATA_IMAGE, (match, alt: string, type: string, _params: string, data: string) => {
      const mimeType = type.toLowerCase();
      const clean = data.replace(/\s+/g, "");
      if (!LIFTED_TYPES.has(mimeType) || !clean) return match;
      lifted.push({
        id: `inline-${attachments.length + lifted.length}-${clean.length}`,
        kind: "image",
        name: alt.trim() || "image",
        mimeType,
        size: Math.floor((clean.length * 3) / 4),
        data: clean,
      });
      return "";
    }),
  );
  if (!lifted.length) return { text, attachments };
  return { text: rest.trim() ? rest : "", attachments: [...attachments, ...lifted] };
}

/// What a bubble shows for text that holds `data:` URIs: a markdown image reads as its name in
/// brackets and any other URI as `[label]`, so the transcript never draws pages of base64.
export function withoutDataUris(text: string, label: string): string {
  if (!text.includes("data:")) return text;
  return text
    .replace(MARKDOWN_DATA_IMAGE, (_match, alt: string) => `[${alt.trim() || label}]`)
    .replace(BARE_DATA_URI, `[${label}]`);
}

/// Any markdown image (`![alt](src "title")`, whatever its source) outside code.
const MARKDOWN_IMAGE = /!\[[^\]\n]*\]\([^()\n]*(?:\([^()\n]*\)[^()\n]*)*\)/g;

/// `text` without its markdown images, for a paste that carries the image itself: a browser's or
/// the transcript's copy puts the picture on the clipboard with `![…](…)` text or an `<img>` for
/// it, and the composer takes the picture as a chip, so that text would only repeat it as markup
/// (Leo 2026-10-21: "copying and pasting images straight puts weird things in composer").
export function withoutMarkdownImages(text: string): string {
  if (!text.includes("![")) return text;
  const rest = outsideCode(text, (prose) => prose.replace(MARKDOWN_IMAGE, ""));
  return rest.trim() ? rest : "";
}
