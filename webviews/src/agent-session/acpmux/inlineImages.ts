// A pasted image is an attachment chip, never prompt text (Leo 2026-10-20: two images copied in
// Chrome and pasted showed full size in the composer and went out as
// `![Screenshot · 778×696](data:image/png;base64,…)`; the bubble showed pages of base64, the agent
// read it as text and the chat's compaction failed). The field no longer makes image nodes from a
// paste (MarkdownField.tsx); these are the checks behind it: a prompt's text never carries a `data:`
// URI to the agent, and a bubble never shows one.
import type { ComposerAttachment } from "./attachments";

/// A markdown image whose source is a base64 `data:` URI, with its optional title.
const MARKDOWN_DATA_IMAGE =
  /!\[([^\]\n]*)\]\(\s*<?data:([a-z]+\/[a-z0-9.+-]+)((?:;[a-z0-9-]+=[^;,\s)]+)*);base64,([a-z0-9+/=\s]+?)>?(?:\s*(?:"[^"\n]*"|'[^'\n]*'))?\s*\)/gi;
/// A bare base64 `data:` URI anywhere in text (an `<img>` or a link the field kept as text).
const BARE_DATA_URI = /data:([a-z]+\/[a-z0-9.+-]+)(?:;[a-z0-9-]+=[^;,\s)"'>]+)*;base64,[a-z0-9+/=]+/gi;

/// Whether `text` holds a base64 `data:` URI.
export function hasDataUri(text: string): boolean {
  BARE_DATA_URI.lastIndex = 0;
  return BARE_DATA_URI.test(text);
}

/// `text` without its `data:` images, and each one as an image chip after `attachments` (in the
/// order they were written). A `data:` URI that is not an image goes without a chip.
export function liftInlineImages(
  text: string,
  attachments: ComposerAttachment[] = [],
): { text: string; attachments: ComposerAttachment[] } {
  if (!text.includes("data:")) return { text, attachments };
  const lifted: ComposerAttachment[] = [];
  const keep = (mimeType: string, data: string, name: string) => {
    const clean = data.replace(/\s+/g, "");
    if (!mimeType.toLowerCase().startsWith("image/") || !clean) return;
    lifted.push({
      id: `inline-${attachments.length + lifted.length}-${clean.length}`,
      kind: "image",
      name: name.trim() || "image",
      mimeType: mimeType.toLowerCase(),
      size: Math.floor((clean.length * 3) / 4),
      data: clean,
    });
  };
  let rest = text.replace(
    MARKDOWN_DATA_IMAGE,
    (_match, alt: string, mimeType: string, _params: string, data: string) => {
      keep(mimeType, data, alt);
      return "";
    },
  );
  rest = rest.replace(BARE_DATA_URI, (match: string, mimeType: string) => {
    keep(mimeType, match.slice(match.indexOf(",") + 1), "");
    return "";
  });
  if (rest === text) return { text, attachments };
  return { text: tidy(rest), attachments: [...attachments, ...lifted] };
}

/// What a bubble shows for text that holds `data:` URIs: each image reads as its name in brackets
/// (`label` for one with none), so the transcript never draws pages of base64.
export function withoutDataUris(text: string, label: string): string {
  if (!text.includes("data:")) return text;
  const rest = text
    .replace(MARKDOWN_DATA_IMAGE, (_match, alt: string) => `[${alt.trim() || label}]`)
    .replace(BARE_DATA_URI, `[${label}]`);
  return rest === text ? text : tidy(rest);
}

/// Text an image was taken out of: no run of blank lines or trailing spaces left where it stood.
function tidy(text: string): string {
  return text
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
