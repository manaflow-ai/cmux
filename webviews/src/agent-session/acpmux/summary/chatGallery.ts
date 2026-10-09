// The chat's gallery: every image its replies drew and every render call it ran, in transcript
// order. The summary's Outputs section opens it (GalleryDialog.tsx).
import { chatImages, type ChatImage } from "../conversation/chatImages";
import { renderCall, type RenderCall } from "../conversation/renderCall";
import type { AcpmuxRow } from "../model";

export type GalleryItem =
  | { kind: "image"; key: string; src: string; alt: string }
  | { kind: "render"; key: string; call: RenderCall };
export type GalleryFilter = "all" | GalleryItem["kind"];

/// Each reply's images, kept while the row is the same object: a live turn's updates leave the
/// earlier rows alone, so an open gallery parses only the reply that changed.
const rowImages = new WeakMap<AcpmuxRow, ChatImage[]>();
const imagesOf = (row: AcpmuxRow): ChatImage[] => {
  let images = rowImages.get(row);
  if (!images) rowImages.set(row, (images = chatImages([row])));
  return images;
};

/// The chat's images (each source once, as the image viewer steps through them) and the render
/// calls the transcript draws as cards, oldest first. As turns.ts draws them, a render call is a
/// card only in an ended turn, before its summary; a live turn's call and one after the summary
/// stay tool rows, so they wait here too.
export function chatGallery(rows: readonly AcpmuxRow[]): GalleryItem[] {
  const items: GalleryItem[] = [];
  const seen = new Set<string>();
  // The open turn's items, in order; its renders join only when its summary comes.
  let turn: GalleryItem[] | undefined;
  const settle = (ended: boolean) => {
    if (turn) items.push(...(ended ? turn : turn.filter((item) => item.kind !== "render")));
    turn = undefined;
  };
  for (const row of rows) {
    // A prompt not yet accepted neither ends a turn nor starts one (turns.ts isUnsent).
    if (row.kind === "user" && !row.pending && !row.failed) {
      settle(false);
      turn = [];
    } else if (row.kind === "turnSummary") settle(true);
    else if (row.kind === "assistant")
      for (const image of imagesOf(row)) {
        if (seen.has(image.src)) continue;
        seen.add(image.src);
        (turn ?? items).push({ kind: "image", key: image.src, ...image });
      }
    else if (row.kind === "activity" && turn)
      (row.items ?? []).forEach((item, index) => {
        const call = item.tool && renderCall(item.tool);
        if (call) turn!.push({ kind: "render", key: item.tool!.id || `${row.id}-${index}`, call });
      });
  }
  settle(false);
  return items;
}

export const galleryItems = (items: readonly GalleryItem[], filter: GalleryFilter): readonly GalleryItem[] =>
  filter === "all" ? items : items.filter((item) => item.kind === filter);
