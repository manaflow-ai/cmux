// A running turn's run that keeps many entries in sight, cut into rows of a few of them each, so the
// transcript windows it as it windows every other row (VirtualTranscript: the rows in sight and the
// overscan mount, the rest take their measured or estimated height). A coordinator's open turn
// drew every Agent card it ever started in one row, all of them mounted wherever the reader
// looked (chat-100k-flat CASES=coordinator: 151 Agent cards and 3,469 transcript elements mounted
// at 20k records, 16 and 1,332 at 2k). Leo, 2026-11-14: "the dream is infinite chats of infinite
// length with flat or no growth in cpu/memory/even disk".
//
// The cut falls only where a stretch begins (toolGroups.ts `runStretches`): the entry a folded run
// keeps in sight, or the work between two of them. Two step rows stand flush (transcriptGrid.ts:
// a run's rows have no padding of their own, and two step rows no gap), so the parts draw exactly
// as the one row did, and nothing moves when a cut appears. A cut whose part would group its calls
// otherwise on its own (toolGroups reads earlier calls: a message file a later send reads) is not
// made.
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { RUN_PART } from "./runPartId";
import { visibleToolItems } from "./mcpPresentation";
import { runStretches, toolGroups, type RunStretch, type ToolGroup } from "./toolGroups";
import { keyCallId } from "./turnRowsModel";

/// How many stretches a part holds at most: a few cards' worth, so a part is about a screen.
export const RUN_PART_STRETCHES = 8;

/// The parts of `row` (itself while it holds no more than RUN_PART_STRETCHES stretches), by the row.
const partsOf = new WeakMap<AcpmuxRow, AcpmuxRow[]>();

/// `rows` with each run of more than RUN_PART_STRETCHES stretches (an unfolded run's groups) cut into parts.
export function cutLongRuns(rows: AcpmuxRow[]): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  for (let at = 0; at < rows.length; at += 1) {
    const row = rows[at]!;
    const parts = runParts(row);
    if (parts.length === 1 && parts[0] === row) {
      out?.push(row);
      continue;
    }
    out ??= rows.slice(0, at);
    for (const part of parts) out.push(part);
  }
  return out ?? rows;
}

/// One group's kind, as far as a part's own grouping must agree with the whole row's.
const groupKind = (group: ToolGroup) => (group.type === "group" ? `group:${group.kind}` : group.type);

/// The rows `row` draws as: itself, or its parts in order.
export function runParts(row: AcpmuxRow): AcpmuxRow[] {
  // A running turn's run is not folded while live-turn-work is `open` (its default since #48766), so an
  // unfolded run is cut too, at its groups (`cut`).
  if (row.kind !== "activity" || !row.items?.length) return [row];
  // Fewer items than a full part's stretches can hold no more stretches than that.
  if (row.items.length <= RUN_PART_STRETCHES) return [row];
  const kept = partsOf.get(row);
  if (kept) return kept;
  const parts = cut(row);
  partsOf.set(row, parts);
  return parts;
}

function cut(row: AcpmuxRow): AcpmuxRow[] {
  const all = row.items!;
  const visible = visibleToolItems(all)!;
  const groups = toolGroups(visible);
  // An unfolded run is one stretch that folds nothing (toolGroups.ts `runStretches`); its groups stack
  // flush as a folded run's stretches do, so each group is where a cut may fall.
  const stretches: readonly RunStretch[] =
    row.foldRun === true
      ? runStretches(row, groups)
      : groups.map((group, at) => ({
          from: at,
          groups: [group],
          items: "items" in group ? group.items : [group.item],
          fold: false,
        }));
  if (stretches.length <= RUN_PART_STRETCHES) return [row];
  // Where each visible item sits in `all`, so a part keeps the hidden calls among its own.
  const index = new Map<AcpmuxActivity, number>();
  all.forEach((item, at) => index.set(item, at));
  // Each part's first stretch; a part starts at its first stretch's first item.
  const starts: number[] = [];
  for (let at = 0; at < stretches.length; at += RUN_PART_STRETCHES) starts.push(at);
  const firstItem = (stretch: number) => index.get(stretches[stretch]!.items[0]!) ?? 0;
  const groupAt = (stretch: number) => stretches[stretch]!.from;
  const parts: { from: number; to: number; groupFrom: number; groupTo: number }[] = [];
  for (let k = 0; k < starts.length; k += 1) {
    const from = k === 0 ? 0 : firstItem(starts[k]!);
    const to = k + 1 < starts.length ? firstItem(starts[k + 1]!) : all.length;
    const groupFrom = groupAt(starts[k]!);
    const groupTo = k + 1 < starts.length ? groupAt(starts[k + 1]!) : groups.length;
    // Stretches hold the row's items in order; a row whose groups reorder them is not cut.
    if (to <= from) return [row];
    const part = { from, to, groupFrom, groupTo };
    // A part that would group its calls otherwise than the row does joins the part before it.
    const own = toolGroups(visibleToolItems(all.slice(from, to))!);
    const same =
      own.length === groupTo - groupFrom &&
      own.every((group, at) => groupKind(group) === groupKind(groups[groupFrom + at]!));
    const previous = parts.at(-1);
    if (!same && previous) {
      previous.to = to;
      previous.groupTo = groupTo;
    } else parts.push(part);
  }
  if (parts.length === 1) return [row];
  const joined = row.joined ?? [row.id];
  return parts.map((part, k) => {
    const items = all.slice(part.from, part.to);
    const last = k === parts.length - 1;
    const { live: _live, ...rest } = row;
    // The first part keeps the row's id, so what holds its place (the scroll anchor, a measured
    // height) holds the run's top; a later part is named by its first call, which a cut before it
    // does not change.
    const id = k === 0 ? row.id : `${row.id}${RUN_PART}${keyCallId(items) ?? k}`;
    const shown = last ? row : rest;
    return {
      ...shown,
      id,
      items,
      joined,
      version: partVersion(id, items, shown),
      ...(row.toolCount !== undefined && { toolCount: items.filter((item) => item.tool).length }),
    };
  });
}

/// A part's version: the same while it holds the same items (by object, as the turn keeps an
/// unchanged call's) and the run draws them the same way, else a new one. The whole row's version
/// moves with every call in it, and a part that took it would lay out and draw again (VirtualTranscript
/// skips a row whose version holds) for a call in another part.
const PART_VERSIONS_KEPT = 512;
const partVersions = new Map<string, { items: readonly AcpmuxActivity[]; epoch: number }>();
/// One count for every part, so a part dropped from the map and made again never takes a version it
/// had for other items.
let nextEpoch = 0;
function partVersion(id: string, items: readonly AcpmuxActivity[], row: AcpmuxRow): number {
  const was = partVersions.get(id);
  const same =
    was !== undefined && was.items.length === items.length && was.items.every((item, at) => item === items[at]);
  const epoch = same ? was.epoch : (nextEpoch = (nextEpoch + 1) % 100_000_000);
  if (!same) {
    partVersions.delete(id);
    partVersions.set(id, { items, epoch });
    if (partVersions.size > PART_VERSIONS_KEPT) partVersions.delete(partVersions.keys().next().value!);
  }
  const look = (row.live ? 1 : 0) + (row.runOpen ? 2 : 0) + (row.settled ? 4 : 0) + (row.inBackground ? 8 : 0);
  // Below zero, where no row's own version is: the first part keeps the row's id, and a version the
  // row had before its first cut must not read as this one.
  return -1 - (epoch * 16 + look);
}
