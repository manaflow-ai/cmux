import { useEffect, useRef } from "react";
import type { ComposerAttachment } from "./attachments";
import { postNative } from "./native";

/// Design mode's card for one browser pick (Swift `AgentPaneDesignSelection`), pushed by the host as
/// the `designSelection` event (plans/cmux-next/design-mode-DESIGN.md).
export type DesignSelection = {
  id: string;
  name: string;
  text: string;
  image?: { mimeType: string; data: string };
};

const IMAGE_TYPES = new Set(["image/png", "image/jpeg"]);
/// The id prefix of a pick's chip (Swift `BrowserDesignModeCards`: `design-<hash>`).
export const DESIGN_PICK_PREFIX = "design-";

/// The composer chip for a pick: ONE text chip with what the agent reads, its number and comment,
/// and the element's crop riding inside it (`shot`), sent after its text as an image (David Beyer,
/// 2026-11-20: a text chip and an image chip per pick got visually messy with several picks). Its id
/// is the pick's, so picking or editing the same element again replaces it. None for a value that is
/// not a pick.
export function designSelectionChips(value: unknown): ComposerAttachment[] {
  const raw = (value ?? {}) as Partial<Record<keyof DesignSelection, unknown>>;
  if (typeof raw.id !== "string" || !raw.id || typeof raw.name !== "string" || typeof raw.text !== "string") return [];
  const chip: ComposerAttachment = {
    id: raw.id,
    kind: "text",
    name: raw.name,
    mimeType: "text/plain",
    size: raw.text.length,
    text: raw.text,
  };
  const image = raw.image as { mimeType?: unknown; data?: unknown } | undefined;
  if (image && typeof image.mimeType === "string" && IMAGE_TYPES.has(image.mimeType) && typeof image.data === "string")
    chip.shot = { mimeType: image.mimeType, data: image.data };
  return [chip];
}

/// The chip ids a `{removed: id}` push takes out of the composer: the pick's chip, and the separate
/// crop chip a draft kept from before picks carried their crop. None for any other value.
export function designSelectionRemovals(value: unknown): string[] {
  const removed = (value as { removed?: unknown } | null)?.removed;
  return typeof removed === "string" && removed ? [removed, `${removed}-shot`] : [];
}

/// The picks in `before` that `after` no longer holds: removed by their ×, or sent. The browser takes
/// their pins off its page, so the page's numbers always match the chips.
export function releasedPicks(before: readonly ComposerAttachment[], after: readonly ComposerAttachment[]): string[] {
  const kept = new Set(after.map((attachment) => attachment.id));
  return before
    .filter((attachment) => attachment.id.startsWith(DESIGN_PICK_PREFIX) && !kept.has(attachment.id))
    .map((attachment) => attachment.id);
}

/// Tells the app each time picks leave `attachments` (`designSelection.released {ids}`).
export function useReleasedPicks(attachments: readonly ComposerAttachment[]): void {
  const previous = useRef(attachments);
  useEffect(() => {
    const ids = releasedPicks(previous.current, attachments);
    previous.current = attachments;
    if (ids.length) void postNative("designSelection.released", { ids }).catch(() => undefined);
  }, [attachments]);
}
