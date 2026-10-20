import type { ComposerAttachment } from "./attachments";

/// A viewer quote from the app (the `quote` host event, viewer-comments-DESIGN.md): the selected
/// text and the user's comment as a composer text chip. `value` is `{id, title, markdown}`; the
/// chip's name is the card title (`README.md · L12–18`), its text the Markdown the agent reads.
export function quoteAttachment(value: unknown): ComposerAttachment | undefined {
  return undefined;
}
