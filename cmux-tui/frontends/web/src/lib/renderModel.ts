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
} from "cmux/raw";

export interface RenderGraphicsModel {
  generation: bigint;
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
  historyEpoch: bigint | undefined;
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

// Base64 payloads are retained before workers or canvases see them. Bound
// those immutable strings across every render model owned by one app root.
export const RENDER_GRAPHIC_ENCODED_BYTE_CAP = 64 * 1024 * 1024;

interface EncodedGraphicsBudgetState {
  owners: Map<object, number>;
  pendingOwners: Set<object>;
  listeners: Map<object, Set<() => void>>;
  scheduledOwners: Set<object>;
  total: number;
}

const encodedGraphicsBudgets = new WeakMap<object, EncodedGraphicsBudgetState>();

function encodedGraphicsBudgetState(budget: object): EncodedGraphicsBudgetState {
  let state = encodedGraphicsBudgets.get(budget);
  if (state === undefined) {
    state = {
      owners: new Map(),
      pendingOwners: new Set(),
      listeners: new Map(),
      scheduledOwners: new Set(),
      total: 0,
    };
    encodedGraphicsBudgets.set(budget, state);
  }
  return state;
}

function deleteEncodedGraphicsBudgetIfEmpty(
  budget: object,
  state: EncodedGraphicsBudgetState,
): void {
  if (state.owners.size === 0
    && state.listeners.size === 0
    && state.scheduledOwners.size === 0) {
    encodedGraphicsBudgets.delete(budget);
  }
}

function schedulePendingGraphicsRecoveries(
  budget: object,
  state: EncodedGraphicsBudgetState,
  except?: object,
): void {
  for (const owner of state.pendingOwners) {
    if (owner === except
      || state.scheduledOwners.has(owner)
      || !state.listeners.has(owner)) continue;
    state.scheduledOwners.add(owner);
    queueMicrotask(() => {
      state.scheduledOwners.delete(owner);
      if (encodedGraphicsBudgets.get(budget) !== state
        || !state.pendingOwners.has(owner)) {
        deleteEncodedGraphicsBudgetIfEmpty(budget, state);
        return;
      }
      for (const listener of [...(state.listeners.get(owner) ?? [])]) listener();
      deleteEncodedGraphicsBudgetIfEmpty(budget, state);
    });
  }
}

function admitEncodedImages(
  images: readonly RenderGraphicImage[],
  budget: object | undefined,
  owner: object | undefined,
  authoritative: boolean,
): readonly RenderGraphicImage[] {
  if (budget === undefined || owner === undefined) return images;
  const state = encodedGraphicsBudgetState(budget);
  const previous = state.owners.get(owner) ?? 0;
  const otherOwners = state.total - previous;
  const available = Math.max(0, RENDER_GRAPHIC_ENCODED_BYTE_CAP - otherOwners);
  let admittedBytes = 0;
  let rejected = false;
  const admitted: RenderGraphicImage[] = [];
  for (const image of images) {
    const encodedBytes = image.data.length;
    if (encodedBytes > available - admittedBytes) {
      rejected = true;
      continue;
    }
    admitted.push(image);
    admittedBytes += encodedBytes;
  }
  state.total = otherOwners + admittedBytes;
  state.owners.set(owner, admittedBytes);
  if (rejected) state.pendingOwners.add(owner);
  else if (authoritative) state.pendingOwners.delete(owner);
  if (admittedBytes < previous) {
    schedulePendingGraphicsRecoveries(budget, state, authoritative ? owner : undefined);
  }
  return admitted.length === images.length ? images : admitted;
}

export function subscribeRenderModelGraphicsBudget(
  budget: object,
  owner: object,
  listener: () => void,
): () => void {
  const state = encodedGraphicsBudgetState(budget);
  let listeners = state.listeners.get(owner);
  if (listeners === undefined) {
    listeners = new Set();
    state.listeners.set(owner, listeners);
  }
  listeners.add(listener);
  return () => {
    listeners?.delete(listener);
    if (listeners?.size === 0) state.listeners.delete(owner);
    deleteEncodedGraphicsBudgetIfEmpty(budget, state);
  };
}

export function releaseRenderModelGraphicsBudget(budget: object, owner: object): void {
  const state = encodedGraphicsBudgets.get(budget);
  if (state === undefined) return;
  const released = state.owners.get(owner);
  if (released === undefined) return;
  state.owners.delete(owner);
  state.pendingOwners.delete(owner);
  state.total -= released;
  if (released > 0) schedulePendingGraphicsRecoveries(budget, state);
  deleteEncodedGraphicsBudgetIfEmpty(budget, state);
}

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
    && left.anchor_col === right.anchor_col
    && left.anchor_row === right.anchor_row
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
  const expectedBytes = image.width * image.height * channels;
  if (!Number.isSafeInteger(expectedBytes)
    || expectedBytes > RENDER_GRAPHIC_MAX_DECODED_BYTES) {
    throw new CmuxProtocolError(
      `render graphics image ${image.id} pixel data does not match its dimensions`,
    );
  }
  const expectedEncodedLength = Math.ceil(expectedBytes / 3) * 4;
  if (typeof image.data !== "string" || image.data.length !== expectedEncodedLength) {
    throw new CmuxProtocolError(
      `render graphics image ${image.id} pixel data does not match its dimensions`,
    );
  }
  const expectedPadding = (3 - expectedBytes % 3) % 3;
  const hasExpectedPadding = expectedPadding === 0
    ? !image.data.endsWith("=")
    : expectedPadding === 1
      ? image.data.endsWith("=") && !image.data.endsWith("==")
      : image.data.endsWith("==");
  if (!hasExpectedPadding) {
    throw new CmuxProtocolError(`render graphics image ${image.id} data is not padded base64 text`);
  }
  return expectedBytes;
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
  budget?: object,
  owner?: object,
): RenderGraphicsModel {
  if (graphics === undefined) {
    admitEncodedImages([], budget, owner, true);
    return { generation: 0n, images: [], placements: [] };
  }
  const sourceImages = graphics.images ?? [];
  validateAuthoritativeImages(sourceImages);
  const admitted = admitEncodedImages(sourceImages, budget, owner, true);
  const images = Object.freeze(
    admitted.map((image) => Object.freeze({ ...image })),
  );
  validateAuthoritativeImages(images);
  const imageIds = new Set(images.map((image) => image.id));
  return {
    generation: graphics.generation,
    images,
    placements: (graphics.placements ?? [])
      .filter((placement) => imageIds.has(placement.image_id))
      .map((placement) => ({ ...placement })),
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
  budget?: object,
  owner?: object,
): RenderGraphicsModel {
  if (graphics === undefined) return previous;
  const mergedImages = mergeImages(
    previous.images,
    graphics.images ?? [],
    graphics.removed_image_ids ?? [],
  );
  if (mergedImages !== previous.images || !validatedImageMetadata.has(mergedImages)) {
    validateAuthoritativeImages(mergedImages, previous.images);
  }
  const admitted = admitEncodedImages(mergedImages, budget, owner, false);
  const images = admitted === mergedImages
    ? mergedImages
    : Object.freeze([...admitted]);
  if (!validatedImageMetadata.has(images)) {
    validateAuthoritativeImages(images, mergedImages);
  }
  const candidatePlacements = graphics.placements === undefined
    || samePlacements(previous.placements, graphics.placements)
    ? previous.placements
    : graphics.placements.map((placement) => ({ ...placement }));
  const imageIds = new Set(images.map((image) => image.id));
  const filteredPlacements = candidatePlacements.filter(
    (placement) => imageIds.has(placement.image_id),
  );
  const placements = filteredPlacements.length === candidatePlacements.length
    ? candidatePlacements
    : filteredPlacements;
  if (graphics.generation === previous.generation
    && images === previous.images
    && placements === previous.placements) return previous;
  return { generation: graphics.generation, images, placements };
}

export function applySnapshot(
  snapshot: RenderStateEvent,
  graphicsBudget?: object,
  graphicsBudgetOwner?: object,
): RenderModel {
  return {
    surface: snapshot.surface,
    size: { ...snapshot.size },
    cursor: { ...snapshot.cursor },
    defaultFg: snapshot.default_fg,
    defaultBg: snapshot.default_bg,
    scrollbackRows: snapshot.scrollback_rows,
    historyEpoch: snapshot.history_epoch,
    rows: normalizeRows(snapshot.rows, snapshot.size.rows),
    graphics: snapshotGraphics(snapshot.graphics, graphicsBudget, graphicsBudgetOwner),
  };
}

export function applyDelta(
  model: RenderModel,
  delta: RenderDeltaEvent,
  graphicsBudget?: object,
  graphicsBudgetOwner?: object,
): RenderModel {
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
    historyEpoch: delta.history_epoch ?? model.historyEpoch,
    rows,
    graphics: applyGraphicsDelta(
      model.graphics,
      delta.graphics,
      graphicsBudget,
      graphicsBudgetOwner,
    ),
  };
}
