// Settings > Menus: reordering by pointer, at any depth. A row is dragged by its grip with pointer
// events and pointer capture, never HTML5 drag and drop: a native drag runs in AppKit's drag loop,
// so the web view sees no mouse-up and the drop's save is not the person's gesture (the host
// refuses it), and per-row dragenter/dragleave made the drop line blink. The rows are measured
// once when the drag begins; the drop place is worked out over them as the drag shows them, the
// dragged block (a row and what an open submenu shows under it) lifted out, so the gap always opens
// where the pointer is: between any two rows at any depth, into a closed submenu on its name, and
// at a submenu's end the pointer's sideways travel picks in or out. The dragged row moves sideways
// to the depth it will land at, and the save runs on the pointer-up the web view does see.
import { samePath, within, type Path } from "./menuLayouts";

/** One drawn row as the drag measured it: its place in the drawn list and in the tree. */
export type RowBox = {
  flat: number;
  path: Path;
  depth: number;
  top: number;
  bottom: number;
  /** A submenu: rows drop into it. */
  folder: boolean;
  /** An open submenu: its rows are drawn under it. */
  open: boolean;
  /** How many rows a submenu holds. */
  children: number;
};

/**
 * Where a drop lands: index `index` of the submenu at `parent` (`[]`: the top level), as counted
 * before the move, at `depth`. `slot` is where the gap opens among the other rows (the rows
 * without the dragged block), or null for a closed submenu, which takes the row out of sight;
 * `into` names the submenu row to highlight.
 */
export type DropTarget = { parent: Path; index: number; depth: number; slot: number | null; into?: Path };

/** Pointer travel before a press on a grip becomes a drag (a plain click on it does nothing). */
export const DRAG_THRESHOLD = 4;

/** How far one level of submenu indents a row, in CSS pixels; also how far sideways the pointer
 * goes to move a drop one level in or out. */
export const INDENT = 18;

/** The drawn rows the node at `path` covers: itself and what an open submenu shows under it. */
export function block(rows: RowBox[], path: Path): { first: number; last: number } {
  const first = rows.findIndex((row) => samePath(row.path, path));
  let last = first;
  while (last + 1 < rows.length && within(rows[last + 1]!.path, path)) last += 1;
  return { first, last };
}

/** The other rows as they stand while the block `[first, last]` (`height` tall) is lifted out:
 * the rows below it move up by its height. */
function others(rows: RowBox[], first: number, last: number, height: number): RowBox[] {
  return rows
    .filter((row) => row.flat < first || row.flat > last)
    .map((row) => (row.flat > last ? { ...row, top: row.top - height, bottom: row.bottom - height } : row));
}

/**
 * The drop target for the node at `dragged` (its drawn block `height` tall) with the pointer at
 * height `y` and `dx` sideways from where the drag began, or null where it would not move. It is
 * worked out over the rows as the drag shows them (the block lifted out), so the gap opens where
 * the pointer is, between any two rows at any depth:
 * - The middle half of a closed submenu's row drops into it, at its end.
 * - Elsewhere the drop goes between the rows whose middles are around the pointer. Between a row
 *   and one that sits shallower (the end of a submenu), the pointer's sideways travel picks the
 *   level, one level per `INDENT`: left leaves the submenu, right stays in it. An open submenu's
 *   row and its first row take the drop inside it.
 */
export function dropTarget(rows: RowBox[], dragged: Path, height: number, y: number, dx: number): DropTarget | null {
  const own = block(rows, dragged);
  if (own.first < 0) return null;
  const startDepth = rows[own.first]!.depth;
  const rest = others(rows, own.first, own.last, height);
  const parentOf = (path: Path) => path.slice(0, -1);
  const last = (path: Path) => path[path.length - 1]!;
  const unmoved = (parent: Path, index: number) =>
    samePath(parent, parentOf(dragged)) && (index === last(dragged) || index === last(dragged) + 1);
  for (const row of rest) {
    if (!row.folder || row.open) continue;
    const quarter = (row.bottom - row.top) / 4;
    if (y >= row.top + quarter && y <= row.bottom - quarter) {
      return unmoved(row.path, row.children)
        ? null
        : { parent: row.path, index: row.children, depth: row.depth + 1, slot: null, into: row.path };
    }
  }
  let slot = rest.findIndex((row) => (row.top + row.bottom) / 2 >= y);
  if (slot < 0) slot = rest.length;
  const prev = rest[slot - 1];
  const next = rest[slot];
  const deepest = prev ? prev.depth + (prev.folder && prev.open ? 1 : 0) : 0;
  const shallowest = Math.min(next ? next.depth : 0, deepest);
  const depth = Math.max(shallowest, Math.min(deepest, startDepth + Math.round(dx / INDENT)));
  let parent: Path = [];
  let index = 0;
  if (prev && depth === prev.depth + 1) {
    parent = prev.path;
  } else if (prev) {
    parent = prev.path.slice(0, depth);
    index = prev.path[depth]! + 1;
  }
  return unmoved(parent, index) ? null : { parent, index, depth, slot };
}

/**
 * How far each drawn row slides (by `flat`) while the block `[first, last]` (`height` tall) is
 * dragged to gap `slot` among the other rows: the rows below the block move up into its place,
 * and the rows from the gap down move down to open it. No target (`undefined`): nothing slides.
 */
export function shifts(
  rows: RowBox[],
  first: number,
  last: number,
  height: number,
  slot: number | null | undefined,
): Map<number, number> {
  const result = new Map<number, number>();
  if (slot === undefined) return result;
  let index = 0;
  for (const row of rows) {
    if (row.flat >= first && row.flat <= last) continue;
    const by = (row.flat > last ? -height : 0) + (slot !== null && index >= slot ? height : 0);
    if (by) result.set(row.flat, by);
    index += 1;
  }
  return result;
}

/** The drawn rows of `list` (each carries `data-flat`, `data-path` and the rest), in page coordinates. */
export function rowBoxes(list: HTMLElement): RowBox[] {
  return [...list.querySelectorAll<HTMLElement>(":scope > [data-flat]")].map((element) => {
    const rect = element.getBoundingClientRect();
    return {
      flat: Number(element.dataset.flat),
      path: (element.dataset.path ?? "").split(".").filter(Boolean).map(Number),
      depth: Number(element.dataset.depth ?? 0),
      top: rect.top,
      bottom: rect.bottom,
      folder: element.dataset.folder !== undefined,
      open: element.dataset.open !== undefined,
      children: Number(element.dataset.children ?? 0),
    };
  });
}
