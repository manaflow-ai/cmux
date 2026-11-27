// Copy and drag out a staged image attachment (Leo, 2026-11-27, on a pasted screenshot whose menu
// had only Open and Remove: "i need to be able to copy images that i pasted"). The chip's whole
// image, never its thumbnail, goes to the host as a `data:` URL with its name: `image.copy` puts
// its named copy on the pasteboard (its file URL, its bytes, PNG and TIFF; AgentPaneImageCopies+Menu
// .swift), and `image.drag` drags that file out while the press is held, as a picture in the
// transcript does (conversation/dragOut.ts). So it pastes into this composer, another chat, Slack
// and Finder alike.
import type { ComposerAttachment } from "../attachments";
import { readLinkedImage } from "../chips/host";
import { linkedImagePath } from "../conversation/userBubbleModel";
import { postNative } from "../native";

type Post = (method: string, params: Record<string, unknown>) => Promise<unknown>;
type Read = (path: string) => Promise<string | undefined>;

/// The disk image a link chip stands for (an image sent as its path), or undefined.
function linkedPath(attachment: ComposerAttachment): string | undefined {
  return attachment.kind === "link" && !attachment.saved && attachment.path?.startsWith("/")
    ? linkedImagePath({ path: attachment.path, mimeType: attachment.mimeType })
    : undefined;
}

/// Whether the attachment is a picture that Copy and a drag out can carry.
export function copiesAsImage(attachment: ComposerAttachment): boolean {
  return (attachment.kind === "image" && Boolean(attachment.data)) || linkedPath(attachment) !== undefined;
}

/// The attachment's whole image as a `data:` URL: its own bytes, or its disk image read at full size
/// (a fresh chip's thumbnail is cropped); undefined for anything else, or a file that cannot be read.
export async function fullImageSource(
  attachment: ComposerAttachment,
  read: Read = readLinkedImage,
): Promise<string | undefined> {
  if (attachment.kind === "image" && attachment.data) return `data:${attachment.mimeType};base64,${attachment.data}`;
  const path = linkedPath(attachment);
  return path ? read(path) : undefined;
}

/// Copy: the host puts the image on the pasteboard. False when there was no image to send.
export async function copyAttachmentImage(
  attachment: ComposerAttachment,
  name: string,
  post: Post = postNative,
  read: Read = readLinkedImage,
): Promise<boolean> {
  const src = await fullImageSource(attachment, read);
  if (!src) return false;
  await post("image.copy", { src, name });
  return true;
}

/// A drag out of the strip: the host drags the image's file while the person still holds the press
/// (it refuses one released meanwhile). False when there was no image to send.
export async function dragAttachmentImage(
  attachment: ComposerAttachment,
  name: string,
  post: Post = postNative,
  read: Read = readLinkedImage,
): Promise<boolean> {
  const src = await fullImageSource(attachment, read);
  if (!src) return false;
  await post("image.drag", { src, name });
  return true;
}

/// Cmd-C alone (no Shift, Option or Control): the chip's Copy when the chip has focus.
export function isCopyKey(event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey">): boolean {
  return event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "c";
}
