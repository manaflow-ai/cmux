import type { AcpmuxRow, PromptContentPart } from "../model";
import { type FileAttachmentInfo } from "../FileAttachment";
import { attachmentPath } from "../fileAttachmentModel";
import { withoutAttachedFileNotes } from "../attachments";

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

/// An image file a prompt sent as its link, not its bytes: an image past the prompt's budget goes
/// as the link to its saved original (promptBudget.ts `originalLink`, no type or size), as does a
/// dropped image file's link chip. The bubble draws it as the image it is, read from its file
/// (UserBubble.tsx `SentLinkedImage`), never as a nameless "0 byte" file chip (Leo, 2026-11-22:
/// "WHAT THE FUCK IS THIS SITUATION MAN WITH THESE ATTACHMENTS!?"). Its path, or undefined.
export function linkedImagePath(file: {
  kind?: string;
  name?: string;
  mimeType?: string;
  companionOf?: number;
  text?: string;
  uri?: string;
  path?: string;
}): string | undefined {
  // `link`: the pane's own row before acpmux's echo keeps the composer's link chip as it was sent.
  if (file.kind !== undefined && file.kind !== "file" && file.kind !== "link") return undefined;
  // A folder's link chip names it with a trailing `/` (attachments.ts `linkAttachment`): `cache.png/`.
  if (file.companionOf !== undefined || file.text || file.name?.endsWith("/")) return undefined;
  if (file.mimeType && file.mimeType !== "application/octet-stream" && !file.mimeType.startsWith("image/"))
    return undefined;
  const path = file.path ?? attachmentPath(file.uri);
  return path && LINKED_IMAGE.test(path) ? path : undefined;
}
const LINKED_IMAGE = /\.(png|jpe?g|gif|webp|heic|heif|tiff?|bmp)$/i;

/// A file part that is an image's retained original: drawn as the image, never again as a file.
export function isImageOriginal(part: PromptContentPart, originals: ReadonlySet<string>): boolean {
  return part.kind === "file" && (part.companionOf !== undefined || originals.has(attachmentPath(part.uri) ?? ""));
}

/// The sent thumbnail's height (conversation.css): the tallest a sent image draws, and a sent video's
/// tile. Was 120 with a 320 cap on width, which drew a wide screenshot as a strip of unreadable text
/// above its bubble (Leo, 2026-11-21: "you guys or we kinda messed up the rendering ... if you sent it
/// iinline you prob shouldn't have such odd stuff").
export const SENT_IMAGE_HEIGHT = 160;
/// The widest a sent image draws: a wider one shrinks to it, whole. The bubble's column (70% of the
/// chat, conversation.css) scales it down further in a narrow chat.
export const SENT_IMAGE_MAX_WIDTH = 480;

/// A sent video's tile box: its whole picture in its own shape under a sent image's rule
/// (`sentImageSize`: contain, at most SENT_IMAGE_HEIGHT tall and SENT_IMAGE_MAX_WIDTH wide), so a
/// wide screen recording is a short wide tile, never a square with bands above and below its poster
/// (Leo, 2026-11-22: "having this square is kinda strange"). Its size, from its frames note, its chip's
/// host read or the size acpmux kept with it (sentVideos.ts), is known before the tile draws; one with
/// only its chip's header shape (composer/videoShape.ts) takes that shape; square while neither is known.
export function sentVideoSize(video: { width?: number; height?: number; shape?: number }): {
  width: number;
  height: number;
} {
  if (video.width && video.height) return sentImageSize(video);
  if (video.shape) return sentImageSize({ width: 1000 * video.shape, height: 1000 });
  return { width: SENT_IMAGE_HEIGHT, height: SENT_IMAGE_HEIGHT };
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

/// A sent prompt's row without the notes the composer added for its linked files (attachments.ts
/// `promptText`: "Attached file: … Read the linked file with your tools."). They went to the agent
/// only; the bubble draws the file as its chip or thumbnail, and the person never typed them.
export function withoutFileNotes<Row extends { text?: string; inlineParts?: PromptContentPart[] }>(row: Row): Row {
  const text = row.text === undefined ? undefined : withoutAttachedFileNotes(row.text);
  let changed = text !== row.text;
  const parts = row.inlineParts?.flatMap((part): PromptContentPart[] => {
    if (part.kind !== "text") return [part];
    const kept = withoutAttachedFileNotes(part.text);
    if (kept === part.text) return [part];
    changed = true;
    return kept ? [{ ...part, text: kept }] : [];
  });
  if (!changed) return row;
  return { ...row, ...(text !== undefined ? { text } : {}), ...(parts ? { inlineParts: parts } : {}) };
}
