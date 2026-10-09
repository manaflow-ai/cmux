// The chat's gallery: every image its replies drew and every render call it ran, in transcript
// order. The summary's Outputs section opens it (GalleryDialog.tsx).
import { chatImages } from "../conversation/chatImages";
import { renderCall, type RenderCall } from "../conversation/renderCall";
import type { AcpmuxRow } from "../model";

export type GalleryItem =
  | { kind: "image"; key: string; src: string; alt: string }
  | { kind: "render"; key: string; call: RenderCall };
export type GalleryFilter = "all" | GalleryItem["kind"];

/// The chat's images (each source once, as the image viewer steps through them) and its render
/// calls that ran, oldest first.
export function chatGallery(rows: readonly AcpmuxRow[]): GalleryItem[] {
  const items: GalleryItem[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (row.kind === "assistant")
      for (const image of chatImages([row])) {
        if (seen.has(image.src)) continue;
        seen.add(image.src);
        items.push({ kind: "image", key: image.src, ...image });
      }
    else if (row.kind === "activity")
      (row.items ?? []).forEach((item, index) => {
        const call = item.tool && renderCall(item.tool);
        if (call) items.push({ kind: "render", key: item.tool!.id || `${row.id}-${index}`, call });
      });
  }
  return items;
}

export const galleryItems = (items: readonly GalleryItem[], filter: GalleryFilter): readonly GalleryItem[] =>
  filter === "all" ? items : items.filter((item) => item.kind === filter);
