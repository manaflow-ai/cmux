// The pixel work of an attached image: its metadata-free preview and its chip's thumbnail. It runs
// in the image worker (imageWorker.ts, through imagePool.ts) so a pasted Retina screenshot never
// stalls typing (Leo, 2026-10-24: "they freeze the composer... this cannot be acceptable"), and
// here on the page only where no worker starts. Nothing in it touches the DOM.

/** Conservative shared preview size; original files stay available through session tools.
 * https://platform.claude.com/docs/en/build-with-claude/vision */
export const MAX_IMAGE_SIDE = 1568;
/** The bytes one attached image may have: past this it is re-encoded (as JPEG) or scaled down. */
export const IMAGE_BUDGET_BYTES = 1536 * 1024;

/// The steps an image that does not fit takes, in order: its longest side, then the JPEG quality.
/// A PNG source tries PNG at each side first (a screenshot's text stays sharp). Past the last step
/// the smallest try goes anyway: an image is never refused for its size (Leo, 2026-10-24: "we
/// shouldn't have this limit").
export const FIT_STEPS = [
  { side: MAX_IMAGE_SIDE, quality: 0.9 },
  { side: MAX_IMAGE_SIDE, quality: 0.8 },
  { side: 1200, quality: 0.75 },
  { side: 800, quality: 0.7 },
  { side: 512, quality: 0.6 },
] as const;

/** The most pixels a picture is decoded at to make its preview: past it, it goes as a file. A
 * 12K x 8K photo (96 MP) is about 400 MB of pixels while it is scaled. */
export const MAX_DECODE_PIXELS = 100_000_000;

/// A PNG, GIF, JPEG or WebP's size from its header (the first 64 KiB), without decoding it;
/// undefined for another type or a header it cannot read.
export async function imageSize(file: Blob): Promise<{ width: number; height: number } | undefined> {
  const bytes = new Uint8Array(await file.slice(0, 64 * 1024).arrayBuffer());
  const view = new DataView(bytes.buffer);
  const at = (offset: number, ...sig: number[]) => sig.every((byte, index) => bytes[offset + index] === byte);
  if (bytes.length >= 24 && at(0, 0x89, 0x50, 0x4e, 0x47) && at(12, 0x49, 0x48, 0x44, 0x52))
    return { width: view.getUint32(16), height: view.getUint32(20) };
  if (bytes.length >= 10 && at(0, 0x47, 0x49, 0x46))
    return { width: view.getUint16(6, true), height: view.getUint16(8, true) };
  if (bytes.length >= 30 && at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) {
    if (at(12, 0x56, 0x50, 0x38, 0x58))
      return { width: 1 + (view.getUint32(24, true) & 0xffffff), height: 1 + (view.getUint32(27, true) & 0xffffff) };
    if (at(12, 0x56, 0x50, 0x38, 0x4c)) {
      const bits = view.getUint32(21, true);
      return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >> 14) & 0x3fff) };
    }
    if (at(12, 0x56, 0x50, 0x38, 0x20))
      return { width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff };
    return undefined;
  }
  if (bytes.length >= 4 && at(0, 0xff, 0xd8)) {
    // A JPEG's frame header (SOF0..SOF15 but DHT, JPG and DAC) names its size.
    for (let offset = 2; offset + 9 < bytes.length;) {
      if (bytes[offset] !== 0xff) return undefined;
      const marker = bytes[offset + 1]!;
      if (marker === 0xff) {
        offset += 1;
        continue;
      }
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc)
        return { width: view.getUint16(offset + 7), height: view.getUint16(offset + 5) };
      offset += 2 + view.getUint16(offset + 2);
    }
  }
  return undefined;
}

export type Thumb = { url: string; width: number; height: number };
/// A fitted image: its type, its bytes as base64, and its chip's thumbnail when one could be drawn.
export type PreparedImage = { mimeType: "image/png" | "image/jpeg"; data: string; thumb?: Thumb };

export function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return btoa(binary);
}

function canDraw(): boolean {
  return typeof createImageBitmap === "function" && typeof OffscreenCanvas === "function";
}

/// Always decode and reencode pixels to strip metadata, including small images. The preview keeps
/// aspect ratio and never upscales, at most 1568 px on its long edge (the conservative standard
/// Claude vision tier: https://platform.claude.com/docs/en/build-with-claude/vision). Its original
/// remains accessible by session path. Undefined when the engine cannot decode it.
export async function prepareImage(file: Blob): Promise<PreparedImage | undefined> {
  if (!canDraw()) return undefined;
  let bitmap: ImageBitmap | undefined;
  try {
    // A picture past the pixel budget is never decoded (a 200-megapixel PNG is 800 MB of pixels):
    // it goes as a file, linked or uploaded, which the agent opens itself.
    const size = await imageSize(file);
    if (size && size.width * size.height > MAX_DECODE_PIXELS) return undefined;
    bitmap = await createImageBitmap(file);
    const fitted = await fit(bitmap, file.type);
    if (!fitted) return undefined;
    const thumb = await drawThumb(bitmap);
    return { ...fitted, ...(thumb ? { thumb } : {}) };
  } catch {
    return undefined;
  } finally {
    bitmap?.close();
  }
}

async function fit(bitmap: ImageBitmap, type: string): Promise<Omit<PreparedImage, "thumb"> | undefined> {
  const longest = Math.max(bitmap.width, bitmap.height, 1);
  let smallest: Blob | undefined;
  let triedPng = 0;
  for (const step of FIT_STEPS) {
    const scale = Math.min(1, step.side / longest);
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    if (type !== "image/jpeg" && triedPng !== width) {
      triedPng = width;
      const canvas = new OffscreenCanvas(width, height);
      const context = canvas.getContext("2d");
      if (!context) return undefined;
      context.drawImage(bitmap, 0, 0, width, height);
      const png = await canvas.convertToBlob({ type: "image/png" });
      if (png.size <= IMAGE_BUDGET_BYTES)
        return { mimeType: "image/png", data: base64(new Uint8Array(await png.arrayBuffer())) };
    }
    const flat = new OffscreenCanvas(width, height);
    const context = flat.getContext("2d");
    if (!context) return undefined;
    context.fillStyle = "#fff";
    context.fillRect(0, 0, width, height);
    context.drawImage(bitmap, 0, 0, width, height);
    smallest = await flat.convertToBlob({ type: "image/jpeg", quality: step.quality });
    if (smallest.size <= IMAGE_BUDGET_BYTES) break;
  }
  return smallest && { mimeType: "image/jpeg", data: base64(new Uint8Array(await smallest.arrayBuffer())) };
}

/// A thumbnail of an image attachment `height`px tall (as a data: URL), in the image's own shape
/// between 0.7:1 and 2:1, its center cropped only past those bounds, so a wide screenshot shows as
/// itself rather than a sliver of its text (Leo, 2026-10-14) and a chip never hands a
/// multi-megabyte image to a small <img>, with the image's natural size (its hover name says it).
export async function drawThumb(bitmap: ImageBitmap, height = 160): Promise<Thumb | undefined> {
  if (!bitmap.width || !bitmap.height) return undefined;
  const ratio = Math.min(2, Math.max(0.7, bitmap.width / bitmap.height));
  const [sourceWidth, sourceHeight] =
    bitmap.width / bitmap.height > ratio
      ? [bitmap.height * ratio, bitmap.height]
      : [bitmap.width, bitmap.width / ratio];
  const canvas = new OffscreenCanvas(Math.round(height * ratio), height);
  const context = canvas.getContext("2d");
  if (!context) return undefined;
  context.drawImage(
    bitmap,
    (bitmap.width - sourceWidth) / 2,
    (bitmap.height - sourceHeight) / 2,
    sourceWidth,
    sourceHeight,
    0,
    0,
    canvas.width,
    canvas.height,
  );
  const blob = await canvas.convertToBlob({ type: "image/png" });
  return {
    url: `data:image/png;base64,${base64(new Uint8Array(await blob.arrayBuffer()))}`,
    width: bitmap.width,
    height: bitmap.height,
  };
}

/// The thumbnail of a staged image's base64 bytes (a chip restored from a draft has no thumbnail
/// yet). Undefined when the engine cannot decode the image or has no OffscreenCanvas.
export async function thumbnailOf(image: { mimeType: string; data: string }): Promise<Thumb | undefined> {
  if (!canDraw()) return undefined;
  let bitmap: ImageBitmap | undefined;
  try {
    const binary = atob(image.data);
    const bytes = new Uint8Array(binary.length);
    for (let at = 0; at < binary.length; at += 1) bytes[at] = binary.charCodeAt(at);
    bitmap = await createImageBitmap(new Blob([bytes], { type: image.mimeType }));
    return await drawThumb(bitmap);
  } catch {
    return undefined;
  } finally {
    bitmap?.close();
  }
}
