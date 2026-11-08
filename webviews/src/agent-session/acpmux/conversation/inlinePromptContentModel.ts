import type { PromptContentPart } from "../model";

/** Whether a part the strip view keeps in the bubble gives it something to read: typed text with
 * more than space, a pasted block, a text file's body. */
export function readsAsText(part: PromptContentPart): boolean {
  return part.kind === "text" ? part.text.trim() !== "" : part.kind === "pasted" || Boolean(blockText(part));
}

/** The text block a part went to the agent as (typed text, a pasted block, a text file's body), or
 * none for an attachment. */
export function blockText(part: PromptContentPart): string | undefined {
  if (part.kind === "text") return part.text;
  if (part.kind === "pasted" || (part.kind === "file" && !part.uri)) return part.text;
  return undefined;
}

/** The parts the strip setting moves to the band above the bubble: attachments, not what reads as
 * the prompt's text (typed text, pasted blocks and a text file's body stay in the bubble, as a
 * legacy prompt's do), so the bubble keeps the recorded text whole. */
export function isStripMedia(part: PromptContentPart): part is Exclude<PromptContentPart, { kind: "text" }> {
  return blockText(part) === undefined;
}
