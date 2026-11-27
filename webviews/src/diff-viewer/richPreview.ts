// Inline previews (InlinePreview.tsx): an image file shows its two sides in place of its diff, and
// with Rich preview on a Markdown file shows its new version rendered. Both sides come from the
// host's `fileContents` (session.ts), the read Load full files uses. This file is the pure part:
// which files preview, and how a side's bytes become what the preview shows.
import type { FileContents, FileSide } from "./session";

export type { FileContents, FileSide };

export type PreviewKind = "markdown" | "image";

/** Reads both sides of one file of the shown diff. */
export type FileContentsLoader = (file: {
  path: string;
  previousPath?: string;
  encoding: "text" | "base64";
}) => Promise<FileContents>;

const MARKDOWN_EXTENSIONS = new Set(["md", "markdown", "mdown", "mkd", "mkdn"]);

/** The images a page can show from a `data:` URL (the page's `img-src` allows `data:`). */
const IMAGE_TYPES: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  bmp: "image/bmp",
  ico: "image/x-icon",
  avif: "image/avif",
  // An SVG in an <img> runs no script and loads nothing.
  svg: "image/svg+xml",
};

function extensionOf(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/** What a file previews as, by its extension; undefined for a file with no preview. */
export function previewKindOf(path: string): PreviewKind | undefined {
  const extension = extensionOf(path);
  if (MARKDOWN_EXTENSIONS.has(extension)) return "markdown";
  return IMAGE_TYPES[extension] ? "image" : undefined;
}

/** The encoding the sheet asks the host for: bytes for an image, text for Markdown. */
export function previewEncodingOf(kind: PreviewKind): "text" | "base64" {
  return kind === "image" ? "base64" : "text";
}

function base64OfText(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function textOfBase64(base64: string): string {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return new TextDecoder().decode(bytes);
}

/** An image side as a `data:` URL; undefined when the side is missing or the type unknown. */
export function imageDataURL(path: string, side: FileSide | undefined): string | undefined {
  const type = IMAGE_TYPES[extensionOf(path)];
  if (!side || !type) return undefined;
  const base64 = side.encoding === "base64" ? side.contents : base64OfText(side.contents);
  return `data:${type};base64,${base64}`;
}

/** A Markdown side as text; undefined when the side is missing. */
export function markdownText(side: FileSide | undefined): string | undefined {
  if (!side) return undefined;
  return side.encoding === "text" ? side.contents : textOfBase64(side.contents);
}
