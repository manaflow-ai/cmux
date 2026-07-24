import {
  decodeBase64,
  RENDER_GRAPHIC_MAX_DECODED_BYTES,
  type RenderGraphicImage,
  type RenderGraphicPlacement,
} from "cmux/browser";

const KITTY_BELOW_BACKGROUND_Z = -1_073_741_824;

// Per rendered terminal surface. This admits sixteen 1024px square RGBA
// placements while bounding their simultaneous canvas backing to 64 MiB.
export const RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP = 64 * 1024 * 1024;

// Each placement owns a DOM canvas, 2D context, and ImageData even when its
// pixel backing is tiny. Bound that fixed overhead independently of bytes.
export const RENDER_GRAPHIC_CANVAS_COUNT_CAP = 512;

// Browser canvas limits vary. Keep each intrinsic axis at or below this
// conservative limit even when a thin image would fit the aggregate byte cap.
export const RENDER_GRAPHIC_MAX_CANVAS_DIMENSION = 16_384;

export interface DecodedRenderGraphicImage {
  image: RenderGraphicImage;
  pixels: Uint8ClampedArray<ArrayBuffer>;
}

export interface ResolvedRenderGraphicPlacement {
  key: string;
  layer: "below" | "above";
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

function nonnegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

export function decodeRenderGraphicImage(
  image: RenderGraphicImage,
): DecodedRenderGraphicImage | null {
  if (!nonnegativeInteger(image.width) || !nonnegativeInteger(image.height)
    || image.width === 0 || image.height === 0) return null;
  const pixelCount = image.width * image.height;
  if (!Number.isSafeInteger(pixelCount) || pixelCount <= 0) return null;
  const bytesPerPixel = image.format === "rgb" ? 3 : image.format === "rgba" ? 4 : 0;
  const expectedBytes = pixelCount * bytesPerPixel;
  if (bytesPerPixel === 0 || !Number.isSafeInteger(expectedBytes)
    || expectedBytes > RENDER_GRAPHIC_MAX_DECODED_BYTES) return null;
  const maximumEncodedLength = Math.ceil(expectedBytes / 3) * 4;
  if (image.data.length > maximumEncodedLength) return null;

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

export function resolveRenderGraphicPlacement(
  image: RenderGraphicImage,
  placement: RenderGraphicPlacement,
): ResolvedRenderGraphicPlacement | null {
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
    || placement.source_height === 0
    || placement.z < KITTY_BELOW_BACKGROUND_Z) return null;
  const sourceRight = placement.source_x + placement.source_width;
  const sourceBottom = placement.source_y + placement.source_height;
  if (!Number.isSafeInteger(sourceRight) || !Number.isSafeInteger(sourceBottom)
    || sourceRight > image.width || sourceBottom > image.height) return null;
  if (placement.source_width > RENDER_GRAPHIC_MAX_CANVAS_DIMENSION
    || placement.source_height > RENDER_GRAPHIC_MAX_CANVAS_DIMENSION) return null;
  const sourcePixels = placement.source_width * placement.source_height;
  const backingBytes = sourcePixels * 4;
  if (!Number.isSafeInteger(sourcePixels) || !Number.isSafeInteger(backingBytes)) return null;

  const width = placement.columns > 0
    ? `calc(var(--render-cell-width) * ${placement.columns})`
    : placement.rows > 0
      ? `calc(var(--render-cell-height) * ${
        placement.rows * placement.source_width / placement.source_height
      })`
      : `${placement.source_width}px`;
  const height = placement.rows > 0
    ? `calc(var(--render-cell-height) * ${placement.rows})`
    : placement.columns > 0
      ? `calc(var(--render-cell-width) * ${
        placement.columns * placement.source_height / placement.source_width
      })`
      : `${placement.source_height}px`;

  return {
    key: `${placement.image_id}:${placement.placement_id}:${placement.ordinal}`,
    layer: placement.z < 0 ? "below" : "above",
    z: placement.z,
    backingBytes,
    source: {
      x: placement.source_x,
      y: placement.source_y,
      width: placement.source_width,
      height: placement.source_height,
    },
    style: {
      left: `calc(var(--render-cell-width) * ${placement.viewport_col} + ${placement.x_offset}px)`,
      top: `calc(var(--render-cell-height) * ${placement.viewport_row} + ${placement.y_offset}px)`,
      width,
      height,
    },
  };
}
