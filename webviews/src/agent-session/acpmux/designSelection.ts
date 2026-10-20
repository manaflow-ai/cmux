import type { ComposerAttachment } from "./attachments";

/// Design mode's card for one highlight (Swift `AgentPaneDesignSelection`), pushed by the host as
/// the `designSelection` event (plans/cmux-next/design-mode-DESIGN.md).
export type DesignSelection = {
  id: string;
  name: string;
  text: string;
  image?: { mimeType: string; data: string };
};

const IMAGE_TYPES = new Set(["image/png", "image/jpeg"]);

/// The composer chips for a highlight: a text chip with what the agent reads, then an image chip
/// with the element's crop when there is one. Their ids are the highlight's, so highlighting the
/// same element again replaces them. None for a value that is not a highlight.
export function designSelectionChips(value: unknown): ComposerAttachment[] {
  const raw = (value ?? {}) as Partial<Record<keyof DesignSelection, unknown>>;
  if (typeof raw.id !== "string" || !raw.id || typeof raw.name !== "string" || typeof raw.text !== "string") return [];
  const chips: ComposerAttachment[] = [
    { id: raw.id, kind: "text", name: raw.name, mimeType: "text/plain", size: raw.text.length, text: raw.text },
  ];
  const image = raw.image as { mimeType?: unknown; data?: unknown } | undefined;
  if (
    image &&
    typeof image.mimeType === "string" &&
    IMAGE_TYPES.has(image.mimeType) &&
    typeof image.data === "string"
  ) {
    const extension = image.mimeType === "image/png" ? ".png" : ".jpg";
    chips.push({
      id: `${raw.id}-shot`,
      kind: "image",
      name: `${raw.name}${extension}`,
      mimeType: image.mimeType,
      size: Math.floor((image.data.length * 3) / 4),
      data: image.data,
    });
  }
  return chips;
}

/// The chip ids a `{removed: id}` push takes out of the composer: the highlight's text chip and its
/// screenshot chip. None for any other value.
export function designSelectionRemovals(value: unknown): string[] {
  const removed = (value as { removed?: unknown } | null)?.removed;
  return typeof removed === "string" && removed ? [removed, `${removed}-shot`] : [];
}
