import type { AcpmuxRow, PromptContentPart } from "../model";
import { type FileAttachmentInfo } from "../FileAttachment";
import { attachmentPath } from "../fileAttachmentModel";

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

/// The sent thumbnail's height (conversation.css), and the narrowest and
/// widest a video's tile draws as a share of that: a tall phone recording or a wide screen
/// recording is cropped to fill past those bounds rather than drawn as a sliver.
export const SENT_IMAGE_HEIGHT = 120;
const SENT_IMAGE_RATIO = { min: 0.75, max: 1.6 };
/// The widest a sent image draws: a wider one shrinks to it, whole.
const SENT_IMAGE_MAX_WIDTH = 320;

/// A video tile's width at SENT_IMAGE_HEIGHT for a video of `size`: square only while no size is known.
export function sentImageWidth(size: { width?: number; height?: number }): number {
  const ratio =
    size.width && size.height
      ? Math.min(SENT_IMAGE_RATIO.max, Math.max(SENT_IMAGE_RATIO.min, size.width / size.height))
      : 1;
  return Math.round(SENT_IMAGE_HEIGHT * ratio);
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
