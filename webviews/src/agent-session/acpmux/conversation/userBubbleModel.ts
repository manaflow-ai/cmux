import type { AcpmuxRow, PromptContentPart } from "../model";
import { type FileAttachmentInfo } from "../FileAttachment";
import { attachmentPath } from "../fileAttachmentModel";
import { videoRatio } from "../composer/videoShape";

/// The files a recorded prompt sent (its `inlineParts`: documents, audio, resource links), drawn
/// as a sent prompt draws them; a file that is an image's companion, a video, or an image's
/// original path is drawn by that image instead.
export function recordedFiles(
  parts: AcpmuxRow["inlineParts"],
  originals: ReadonlySet<string> = new Set(),
): FileAttachmentInfo[] | undefined {
  return parts?.flatMap((part): FileAttachmentInfo[] =>
    part.kind === "file" && !isImageOriginal(part, originals) && !part.mimeType?.startsWith("video/")
      ? [{ ...part, path: attachmentPath(part.uri) }]
      : [],
  );
}

/// A file part that is an image's retained original: drawn as the image, never again as a file.
export function isImageOriginal(part: PromptContentPart, originals: ReadonlySet<string>): boolean {
  return part.kind === "file" && (part.companionOf !== undefined || originals.has(attachmentPath(part.uri) ?? ""));
}

/// The sent thumbnail's height (conversation.css).
export const SENT_IMAGE_HEIGHT = 120;
/// The widest a sent image draws: a wider one shrinks to it, whole.
const SENT_IMAGE_MAX_WIDTH = 320;

/// A video tile's width at SENT_IMAGE_HEIGHT: the shape its composer chip had (`shape`,
/// composer/videoShape.ts), else its size's within the same bounds; square only while neither is known.
/// The composer's tile and the sent one are one box at two heights (Leo, 2026-11-10: "the preview
/// placeholder boxes are incongruent between the initial load, then the second load, and the chat
/// attachment itself").
export function sentImageWidth(size: { width?: number; height?: number; shape?: number }): number {
  return Math.round(SENT_IMAGE_HEIGHT * (size.shape ?? videoRatio(size)));
}

/// A sent image's thumbnail box for an image of `size`: the whole image in its own shape, at most
/// SENT_IMAGE_HEIGHT tall and SENT_IMAGE_MAX_WIDTH wide and never larger than the image, so a wide
/// screenshot is a whole strip, never a magnified crop of its middle (Leo, 2026-11-05: "I don't
/// think we have good enough looking previews for these"). Square while no size is known.
export function sentImageSize(size: { width?: number; height?: number }): { width: number; height: number } {
  if (!size.width || !size.height) return { width: SENT_IMAGE_HEIGHT, height: SENT_IMAGE_HEIGHT };
  const scale = Math.min(1, SENT_IMAGE_HEIGHT / size.height, SENT_IMAGE_MAX_WIDTH / size.width);
  return {
    width: Math.max(1, Math.round(size.width * scale)),
    height: Math.max(1, Math.round(size.height * scale)),
  };
}
