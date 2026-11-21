import { type StringKey, type Translate } from "../i18n";
import type { DragSummary } from "./dropOverlayState";

export const DROP_LABELS = {
  title: "composer.drop.title",
  refusedTitle: "composer.drop.refusedTitle",
  imagesUnsupported: "composer.imagesUnsupported",
  photos: "composer.drop.photos",
  pdf: "composer.drop.pdf",
  pdfs: "composer.drop.pdfs",
  files: "composer.drop.files",
} as const satisfies Record<string, StringKey>;

/// What the drag holds, in a few words ("3 photos", "PDF", "2 files"); empty when the engine showed
/// no items.
export function dropHint(summary: DragSummary, t: Translate): string {
  const n = summary.count;
  if (n === 0) return "";
  if (summary.kind === "photos") return t(DROP_LABELS.photos, { n });
  if (summary.kind === "pdfs") return n === 1 ? t(DROP_LABELS.pdf) : t(DROP_LABELS.pdfs, { n });
  return t(DROP_LABELS.files, { n });
}
