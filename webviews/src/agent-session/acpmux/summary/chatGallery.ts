// The chat's gallery: reply images, tool media and render calls, in transcript order. The summary's Outputs section opens it (GalleryDialog.tsx).
import { chatImages, type ChatImage } from "../conversation/chatImages";
import { renderCall, type RenderCall } from "../conversation/renderCall";
import { toolImages } from "../toolImages";
import { loadedImageSrc } from "../chips/ReplyImage";
import { mediaKind } from "../chips/mediaKind";
import type { AcpmuxRow } from "../model";

export type GalleryItem =
  | { kind: "image"; key: string; src: string; alt: string }
  | { kind: "tool"; key: string; source: string }
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

/// Discovery only: local files still load through the host when their gallery tile is mounted.
const rowTools = new WeakMap<AcpmuxRow, GalleryItem[]>();
const toolsOf = (row: AcpmuxRow): GalleryItem[] => {
  let items = rowTools.get(row);
  if (!items) {
    items = [];
    for (const [index, item] of (row.items ?? []).entries()) {
      const tool = item.tool;
      if (!tool) continue;
      if (tool.status !== "pending" && tool.status !== "in_progress")
        for (const source of toolImages(tool)) items.push({ kind: "tool", key: source, source });
      const call = renderCall(tool);
      if (call) items.push({ kind: "render", key: tool.id || `${row.id}-${index}`, call });
    }
    rowTools.set(row, items);
  }
  return items;
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
  let started = false;
  const settle = (ended: boolean) => {
    if (turn) items.push(...(ended ? turn : turn.filter((item) => item.kind !== "render")));
    turn = undefined;
  };
  for (const row of rows) {
    // A prompt not yet accepted neither ends a turn nor starts one (turns.ts isUnsent), except
    // the first: with no accepted prompt loaded, the transcript's first turn starts at it.
    if (row.kind === "user" && (!started || (!row.pending && !row.failed))) {
      settle(false);
      turn = [];
      started = true;
    } else if (row.kind === "turnSummary") settle(true);
    else if (row.kind === "assistant")
      for (const image of imagesOf(row)) {
        if (seen.has(image.src)) continue;
        seen.add(image.src);
        (turn ?? items).push({ kind: "image", key: image.src, ...image });
      }
    else if (row.kind === "activity")
      for (const item of toolsOf(row)) {
        if (item.kind === "tool") {
          if (seen.has(item.source)) continue;
          seen.add(item.source);
          (turn ?? items).push(item);
        } else if (turn) turn.push(item);
      }
  }
  settle(false);
  return items;
}

export const galleryItems = (items: readonly GalleryItem[], filter: GalleryFilter): readonly GalleryItem[] =>
  filter === "all" ? items : items.filter((item) => item.kind === filter);

/// The image viewer's images when `src` opens (`path`: the file it was read from, when it has one):
/// the gallery's images in order. The viewer draws data URLs only (the page loads no file itself),
/// so a tool file steps in once its tile loaded it, and the one just opened always does; a tool's
/// audio and video are not images.
export function viewerImages(
  rows: readonly AcpmuxRow[],
  src: string,
  alt: string,
  path?: string,
): { images: ChatImage[]; index: number } {
  const gallery = chatGallery(rows);
  // The file the viewer was opened from, when the gallery holds it: it decides which entry opens, so two
  // files that loaded identical bytes stay two entries, each with its own path.
  const byPath = path !== undefined && gallery.some((item) => item.kind === "tool" && item.source === path);
  const images: (ChatImage & { open: boolean })[] = [];
  for (const item of gallery) {
    if (item.kind === "image") images.push({ src: item.src, alt: item.alt, open: !byPath && item.src === src });
    else if (item.kind === "tool") {
      if (item.source.startsWith("data:"))
        images.push({ src: item.source, alt: "", open: !byPath && item.source === src });
      else if (!mediaKind(item.source)) {
        const loaded = loadedImageSrc(item.source);
        const open = byPath ? item.source === path : loaded !== undefined && loaded === src;
        if (loaded || open) images.push({ src: loaded ?? src, alt: "", path: item.source, open });
      }
    }
  }
  const index = images.findIndex((image) => image.open);
  if (index < 0) return { images: [{ src, alt, path }], index: 0 };
  return {
    images: images.map(({ open: _open, ...image }, i) =>
      i === index ? { ...image, src, alt: alt || image.alt, ...(path ? { path } : {}) } : image,
    ),
    index,
  };
}
