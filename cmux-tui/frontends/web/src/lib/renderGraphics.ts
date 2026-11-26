import {
  decodeBase64,
  RENDER_GRAPHIC_MAX_DECODED_BYTES,
  type RenderGraphicImage,
  type RenderGraphicPlacement,
} from "cmux/raw";

const KITTY_BELOW_BACKGROUND_Z = -1_073_741_824;

// Shared by every rendered terminal surface in the browser page. This admits
// sixteen 1024px square RGBA placements while bounding all canvas backing to
// 64 MiB.
export const RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP = 64 * 1024 * 1024;

// Each placement owns a DOM canvas, 2D context, and ImageData even when its
// pixel backing is tiny. Bound that fixed overhead independently of bytes.
export const RENDER_GRAPHIC_CANVAS_COUNT_CAP = 512;

// RGB images expand to RGBA in the decoder. Admit referenced image buffers
// across the whole browser page before workers allocate them.
export const RENDER_GRAPHIC_DECODED_BYTE_CAP = 64 * 1024 * 1024;

// Browser canvas limits vary. Keep each intrinsic axis at or below this
// conservative limit even when a thin image would fit the aggregate byte cap.
export const RENDER_GRAPHIC_MAX_CANVAS_DIMENSION = 16_384;

export interface DecodedRenderGraphicImage {
  image: RenderGraphicImage;
  pixels: Uint8ClampedArray<ArrayBuffer>;
}

export interface ResolvedRenderGraphicPlacement {
  key: string;
  layer: "belowBackground" | "below" | "above";
  z: number;
  backingBytes: number;
  source: { x: number; y: number; width: number; height: number };
  style: {
    left: string;
    top: string;
    width: string;
    height: string;
  };
}

export interface RenderGraphicPlacementPlan {
  key: string;
  layer: "belowBackground" | "below" | "above";
  z: number;
  backingBytes: number;
  source: { x: number; y: number; width: number; height: number };
  viewportCol: number;
  viewportRow: number;
  xOffset: number;
  yOffset: number;
  columns: number;
  rows: number;
}

export function renderGraphicImageKey(image: RenderGraphicImage): string {
  return `${image.id}:${image.generation}`;
}

function nonnegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

export function renderGraphicDecodedByteLength(
  image: RenderGraphicImage,
): number | null {
  if (typeof image.data !== "string") return null;
  if (!nonnegativeInteger(image.width) || !nonnegativeInteger(image.height)
    || image.width === 0 || image.height === 0) return null;
  const pixelCount = image.width * image.height;
  if (!Number.isSafeInteger(pixelCount) || pixelCount <= 0) return null;
  const bytesPerPixel = image.format === "rgb" ? 3 : image.format === "rgba" ? 4 : 0;
  const expectedBytes = pixelCount * bytesPerPixel;
  if (bytesPerPixel === 0 || !Number.isSafeInteger(expectedBytes)
    || expectedBytes > RENDER_GRAPHIC_MAX_DECODED_BYTES) return null;
  const expectedEncodedLength = Math.ceil(expectedBytes / 3) * 4;
  if (image.data.length !== expectedEncodedLength) return null;
  const expectedPadding = (3 - expectedBytes % 3) % 3;
  const hasExpectedPadding = expectedPadding === 0
    ? !image.data.endsWith("=")
    : expectedPadding === 1
      ? image.data.endsWith("=") && !image.data.endsWith("==")
      : image.data.endsWith("==");
  return hasExpectedPadding ? expectedBytes : null;
}

export function renderGraphicRgbaByteLength(
  image: RenderGraphicImage,
): number | null {
  if (renderGraphicDecodedByteLength(image) === null) return null;
  const rgbaBytes = image.width * image.height * 4;
  return Number.isSafeInteger(rgbaBytes) ? rgbaBytes : null;
}

function hasCanonicalBase64Payload(data: string, decodedBytes: number): boolean {
  const padding = (3 - decodedBytes % 3) % 3;
  const payloadLength = data.length - padding;
  for (let index = 0; index < payloadLength; index += 1) {
    const code = data.charCodeAt(index);
    if (!(code >= 65 && code <= 90)
      && !(code >= 97 && code <= 122)
      && !(code >= 48 && code <= 57)
      && code !== 43
      && code !== 47) return false;
  }
  for (let index = payloadLength; index < data.length; index += 1) {
    if (data.charCodeAt(index) !== 61) return false;
  }
  return true;
}

export function decodeRenderGraphicImage(
  image: RenderGraphicImage,
): DecodedRenderGraphicImage | null {
  const expectedBytes = renderGraphicDecodedByteLength(image);
  if (expectedBytes === null || !hasCanonicalBase64Payload(image.data, expectedBytes)) return null;

  let bytes: Uint8Array;
  try {
    bytes = decodeBase64(image.data);
  } catch {
    return null;
  }
  if (bytes.byteLength !== expectedBytes) return null;
  if (image.format === "rgba") {
    const pixels = new Uint8ClampedArray(expectedBytes);
    pixels.set(bytes);
    return { image, pixels };
  }

  const pixelCount = image.width * image.height;
  const pixels = new Uint8ClampedArray(pixelCount * 4);
  for (let source = 0, destination = 0; source < bytes.length; source += 3, destination += 4) {
    pixels[destination] = bytes[source];
    pixels[destination + 1] = bytes[source + 1];
    pixels[destination + 2] = bytes[source + 2];
    pixels[destination + 3] = 255;
  }
  return { image, pixels };
}

/** Decode the current image set while retaining unchanged pixel buffers. */
export function updateDecodedRenderGraphicImages(
  previous: ReadonlyMap<number, DecodedRenderGraphicImage>,
  images: readonly RenderGraphicImage[],
): Map<number, DecodedRenderGraphicImage> {
  const decoded = new Map<number, DecodedRenderGraphicImage>();
  for (const image of images) {
    const cached = previous.get(image.id);
    if (cached?.image === image) {
      decoded.set(image.id, cached);
      continue;
    }
    const candidate = decodeRenderGraphicImage(image);
    if (candidate !== null) decoded.set(image.id, candidate);
  }
  return decoded;
}

export function planRenderGraphicPlacement(
  image: Pick<RenderGraphicImage, "id" | "width" | "height">,
  placement: RenderGraphicPlacement,
): RenderGraphicPlacementPlan | null {
  if (!placement.viewport_visible || placement.image_id !== image.id
    || !Number.isSafeInteger(placement.viewport_col)
    || !Number.isSafeInteger(placement.viewport_row)
    || !nonnegativeInteger(placement.x_offset)
    || !nonnegativeInteger(placement.y_offset)
    || !nonnegativeInteger(placement.source_x)
    || !nonnegativeInteger(placement.source_y)
    || !nonnegativeInteger(placement.source_width)
    || !nonnegativeInteger(placement.source_height)
    || !nonnegativeInteger(placement.columns)
    || !nonnegativeInteger(placement.rows)
    || !Number.isSafeInteger(placement.z)
    || placement.source_width === 0
    || placement.source_height === 0) return null;
  const sourceRight = placement.source_x + placement.source_width;
  const sourceBottom = placement.source_y + placement.source_height;
  if (!Number.isSafeInteger(sourceRight) || !Number.isSafeInteger(sourceBottom)
    || sourceRight > image.width || sourceBottom > image.height) return null;
  if (placement.source_width > RENDER_GRAPHIC_MAX_CANVAS_DIMENSION
    || placement.source_height > RENDER_GRAPHIC_MAX_CANVAS_DIMENSION) return null;
  const sourcePixels = placement.source_width * placement.source_height;
  const backingBytes = sourcePixels * 4;
  if (!Number.isSafeInteger(sourcePixels) || !Number.isSafeInteger(backingBytes)) return null;

  return {
    key: `${placement.image_id}:${placement.placement_id}:${placement.ordinal}`,
    layer: placement.z < KITTY_BELOW_BACKGROUND_Z
      ? "belowBackground"
      : placement.z < 0 ? "below" : "above",
    z: placement.z,
    backingBytes,
    source: {
      x: placement.source_x,
      y: placement.source_y,
      width: placement.source_width,
      height: placement.source_height,
    },
    viewportCol: placement.viewport_col,
    viewportRow: placement.viewport_row,
    xOffset: placement.x_offset,
    yOffset: placement.y_offset,
    columns: placement.columns,
    rows: placement.rows,
  };
}

export function resolveRenderGraphicPlacementPlan(
  plan: RenderGraphicPlacementPlan,
): ResolvedRenderGraphicPlacement {
  const width = plan.columns > 0
    ? `calc(var(--render-cell-width) * ${plan.columns})`
    : plan.rows > 0
      ? `calc(var(--render-cell-height) * ${
        plan.rows * plan.source.width / plan.source.height
      })`
      : `${plan.source.width}px`;
  const height = plan.rows > 0
    ? `calc(var(--render-cell-height) * ${plan.rows})`
    : plan.columns > 0
      ? `calc(var(--render-cell-width) * ${
        plan.columns * plan.source.height / plan.source.width
      })`
      : `${plan.source.height}px`;

  return {
    key: plan.key,
    layer: plan.layer,
    z: plan.z,
    backingBytes: plan.backingBytes,
    source: plan.source,
    style: {
      left: `calc(var(--render-cell-width) * ${plan.viewportCol} + ${plan.xOffset}px)`,
      top: `calc(var(--render-cell-height) * ${plan.viewportRow} + ${plan.yOffset}px)`,
      width,
      height,
    },
  };
}

export function resolveRenderGraphicPlacement(
  image: RenderGraphicImage,
  placement: RenderGraphicPlacement,
): ResolvedRenderGraphicPlacement | null {
  const plan = planRenderGraphicPlacement(image, placement);
  return plan === null ? null : resolveRenderGraphicPlacementPlan(plan);
}
