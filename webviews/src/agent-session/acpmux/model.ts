export type AcpmuxRow = {
  id: string;
  version: number;
  at: number;
  kind: string;
  text?: string;
  streaming?: boolean;
  pending?: boolean;
  failed?: boolean;
  items?: AcpmuxActivity[];
  toolCount?: number;
  durationMs?: number;
  status?: string;
  error?: string;
  permission?: AcpmuxPermission;
};

export type AcpmuxActivity = {
  kind: string;
  text: string;
  status?: string;
  tool?: { id: string; title: string; kind?: string; status: string; inputSummary?: string; output?: string };
};

export type AcpmuxPermission = {
  permissionId: string;
  title?: string;
  kind?: string;
  pending: boolean;
  options: { id: string; name: string; allow: boolean }[];
};

export type AcpmuxSnapshot = {
  type: "snapshot";
  protocolVersion: number;
  rows: AcpmuxRow[];
  sessions: { sessionId: string; displayTitle?: string; title?: string; name?: string; status?: string; model?: string }[];
  summary?: { sessionId: string; title?: string; name?: string; harness?: string; model?: string; effort?: string; status?: string; modes?: { availableModes: { id: string; name?: string }[]; currentModeId?: string }; configOptions?: { id: string; name?: string; category?: string; currentValue?: string; options: { value: string; name?: string }[] }[] };
  connection: string;
  sessionId?: string;
  isWorking: boolean;
  queue: { id: string; prompt: string }[];
  permission?: AcpmuxPermission;
  catalog: { id: string; name: string; models: { id: string; name?: string }[] }[];
  canLoadOlder: boolean;
};

export type RowChange = { added: AcpmuxRow[]; updated: AcpmuxRow[]; removed: string[] };

export type PreparedRow = {
  version: number;
  text: string;
  prepared: PreparedText | null;
  blocks: Map<string, PreparedText>;
};

export type ConversationLayout = {
  tops: Float64Array;
  heights: Float64Array;
  totalHeight: number;
};

const MEASURE_FONT = '13px "Helvetica Neue"';
const MESSAGE_LINE_HEIGHT = 20;

export function diffRows(previous: Map<string, AcpmuxRow>, next: AcpmuxRow[]): RowChange {
  const nextById = new Map(next.map((row) => [row.id, row]));
  const added: AcpmuxRow[] = [];
  const updated: AcpmuxRow[] = [];
  for (const row of next) {
    const before = previous.get(row.id);
    if (!before) added.push(row);
    else if (before.version !== row.version) updated.push(row);
  }
  const removed = [...previous.keys()].filter((id) => !nextById.has(id));
  return { added, updated, removed };
}

export function visibleRowRange(rowCount: number, scrollTop: number, viewportHeight: number, estimate = 96, overscan = 8) {
  const first = Math.max(0, Math.floor(scrollTop / estimate) - overscan);
  const last = Math.min(rowCount, Math.ceil((scrollTop + viewportHeight) / estimate) + overscan);
  return { first, last };
}

function fallbackRowHeight(row: AcpmuxRow, width: number): number {
  const textLines = Math.max(1, Math.ceil((row.text?.length ?? 0) / Math.max(24, Math.floor(width / 8))));
  if (row.kind === "activity") return Math.max(46, 24 + (row.items?.length ?? 0) * 20);
  if (row.kind === "turnSummary" || row.kind === "notice" || row.kind === "typing") return 32;
  return 24 + textLines * MESSAGE_LINE_HEIGHT;
}

function measuredRowHeight(row: AcpmuxRow, width: number, cache: Map<string, PreparedRow>): number {
  if (!row.text) return fallbackRowHeight(row, width);
  const previous = cache.get(row.id);
  let entry = previous ?? { version: row.version, text: row.text, prepared: null, blocks: new Map<string, PreparedText>() };
  entry.version = row.version;
  entry.text = row.text;
  if (!entry.blocks.size) {
    try { entry.prepared = prepare(row.text, MEASURE_FONT, { whiteSpace: "pre-wrap" }); } catch { entry.prepared = null; }
  }
  cache.set(row.id, entry);
  const contentWidth = Math.max(80, width - (row.kind === "user" ? 120 : 0));
  const blocks = row.text.split(/\n{2,}/).filter(Boolean);
  if (blocks.length === 0) return fallbackRowHeight(row, width);
  let contentHeight = 0;
  for (const block of blocks) {
    let prepared = entry.blocks.get(block);
    if (!prepared) {
      try { prepared = prepare(block, MEASURE_FONT, { whiteSpace: "pre-wrap" }); entry.blocks.set(block, prepared); } catch { return fallbackRowHeight(row, width); }
    }
    contentHeight += layout(prepared, contentWidth, MESSAGE_LINE_HEIGHT).height;
  }
  return Math.max(34, 16 + contentHeight + Math.max(0, blocks.length - 1) * 8);
}

/** DOM-free row geometry. Only visible rows need their React elements painted. */
export function layoutConversation(rows: AcpmuxRow[], width: number, cache = new Map<string, PreparedRow>(), measureOverride?: (row: AcpmuxRow, width: number) => number | undefined): ConversationLayout {
  const tops = new Float64Array(rows.length);
  const heights = new Float64Array(rows.length);
  let top = 0;
  for (let index = 0; index < rows.length; index += 1) {
    tops[index] = top;
    const customHeight = measureOverride?.(rows[index], width);
    const height = customHeight !== undefined && Number.isFinite(customHeight) && customHeight > 0 ? customHeight : measuredRowHeight(rows[index], width, cache);
    heights[index] = height;
    top += height;
  }
  return { tops, heights, totalHeight: top };
}

function upperBound(values: Float64Array, target: number): number {
  let low = 0;
  let high = values.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (values[middle] <= target) low = middle + 1;
    else high = middle;
  }
  return low;
}

export function visibleLayoutRange(layoutModel: ConversationLayout, scrollTop: number, viewportHeight: number, overscan = 4) {
  if (layoutModel.tops.length === 0) return { first: 0, last: 0 };
  const first = Math.max(0, upperBound(layoutModel.tops, Math.max(0, scrollTop)) - 1 - overscan);
  const last = Math.min(layoutModel.tops.length, upperBound(layoutModel.tops, scrollTop + viewportHeight) + overscan);
  return { first, last };
}
import { layout, prepare, type PreparedText } from "@chenglou/pretext";
