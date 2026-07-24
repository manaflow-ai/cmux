import type {
  Id,
  RenderCursor,
  RenderDeltaEvent,
  RenderGraphicImage,
  RenderGraphicPlacement,
  RenderGraphics,
  RenderRow,
  RenderStateEvent,
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

function snapshotGraphics(
  graphics: RenderGraphics | undefined,
): RenderGraphicsModel {
  if (graphics === undefined) return { generation: 0, images: [], placements: [] };
  return {
    generation: graphics.generation,
    images: (graphics.images ?? []).map((image) => ({ ...image })),
    placements: graphics.placements.map((placement) => ({ ...placement })),
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
      merged.push({ ...upsert });
      changed = true;
    }
  }
  for (const upsert of pending.values()) {
    merged.push({ ...upsert });
    changed = true;
  }
  return changed ? merged : previous;
}

function applyGraphicsDelta(
  previous: RenderGraphicsModel,
  graphics: RenderGraphics | undefined,
): RenderGraphicsModel {
  if (graphics === undefined) return previous;
  const images = mergeImages(
    previous.images,
    graphics.images ?? [],
    graphics.removed_image_ids ?? [],
  );
  const placements = samePlacements(previous.placements, graphics.placements)
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
