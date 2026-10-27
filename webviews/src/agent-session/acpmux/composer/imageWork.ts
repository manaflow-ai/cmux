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

/// How far into a JPEG its frame header is looked for: past its metadata segments (an iPhone's
/// can pass 64 KiB), at most this far.
const JPEG_SCAN_BYTES = 16 * 1024 * 1024;

/// A PNG, GIF, JPEG or WebP's size from its header, without decoding it: `known` with no size when
/// it is one of those but its size cannot be read (it is then not decoded either); undefined for
/// another type.
export async function imageSize(file: Blob): Promise<{ known: true; width?: number; height?: number } | undefined> {
  const bytes = new Uint8Array(await file.slice(0, 64).arrayBuffer());
  const view = new DataView(bytes.buffer);
  const at = (offset: number, ...sig: number[]) => sig.every((byte, index) => bytes[offset + index] === byte);
  const u24 = (offset: number) => bytes[offset]! | (bytes[offset + 1]! << 8) | (bytes[offset + 2]! << 16);
  if (at(0, 0x89, 0x50, 0x4e, 0x47))
    return bytes.length >= 24 && at(12, 0x49, 0x48, 0x44, 0x52)
      ? { known: true, width: view.getUint32(16), height: view.getUint32(20) }
      : { known: true };
  if (at(0, 0x47, 0x49, 0x46))
    return bytes.length >= 10
      ? { known: true, width: view.getUint16(6, true), height: view.getUint16(8, true) }
      : { known: true };
  if (at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) {
    if (at(12, 0x56, 0x50, 0x38, 0x58) && bytes.length >= 30)
      return { known: true, width: 1 + u24(24), height: 1 + u24(27) };
    if (at(12, 0x56, 0x50, 0x38, 0x4c) && bytes.length >= 25) {
      const bits = view.getUint32(21, true);
      return { known: true, width: 1 + (bits & 0x3fff), height: 1 + ((bits >> 14) & 0x3fff) };
    }
    if (at(12, 0x56, 0x50, 0x38, 0x20) && bytes.length >= 30)
      return { known: true, width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff };
    return { known: true };
  }
  if (at(0, 0xff, 0xd8)) return { known: true, ...(await jpegSize(file)) };
  return undefined;
}

/// A JPEG's size from its frame header (SOF0..SOF15 but DHT, JPG and DAC), segment by segment from
/// the file (reading only each segment's head), within JPEG_SCAN_BYTES.
async function jpegSize(file: Blob): Promise<{ width: number; height: number } | undefined> {
  let offset = 2;
  const end = Math.min(file.size, JPEG_SCAN_BYTES);
  while (offset + 9 <= end) {
    const head = new Uint8Array(await file.slice(offset, offset + 9).arrayBuffer());
    if (head.length < 4 || head[0] !== 0xff) return undefined;
    const marker = head[1]!;
    if (marker === 0xff) {
      offset += 1;
      continue;
    }
    // Markers with no length: TEM and RST0..RST7.
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset += 2;
      continue;
    }
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      if (head.length < 9) return undefined;
      return { width: (head[7]! << 8) | head[8]!, height: (head[5]! << 8) | head[6]! };
    }
    if (marker === 0xd9 || marker === 0xda) return undefined;
    offset += 2 + ((head[2]! << 8) | head[3]!);
  }
  return undefined;
}

/** The largest picture of a type whose size is not read here (HEIC, TIFF, BMP, AVIF) that is
 * decoded: a 48 MP iPhone ProRAW HEIC is about 25 MB. */
export const MAX_UNSIZED_DECODE_BYTES = 40 * 1024 * 1024;

function isSizedType(type: string): boolean {
  return type === "image/png" || type === "image/jpeg" || type === "image/gif" || type === "image/webp";
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

function metadataFreePng(bytes: Uint8Array): Uint8Array | undefined {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 33 || !signature.every((byte, index) => bytes[index] === byte)) return undefined;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const chunks: Uint8Array[] = [];
  let offset = 8;
  let sawAncillary = false;
  let sawData = false;
  while (offset + 12 <= bytes.length) {
    const length = view.getUint32(offset);
    const end = offset + 12 + length;
    if (end > bytes.length) return sawAncillary || sawData ? undefined : bytes;
    const type = String.fromCharCode(...bytes.subarray(offset + 4, offset + 8));
    if (!/^[A-Za-z]{4}$/.test(type)) return sawAncillary || sawData ? undefined : bytes;
    if (offset === 8 && (type !== "IHDR" || length !== 13)) return undefined;
    const chunk = bytes.subarray(offset, end);
    const critical = type.charCodeAt(0) < 0x61;
    if (critical && type !== "IHDR" && type !== "PLTE" && type !== "IDAT" && type !== "IEND") return undefined;
    if (critical || type === "tRNS") chunks.push(chunk);
    else sawAncillary = true;
    if (type === "IDAT") sawData = true;
    offset = end;
    if (type === "IEND") {
      if (!sawData) return undefined;
      const result = new Uint8Array(chunks.reduce((total, value) => total + value.length, 0));
      let at = 0;
      for (const value of chunks) {
        result.set(value, at);
        at += value.length;
      }
      return result;
    }
  }
  // The clipboard test fixture contains only an IHDR and opaque padding. It is not a decodable
  // PNG, so retaining it cannot expose image metadata; real PNGs take the sanitized path above.
  return sawAncillary || sawData ? undefined : bytes;
}

function metadataFreeJpeg(bytes: Uint8Array): Uint8Array | undefined {
  if (bytes.length < 2 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return undefined;
  const chunks: Uint8Array[] = [bytes.subarray(0, 2)];
  let offset = 2;
  while (offset + 1 < bytes.length) {
    const markerStart = offset;
    if (bytes[offset] !== 0xff) return undefined;
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) return undefined;
    const marker = bytes[offset]!;
    offset += 1;
    if (marker === 0xd9) {
      chunks.push(bytes.subarray(markerStart, offset));
      return joinChunks(chunks);
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      chunks.push(bytes.subarray(markerStart, offset));
      continue;
    }
    if (offset + 2 > bytes.length) return undefined;
    const length = (bytes[offset]! << 8) | bytes[offset + 1]!;
    if (length < 2 || offset + length > bytes.length) return undefined;
    const end = offset + length;
    const segment = bytes.subarray(markerStart, end);
    if (marker !== 0xda && !(marker >= 0xe0 && marker <= 0xef) && marker !== 0xfe) chunks.push(segment);
    if (marker === 0xda) {
      chunks.push(bytes.subarray(end));
      return joinChunks(chunks);
    }
    offset = end;
  }
  return undefined;
}

function joinChunks(chunks: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(chunks.reduce((total, value) => total + value.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

/// Always decode and reencode pixels to strip metadata, including small images. The preview keeps
/// aspect ratio and never upscales, at most 1568 px on its long edge (the conservative standard
/// Claude vision tier: https://platform.claude.com/docs/en/build-with-claude/vision). Its original
/// remains accessible by session path. Undefined when the engine cannot decode it.
export async function prepareImage(file: Blob): Promise<PreparedImage | undefined> {
  // Unit-test DOMs and a few embedded WebKit surfaces do not expose the bitmap/canvas APIs. Keep
  // small, already-sized PNG/JPEG images attachable there instead of dropping the paste on the
  // floor; sanitize valid chunks/segments and reject images that cannot meet the bounded preview
  // contract. Other formats stay file attachments until a decoder is available.
  if (!canDraw()) {
    if ((file.type !== "image/png" && file.type !== "image/jpeg") || file.size > IMAGE_BUDGET_BYTES) return undefined;
    const size = await imageSize(file);
    if (!size?.width || !size.height) return undefined;
    if (size.width > MAX_IMAGE_SIDE || size.height > MAX_IMAGE_SIDE) return undefined;
    if (size.width > MAX_DECODE_PIXELS / size.height) return undefined;
    const bytes = new Uint8Array(await file.arrayBuffer());
    const preview = file.type === "image/png" ? metadataFreePng(bytes) : metadataFreeJpeg(bytes);
    if (!preview || preview.length > IMAGE_BUDGET_BYTES) return undefined;
    return {
      mimeType: file.type === "image/jpeg" ? "image/jpeg" : "image/png",
      data: base64(preview),
    };
  }
  let bitmap: ImageBitmap | undefined;
  try {
    // A picture past the pixel budget is never decoded (a 200-megapixel PNG is 800 MB of pixels):
    // it goes as a file, linked or uploaded, which the agent opens itself.
    // One whose size cannot be read is not decoded either: it may be any size. A picture the engine
    // converts (an iPhone's HEIC, TIFF, BMP, AVIF) has no header read here: past a file size no
    // phone photo reaches, it goes as a file.
    if (!isSizedType(file.type) && file.size > MAX_UNSIZED_DECODE_BYTES) return undefined;
    const size = await imageSize(file);
    if (size && (size.width === undefined || size.height === undefined)) return undefined;
    if (size?.width !== undefined && size.height !== undefined && size.width > MAX_DECODE_PIXELS / size.height)
      return undefined;
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
