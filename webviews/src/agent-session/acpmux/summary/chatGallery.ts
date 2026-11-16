// The chat's gallery: reply images, tool media and render calls, in transcript order. The summary's Outputs section opens it (GalleryDialog.tsx).
import { chatImages, type ChatImage } from "../conversation/chatImages";
import { renderCall, type RenderCall } from "../conversation/renderCall";
import { toolImages } from "../toolImages";
import { loadedImageSrc } from "../chips/replyImageModel";
import { mediaKind } from "../chips/mediaKind";
import type { AcpmuxRow } from "../model";
import { PrefixFold } from "../conversation/prefixFlatMap";

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
/// Read on every update while Session Info shows: each row's steps are read again only past the prefix
/// an update kept, and the gallery made again only when the steps changed (PrefixFold), so a streamed
/// token walks neither the chat's rows nor its turns. The result is shared: callers must not change it.
export function chatGallery(rows: readonly AcpmuxRow[]): GalleryItem[] {
  return gallery.read(rows);
}

/// What a row adds to the gallery's walk: a prompt (accepted, or `unsent`), a turn's summary, a
/// reply's images or an activity's tool media and render calls. The marks are constants, so a kept
/// row's steps are the same objects in the next pass.
type Mark = { readonly mark: "prompt" | "unsent" | "summary" };
type Step = Mark | ChatImage | GalleryItem;
const PROMPT: readonly Step[] = [{ mark: "prompt" }];
const UNSENT: readonly Step[] = [{ mark: "unsent" }];
const SUMMARY: readonly Step[] = [{ mark: "summary" }];
const NO_STEPS: readonly Step[] = [];
function rowSteps(row: AcpmuxRow): readonly Step[] {
  if (row.kind === "user") return row.pending || row.failed ? UNSENT : PROMPT;
  if (row.kind === "turnSummary") return SUMMARY;
  if (row.kind === "assistant") return imagesOf(row);
  if (row.kind === "activity") return toolsOf(row);
  return NO_STEPS;
}

const gallery = new PrefixFold<AcpmuxRow, Step, GalleryItem[]>(rowSteps, (steps) => {
  const items: GalleryItem[] = [];
  const seen = new Set<string>();
  // The open turn's items, in order; its renders join only when its summary comes.
  let turn: GalleryItem[] | undefined;
  let started = false;
  const settle = (ended: boolean) => {
    if (turn) items.push(...(ended ? turn : turn.filter((item) => item.kind !== "render")));
    turn = undefined;
  };
  for (const step of steps) {
    if ("mark" in step) {
      // A prompt not yet accepted neither ends a turn nor starts one (turns.ts isUnsent), except
      // the first: with no accepted prompt loaded, the transcript's first turn starts at it.
      if (step.mark === "summary") settle(true);
      else if (!started || step.mark === "prompt") {
        settle(false);
        turn = [];
        started = true;
      }
    } else if (!("kind" in step)) {
      if (seen.has(step.src)) continue;
      seen.add(step.src);
      (turn ?? items).push({ kind: "image", key: step.src, ...step });
    } else if (step.kind === "tool") {
      if (seen.has(step.source)) continue;
      seen.add(step.source);
      (turn ?? items).push(step);
    } else if (turn) turn.push(step);
  }
  settle(false);
  return items;
});

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
