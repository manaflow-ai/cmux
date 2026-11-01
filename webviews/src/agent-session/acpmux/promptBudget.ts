/// A prompt is one acpmux message, and acpmux refuses one over `rpc::MAX_MESSAGE_BYTES` (31 MiB) as
/// `message.too_large`. No attachment has a size cap (Leo, 2026-10-26: "arbitarrily large file
/// sizes"), and each kind's own cap (an image preview's IMAGE_BUDGET_BYTES, a recording's
/// MAX_AUDIO_BYTES) caps nothing about their sum: ten screenshots' previews passed it (Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size").
import { promptBlocks, type ComposerAttachment, type InlineReadOptions, type PromptBlock } from "./attachments";
import { withoutFrames } from "./composer/videoPrompt";

/// The bytes a prompt's blocks may carry: under acpmux's 31 MiB, with room for the message's
/// envelope (its ids, `_meta`, the bubble's display parts).
export const PROMPT_INLINE_BUDGET = 28 * 1024 * 1024;

/// What each block adds to the message besides its own strings (its keys and quotes).
const BLOCK_OVERHEAD = 64;

/// About the bytes `blocks` take in the prompt's JSON: base64 as it is, text as escaped UTF-8.
export function inlineBytes(blocks: readonly PromptBlock[]): number {
  let total = 0;
  for (const block of blocks) {
    total += BLOCK_OVERHEAD;
    if (block.type === "text") total += jsonBytes(block.text);
    else if (block.type === "resource_link") total += jsonBytes(block.uri) + jsonBytes(block.name);
    else
      total += block.data.length + block.mimeType.length + ("name" in block && block.name ? jsonBytes(block.name) : 0);
  }
  return total;
}

/// The UTF-8 bytes of `text` as a JSON string's contents: a quote, a backslash or a control
/// character is escaped (two bytes, or six for `\uXXXX`).
function jsonBytes(text: string): number {
  let bytes = 0;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (code === 0x22 || code === 0x5c) bytes += 2;
    else if (code < 0x20) bytes += code === 0x0a || code === 0x0d || code === 0x09 ? 2 : 6;
    else if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    // A surrogate pair is one four-byte character: two UTF-16 units of two bytes each.
    else if (code >= 0xd800 && code <= 0xdfff) bytes += 2;
    else bytes += 3;
  }
  return bytes;
}

/// `attachments` with the largest image previews going as the links to their originals, largest
/// first, until the prompt's blocks fit `budget`. Only an image whose original is saved on the
/// chat's machine (`originalPath`) goes so: its preview is a copy, and the link to its original
/// already goes beside it. The person's draft and chips stay as they are; this is only what the
/// prompt carries. The same array when it already fits.
export function fitPromptBudget(
  input: string,
  attachments: ComposerAttachment[],
  options: InlineReadOptions = {},
  budget = PROMPT_INLINE_BUDGET,
): ComposerAttachment[] {
  let total = inlineBytes(promptBlocks(input, attachments, options));
  if (total <= budget) return attachments;
  const previews = attachments
    .filter((chip) => chip.kind === "image" && chip.data && chip.originalPath)
    .sort((a, b) => b.data!.length - a.data!.length);
  const linked = new Map<string, ComposerAttachment>();
  for (const image of previews) {
    if (total <= budget) break;
    if (linked.has(image.id)) continue;
    // Its copies in the draft (attachments.ts `inlineCopyId`) share its original, and go with it: the
    // sent bubble would hide a link whose path a kept preview names as its own original.
    for (const copy of previews) {
      if (copy.originalPath !== image.originalPath || linked.has(copy.id)) continue;
      linked.set(copy.id, originalLink(copy));
      total -= copy.data!.length + copy.mimeType.length + jsonBytes(copy.name) + BLOCK_OVERHEAD;
    }
  }
  const fitted = attachments.map((chip) => linked.get(chip.id) ?? chip);
  // Still too large: the videos' frames stay out, each video going as its link (composer/videoPrompt.ts).
  if (total > budget && fitted.some((chip) => chip.video?.frames.length)) {
    const bare = withoutFrames(fitted);
    if (inlineBytes(promptBlocks(input, bare, options)) < total) return bare;
  }
  return fitted;
}

/// Whether a send must wait for originals still uploading (`uploading`, by chip id) before it goes:
/// the prompt is over `budget` even with every saved original linked, and an image still uploading
/// its original would let it fit. Never for a prompt that fits: it goes at once, its originals
/// staying for the next prompt.
export function awaitsOriginals(
  input: string,
  attachments: readonly ComposerAttachment[],
  uploading: (id: string) => boolean,
  options: InlineReadOptions = {},
  budget = PROMPT_INLINE_BUDGET,
): boolean {
  if (!attachments.some((chip) => chip.kind === "image" && chip.data && !chip.originalPath && uploading(chip.id)))
    return false;
  const fitted = fitPromptBudget(input, [...attachments], options, budget);
  return inlineBytes(promptBlocks(input, fitted, options)) > budget;
}

/// An image as the link to its original on the chat's machine, in its place: its id stays, so it
/// sits where the composer put it, and the agent reads the file there. No type or size: the chip's
/// are its preview's, not the original's, and the prompt's note would name them (`promptText`).
function originalLink(image: ComposerAttachment): ComposerAttachment {
  const path = image.originalPath!;
  const name = image.originalName || path.slice(path.lastIndexOf("/") + 1) || image.name;
  return {
    id: image.id,
    kind: "link",
    ...(image.inline ? { inline: true } : {}),
    name,
    mimeType: "",
    size: 0,
    path,
    saved: true,
  };
}
