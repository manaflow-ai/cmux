// A Chief's picture as the person chose and placed it (backgrounds plan phase 4). A still is
// cropped to the square they placed in the circle and drawn at 512 px, so a photo of any size fits
// the daemon's 1 MB; a GIF is sent as it is, keeping its motion, and drawn centered.
import { AVATAR_MAX_BYTES, AVATAR_TYPES } from "./daemonPeople";

/** Where the square sits: `zoom` 1 (the short side) to 4, `x`/`y` from -1 (left/top) to 1 across
 * the room the zoom leaves. */
export type PictureCrop = { zoom: number; x: number; y: number };
export const CENTERED: PictureCrop = { zoom: 1, x: 0, y: 0 };
export const MAX_ZOOM = 4;
/** The side a still is drawn at: sharp on the largest avatar disc at 4x. */
export const PICTURE_SIDE = 512;
/** The largest still the page reads; it is drawn down before it is sent. */
export const STILL_MAX_BYTES = 20 * 1024 * 1024;
/** The most pixels a still may have: a small file can still decode to gigabytes. */
export const STILL_MAX_PIXELS = 50_000_000;

/** Whether a picture of `size` may be shown or drawn at all. */
export function withinPixels(size: { width: number; height: number }): boolean {
  return size.width > 0 && size.height > 0 && size.width * size.height <= STILL_MAX_PIXELS;
}

const clamp = (value: number, low: number, high: number) =>
  Math.min(Math.max(Number.isFinite(value) ? value : 0, low), high);

/** The square of a `width`×`height` image that `crop` shows, in image pixels. */
export function cropSquare(width: number, height: number, crop: PictureCrop): { x: number; y: number; side: number } {
  const side = Math.min(width, height) / clamp(crop.zoom, 1, MAX_ZOOM);
  const centerX = width / 2 + clamp(crop.x, -1, 1) * ((width - side) / 2);
  const centerY = height / 2 + clamp(crop.y, -1, 1) * ((height - side) / 2);
  return { x: centerX - side / 2, y: centerY - side / 2, side };
}

/** `crop` moved by a drag of `dx`, `dy` view pixels over a `view`-pixel preview of the square. */
export function dragCrop(
  crop: PictureCrop,
  width: number,
  height: number,
  view: number,
  dx: number,
  dy: number,
): PictureCrop {
  const { side } = cropSquare(width, height, crop);
  const perPixel = side / view;
  // Dragging the picture right shows more of its left: the square moves the other way.
  const move = (value: number, delta: number, room: number) =>
    room > 0 ? clamp(value - (delta * perPixel) / (room / 2), -1, 1) : 0;
  return { ...crop, x: move(crop.x, dx, width - side), y: move(crop.y, dy, height - side) };
}

export type PreparedPicture = { mediaType: string; data: string };
export type PictureRefusal = { error: "type" | "size" | "tooBig" | "pixels" | "unreadable" };
/** Draws the square `rect` of a `size` picture `file` at `side` px and returns it encoded (the
 * browser's canvas; tests pass their own). */
export type PictureRenderer = (
  file: Blob,
  rect: { x: number; y: number; side: number },
  side: number,
  size: { width: number; height: number },
) => Promise<PreparedPicture | null>;

/** The picture the daemon takes for `file` placed by `crop`, or why not. */
export async function preparePicture(
  file: File,
  crop: PictureCrop,
  size: { width: number; height: number },
  render: PictureRenderer = renderSquare,
): Promise<PreparedPicture | PictureRefusal> {
  if (!(AVATAR_TYPES as readonly string[]).includes(file.type)) return { error: "type" };
  if (file.type === "image/gif") {
    if (file.size > AVATAR_MAX_BYTES) return { error: "size" };
    return { mediaType: file.type, data: base64(new Uint8Array(await file.arrayBuffer())) };
  }
  if (file.size > STILL_MAX_BYTES) return { error: "tooBig" };
  if (!withinPixels(size)) return { error: "pixels" };
  const rect = cropSquare(size.width, size.height, crop);
  const drawn = await render(file, rect, Math.min(PICTURE_SIDE, Math.round(rect.side)), size);
  return drawn ?? { error: "unreadable" };
}

/** The canvas renderer: decoded already scaled down to what the square needs, then PNG, or JPEG
 * when a busy photo's PNG would pass 1 MB. */
async function renderSquare(
  file: Blob,
  rect: { x: number; y: number; side: number },
  side: number,
  size: { width: number; height: number },
) {
  const scale = Math.min(1, side / rect.side);
  const bitmap = await createImageBitmap(file, {
    resizeWidth: Math.max(1, Math.round(size.width * scale)),
    resizeHeight: Math.max(1, Math.round(size.height * scale)),
    resizeQuality: "high",
  }).catch(() => null);
  if (!bitmap) return null;
  const canvas = document.createElement("canvas");
  canvas.width = side;
  canvas.height = side;
  const [x, y, s] = [rect.x * scale, rect.y * scale, rect.side * scale];
  canvas.getContext("2d")?.drawImage(bitmap, x, y, s, s, 0, 0, side, side);
  bitmap.close();
  for (const [type, quality] of [
    ["image/png", undefined],
    ["image/jpeg", 0.9],
  ] as const) {
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, type, quality));
    if (blob && blob.size <= AVATAR_MAX_BYTES)
      return { mediaType: type, data: base64(new Uint8Array(await blob.arrayBuffer())) };
  }
  return null;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return btoa(binary);
}
