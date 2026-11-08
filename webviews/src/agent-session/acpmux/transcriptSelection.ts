import type { ComposerAttachment } from "./attachments";

/// A selected transcript span becomes one named context chip. Each invocation keeps its own id so
/// repeated selections remain available instead of replacing the previous chapter context.
export function transcriptSelectionAttachment(text: string): ComposerAttachment | undefined {
  const value = text.trim();
  if (!value) return undefined;
  return {
    id: `transcript-selection-${crypto.randomUUID()}`,
    kind: "text",
    name: "Selection",
    mimeType: "text/plain",
    size: value.length,
    text: value,
  };
}
