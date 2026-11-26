// Shared by the sent-media gallery entries (conversation/SentImages.gallery.tsx,
// conversation/SentVideoTile.gallery.tsx): a painted screenshot or poster of any shape, a read held
// until the play releases it, and the play that proves a sent message's attachments draw in their
// final box from the first frame, whole (Leo, 2026-11-22: "i meant there were various resizing things
// going on, and you guys didn't predict the placements in time").
import type { Play } from "../play";

export type Shot = { width: number; height: number; hue: number };

/// A screenshot-like picture `shot.width`x`shot.height`: a title bar, a sidebar and lines of text.
export function paintShot({ width, height, hue }: Shot, type: "image/png" | "image/jpeg" = "image/png"): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = `hsl(${hue} 30% 16%)`;
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = `hsl(${hue} 30% 24%)`;
  ink.fillRect(0, 0, width, height * 0.07);
  ink.fillRect(0, 0, width * 0.22, height);
  ink.fillStyle = `hsl(${hue} 70% 62%)`;
  for (let line = 0; line < 9; line += 1)
    ink.fillRect(width * 0.27, height * (0.14 + line * 0.08), width * (0.3 + ((line * 37) % 40) / 100), height * 0.025);
  return canvas.toDataURL(type);
}

/// The event the play sends to let the held reads answer.
const RELEASE = "cmux-gallery:release-media";

/// `value` once the play releases the held reads (`attachmentsHoldTheirBoxes`): the first frame draws
/// every attachment before its bytes land, as a long chat's slow read does.
export function heldUntilReleased<T>(value: T): Promise<T> {
  return new Promise((resolve) => window.addEventListener(RELEASE, () => resolve(value), { once: true }));
}

const BOXES =
  ".cv-user, .cv-user__bubble, .cv-user__inline-image, .cv-user__inline-strip, .cv-user__images, .cv-user__video";

type Box = { name: string; rect: DOMRect };

function boxes(document: Document): Box[] {
  return [...document.querySelectorAll(BOXES)].map((element, index) => ({
    name: `${element.className.toString().split(" ")[0]}#${index}`,
    rect: element.getBoundingClientRect(),
  }));
}

/// The sent message draws each attachment in its final box from its first frame: every box (the
/// row, the bubble, each attachment) is where it was before the reads answered, to half a pixel,
/// and no layout shift came from the message (CLS, where the engine reports it). Every picture is
/// whole: a sent image's box and a video's tile have the picture's own shape (within 2%), so no
/// crop and no bands. `inBubble`: the attachments were placed in the text and draw inside the
/// bubble, where they were put.
export function attachmentsHoldTheirBoxes({ inBubble = false }: { inBubble?: boolean } = {}): Play {
  return async ({ waitFor, document }) => {
    const view = document.defaultView!;
    const shifts: number[] = [];
    const types = (view.PerformanceObserver as typeof PerformanceObserver | undefined)?.supportedEntryTypes ?? [];
    const observer = types.includes("layout-shift")
      ? new view.PerformanceObserver((list) => {
          for (const entry of list.getEntries() as (PerformanceEntry & {
            value: number;
            sources?: { node?: Node | null }[];
          })[])
            if (
              entry.sources?.some((source) => source.node && document.querySelector(".cv-user")?.contains(source.node))
            )
              shifts.push(entry.value);
        })
      : undefined;
    observer?.observe({ type: "layout-shift", buffered: true });
    await waitFor(() => document.querySelector(".cv-user__bubble, .cv-user__video, .cv-user__inline-image"));
    // The page's own font, loaded before the chat opens in the app: its swap is not the message's.
    await document.fonts.ready;
    const first = boxes(document);
    view.dispatchEvent(new view.Event(RELEASE));
    const pictures = () => [...document.querySelectorAll<HTMLImageElement>("img.cv-user__image")];
    await waitFor(
      () =>
        pictures().length > 0 &&
        pictures().every((image) => image.complete && image.naturalWidth > 0) &&
        !document.querySelector(".cv-user__image-placeholder"),
    );
    await new Promise((resolve) => view.requestAnimationFrame(() => view.requestAnimationFrame(resolve)));
    observer?.disconnect();
    const last = boxes(document);
    const moves = last.map((box, index) => {
      const was = first[index]?.rect;
      return was
        ? Math.max(
            Math.abs(box.rect.x - was.x),
            Math.abs(box.rect.y - was.y),
            Math.abs(box.rect.width - was.width),
            Math.abs(box.rect.height - was.height),
          )
        : Infinity;
    });
    const shift = shifts.reduce((sum, value) => sum + value, 0);
    // The numbers, before any judgment: a browser test reads them from a build that fails (the
    // before of a change) as well as one that passes.
    document.documentElement.dataset.sentMediaShift = JSON.stringify({
      movedPx: Math.round(Math.max(0, ...moves) * 10) / 10,
      cls: Math.round(shift * 10000) / 10000,
      boxes: [first.length, last.length],
    });
    if (last.length !== first.length) throw new Error(`the message drew ${first.length} boxes, then ${last.length}`);
    for (const [index, box] of last.entries()) {
      const was = first[index]!.rect;
      const moved = moves[index]!;
      if (moved > 0.5)
        throw new Error(
          `${last
            .filter((_, at) => moves[at]! > 0.5)
            .map((one) => one.name)
            .join(", ")} moved; ` +
            `${box.name} moved ${moved.toFixed(1)}px when its reads landed: ${was.width}x${was.height} at ${was.x},${was.y}, then ${box.rect.width}x${box.rect.height} at ${box.rect.x},${box.rect.y}`,
        );
    }
    if (shift > 0.0001) throw new Error(`layout shift ${shift.toFixed(4)} from the message`);
    const bubble = document.querySelector(".cv-user__bubble")?.getBoundingClientRect();
    for (const image of pictures()) {
      // A video's poster draws in its tile: the tile is the box to judge.
      const frame = image.closest(".cv-user__video") ?? image;
      const box = frame.getBoundingClientRect();
      const natural = image.naturalWidth / image.naturalHeight;
      if (Math.abs(box.width / box.height / natural - 1) > 0.02)
        throw new Error(
          `a ${image.naturalWidth}x${image.naturalHeight} picture draws in a ${box.width.toFixed(1)}x${box.height.toFixed(1)} box: cropped or banded`,
        );
      if (box.height > 160.5 || box.width > 480.5)
        throw new Error(`a picture draws ${box.width}x${box.height}, past 480x160`);
      if (
        inBubble &&
        bubble &&
        (box.left < bubble.left - 0.5 ||
          box.right > bubble.right + 0.5 ||
          box.top < bubble.top - 0.5 ||
          box.bottom > bubble.bottom + 0.5)
      )
        throw new Error("a placed attachment draws outside its bubble, not where it was put");
    }
  };
}
