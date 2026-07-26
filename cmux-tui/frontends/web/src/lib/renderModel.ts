import {
  CmuxProtocolError,
  RENDER_GRAPHIC_MAX_DECODED_BYTES,
  RENDER_GRAPHIC_MAX_IMAGES,
  type Id,
  type RenderCursor,
  type RenderDeltaEvent,
  type RenderGraphicImage,
  type RenderGraphicPlacement,
  type RenderGraphics,
  type RenderGraphicsDelta,
  type RenderRow,
  type RenderStateEvent,
} from "cmux/browser";

export interface RenderGraphicsModel {
  generation: number;
  images: readonly RenderGraphicImage[];
  placements: readonly RenderGraphicPlacement[];
}

export interface RenderModel {
  surface: Id;
  size: { cols: number; rows: number };
  cursor: RenderCursor;
  defaultFg: string;
  defaultBg: string;
  scrollbackRows: number;
  rows: readonly RenderRow[];
  graphics: RenderGraphicsModel;
}

interface ValidatedImageMetadata {
  image: RenderGraphicImage;
  decodedBytes: number;
}

const validatedImageMetadata = new WeakMap<
  readonly RenderGraphicImage[],
  ReadonlyMap<number, ValidatedImageMetadata>
>();

function emptyRow(row: number): RenderRow {
  return { row, runs: [] };
}

function normalizeRows(rows: readonly RenderRow[], height: number): readonly RenderRow[] {
  const normalized = Array.from({ length: height }, (_, row) => emptyRow(row));
  for (const candidate of rows) {
    if (!Number.isInteger(candidate.row) || candidate.row < 0 || candidate.row >= height) continue;
    normalized[candidate.row] = { row: candidate.row, runs: [...candidate.runs] };
  }
  return normalized;
}

function samePlacement(left: RenderGraphicPlacement, right: RenderGraphicPlacement): boolean {
  return left.image_id === right.image_id
    && left.placement_id === right.placement_id
    && left.ordinal === right.ordinal
    && left.x_offset === right.x_offset
    && left.y_offset === right.y_offset
    && left.source_x === right.source_x
    && left.source_y === right.source_y
    && left.source_width === right.source_width
    && left.source_height === right.source_height
    && left.columns === right.columns
    && left.rows === right.rows
    && left.grid_cols === right.grid_cols
    && left.grid_rows === right.grid_rows
    && left.pixel_width === right.pixel_width
    && left.pixel_height === right.pixel_height
    && left.viewport_col === right.viewport_col
    && left.viewport_row === right.viewport_row
    && left.viewport_visible === right.viewport_visible
    && left.z === right.z;
}

function samePlacements(
  left: readonly RenderGraphicPlacement[],
  right: readonly RenderGraphicPlacement[],
): boolean {
  return left.length === right.length
    && left.every((placement, index) => samePlacement(placement, right[index]!));
}

function sameImage(left: RenderGraphicImage, right: RenderGraphicImage): boolean {
  return left.id === right.id
    && left.generation === right.generation
    && left.width === right.width
    && left.height === right.height
    && left.format === right.format
    && left.data === right.data;
}

function decodedImageBytes(image: RenderGraphicImage): number {
  if (!Number.isSafeInteger(image.width) || image.width <= 0
    || !Number.isSafeInteger(image.height) || image.height <= 0) {
    throw new CmuxProtocolError(`render graphics image ${image.id} has invalid dimensions`);
  }
  const channels = image.format === "rgb" ? 3 : image.format === "rgba" ? 4 : 0;
  if (channels === 0) {
    throw new CmuxProtocolError(`render graphics image ${image.id} has an invalid format`);
  }
  if (typeof image.data !== "string" || image.data.length % 4 !== 0) {
    throw new CmuxProtocolError(`render graphics image ${image.id} data is not padded base64 text`);
  }

  const padding = image.data.endsWith("==") ? 2 : image.data.endsWith("=") ? 1 : 0;
  const payloadLength = image.data.length - padding;
  for (let index = 0; index < image.data.length; index += 1) {
    const code = image.data.charCodeAt(index);
    const payload = index < payloadLength;
    const base64 = code >= 65 && code <= 90
      || code >= 97 && code <= 122
      || code >= 48 && code <= 57
      || code === 43
      || code === 47;
    if (payload ? !base64 : code !== 61) {
      throw new CmuxProtocolError(
        `render graphics image ${image.id} data is not padded base64 text`,
      );
    }
  }
  const decodedBytes = (image.data.length / 4) * 3 - padding;
  const expectedBytes = image.width * image.height * channels;
  if (!Number.isSafeInteger(expectedBytes)
    || expectedBytes > RENDER_GRAPHIC_MAX_DECODED_BYTES
    || decodedBytes !== expectedBytes) {
    throw new CmuxProtocolError(
      `render graphics image ${image.id} pixel data does not match its dimensions`,
    );
  }
  return decodedBytes;
}

function validateAuthoritativeImages(
  images: readonly RenderGraphicImage[],
  previous?: readonly RenderGraphicImage[],
): void {
  if (images.length > RENDER_GRAPHIC_MAX_IMAGES) {
    throw new CmuxProtocolError(
      `render graphics state exceeds ${RENDER_GRAPHIC_MAX_IMAGES} images`,
    );
  }

  let decodedBytes = 0;
  const ids = new Set<number>();
  const previousMetadata = previous === undefined
    ? undefined
    : validatedImageMetadata.get(previous);
  const metadata = new Map<number, ValidatedImageMetadata>();
  for (const image of images) {
    if (ids.has(image.id)) {
      throw new CmuxProtocolError(`render graphics state contains duplicate image ${image.id}`);
    }
    ids.add(image.id);
    const retained = previousMetadata?.get(image.id);
    const imageBytes = retained?.image === image
      ? retained.decodedBytes
      : decodedImageBytes(image);
    decodedBytes += imageBytes;
    if (decodedBytes > RENDER_GRAPHIC_MAX_DECODED_BYTES) {
      throw new CmuxProtocolError(
        `render graphics state exceeds ${RENDER_GRAPHIC_MAX_DECODED_BYTES} decoded image bytes`,
      );
    }
    metadata.set(image.id, { image, decodedBytes: imageBytes });
  }
  validatedImageMetadata.set(images, metadata);
}

function snapshotGraphics(
  graphics: RenderGraphics | undefined,
): RenderGraphicsModel {
  if (graphics === undefined) return { generation: 0, images: [], placements: [] };
  const images = Object.freeze(
    (graphics.images ?? []).map((image) => Object.freeze({ ...image })),
  );
  validateAuthoritativeImages(images);
  return {
    generation: graphics.generation,
    images,
    placements: (graphics.placements ?? []).map((placement) => ({ ...placement })),
  };
}

function mergeImages(
  previous: readonly RenderGraphicImage[],
  upserts: readonly RenderGraphicImage[],
  removals: readonly number[],
): readonly RenderGraphicImage[] {
  if (upserts.length === 0 && removals.length === 0) return previous;
  const removed = new Set(removals);
  const pending = new Map(upserts.map((image) => [image.id, image]));
  const merged: RenderGraphicImage[] = [];
  let changed = false;
  for (const image of previous) {
    if (removed.has(image.id) && !pending.has(image.id)) {
      changed = true;
      continue;
    }
    const upsert = pending.get(image.id);
    if (upsert === undefined) {
      merged.push(image);
      continue;
    }
    pending.delete(image.id);
    if (sameImage(image, upsert)) {
      merged.push(image);
    } else {
      merged.push(Object.freeze({ ...upsert }));
      changed = true;
    }
  }
  for (const upsert of pending.values()) {
    merged.push(Object.freeze({ ...upsert }));
    changed = true;
  }
  return changed ? Object.freeze(merged) : previous;
}

function applyGraphicsDelta(
  previous: RenderGraphicsModel,
  graphics: RenderGraphicsDelta | undefined,
): RenderGraphicsModel {
  if (graphics === undefined) return previous;
  const images = mergeImages(
    previous.images,
    graphics.images ?? [],
    graphics.removed_image_ids ?? [],
  );
  if (images !== previous.images || !validatedImageMetadata.has(images)) {
    validateAuthoritativeImages(images, previous.images);
  }
  const placements = graphics.placements === undefined
    || samePlacements(previous.placements, graphics.placements)
    ? previous.placements
    : graphics.placements.map((placement) => ({ ...placement }));
  if (graphics.generation === previous.generation
    && images === previous.images
    && placements === previous.placements) return previous;
  return { generation: graphics.generation, images, placements };
}

export function applySnapshot(snapshot: RenderStateEvent): RenderModel {
  return {
    surface: snapshot.surface,
    size: { ...snapshot.size },
    cursor: { ...snapshot.cursor },
    defaultFg: snapshot.default_fg,
    defaultBg: snapshot.default_bg,
    scrollbackRows: snapshot.scrollback_rows,
    rows: normalizeRows(snapshot.rows, snapshot.size.rows),
    graphics: snapshotGraphics(snapshot.graphics),
  };
}

export function applyDelta(model: RenderModel, delta: RenderDeltaEvent): RenderModel {
  // Attachment streams are ordered, but a stale event can still be buffered
  // after a surface switch. Never let it mutate the replacement attachment.
  if (delta.surface !== model.surface) return model;

  const size = delta.size === undefined ? model.size : { ...delta.size };
  const replacesViewport = delta.full || delta.size !== undefined;
  let rows = model.rows;
  if (replacesViewport) {
    rows = normalizeRows(delta.rows, size.rows);
  } else if (delta.rows.length > 0) {
    const next = [...model.rows];
    for (const candidate of delta.rows) {
      if (!Number.isInteger(candidate.row) || candidate.row < 0 || candidate.row >= size.rows) continue;
      next[candidate.row] = { row: candidate.row, runs: [...candidate.runs] };
    }
    rows = next;
  }

  return {
    surface: model.surface,
    size,
    cursor: { ...delta.cursor },
    defaultFg: delta.default_fg ?? model.defaultFg,
    defaultBg: delta.default_bg ?? model.defaultBg,
    scrollbackRows: delta.scrollback_rows ?? model.scrollbackRows,
    rows,
    graphics: applyGraphicsDelta(model.graphics, delta.graphics),
  };
}
