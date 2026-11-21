// One page of a chat's records as acpmux reads it for `_acpmux/attach` and `_acpmux/events`
// (cmux-tui/crates/acpmux/src/hub/paging.rs `events_page`, newest first): the newest `limit`
// records before `beforeSeq`, which also ends before its records' JSON passes `maxBytes`
// (`page_bytes`: 1 MiB when the ask names none, at most 4 MiB), and always holds one record.
// A page the ask bounds by bytes also leaves out what newer tool call updates in it make moot
// (store/superseded.rs, ported below), so a command's cumulative output updates fold to its newest.
// The benches' stand-in daemons page with it, so a chat with MB tool outputs opens on the page the
// pane would get, not on 400 records of any size (a god session's were 1.2 MB against the pane's
// 128 KiB ask).

/// paging.rs DEFAULT_PAGE_BYTES and MAX_PAGE_BYTES.
export const DEFAULT_PAGE_BYTES = 1 << 20;
export const MAX_PAGE_BYTES = 4 << 20;

/// paging.rs `record_bytes`: a record's JSON and room for its envelope.
export const recordBytes = (record: unknown) => JSON.stringify(record).length + 120;

/// paging.rs MAX_RECORD_BYTES: the most one record may hold in a page (rpc.rs MAX_MESSAGE_BYTES, 31 MiB, less
/// one MiB for the reply around it), and ENVELOPE_FIELD_BYTES, the longest kind a stub keeps.
export const MAX_RECORD_BYTES = (31 << 20) - (1 << 20);
const ENVELOPE_FIELD_BYTES = 1 << 10;

/// paging.rs `fit_sized`: a record no message can carry goes as a stub with its seq and time, its `msg` what it
/// left out and how much, and its kind unless that is the large part (a copy). Also returns what it adds.
function fit<T extends Rec>(rec: T, bytes: number): { rec: T; bytes: number } {
  if (bytes <= MAX_RECORD_BYTES) return { rec, bytes };
  const stub = { ...rec, msg: { _meta: { acpmux: { omitted: { bytes, reason: "too_large" } } } } };
  if ((rec.kind?.length ?? 0) > ENVELOPE_FIELD_BYTES) stub.kind = "";
  return { rec: stub, bytes: recordBytes(stub) };
}
const delivered = (rec: Rec) => recordBytes(rec) <= MAX_RECORD_BYTES;

type Rec = { seq: number; dir?: string; kind?: string; msg?: unknown };
type Obj = Record<string, unknown>;
const obj = (value: unknown): Obj | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Obj) : undefined;

/// superseded.rs `starts_prompt`: no call id carries across it.
const startsPrompt = (rec: Rec) => rec.dir === "mux" && (rec.kind === "user_message" || rec.kind === "turn_started");

/// superseded.rs `call_of_msg`: the call's key within its owner, and whether `params` holds nothing else read.
function callOf(rec: Rec): { key: string; plain: boolean } | undefined {
  const params = obj(obj(rec.msg)?.params);
  const id = obj(params?.update)?.toolCallId;
  if (typeof id !== "string") return undefined;
  const meta = params?._meta;
  const acpmux = obj(obj(meta)?.acpmux);
  const owner = acpmux?.subagent;
  const plain =
    meta === undefined ||
    (Object.keys(obj(meta) ?? { x: 1, y: 1 }).length === 1 &&
      !!acpmux &&
      Object.keys(acpmux).length === 1 &&
      owner !== undefined);
  return { key: `${owner === undefined ? "" : JSON.stringify(owner)}\u0000${id}`, plain };
}

/// superseded.rs `fields`: what of an update a reader folds.
function fieldsOf(update: Obj): Set<string> {
  const out = new Set<string>();
  for (const [key, value] of Object.entries(update)) {
    if (key === "toolCallId" || key === "sessionUpdate") continue;
    const meta = key === "_meta" ? obj(value) : undefined;
    if (!meta) {
      out.add(key);
      continue;
    }
    for (const [k, v] of Object.entries(meta)) {
      if (k === "terminal_output_delta") continue;
      const acpmux = k === "acpmux" ? obj(v) : undefined;
      if (acpmux) {
        for (const a of Object.keys(acpmux)) if (a !== "supersededContent") out.add(`_meta.acpmux.${a}`);
      } else out.add(`_meta.${k}`);
    }
  }
  return out;
}

/// superseded.rs `only_output`: no field but `status` and `content`, and only text in the content.
function onlyOutput(update: Obj, fields: Set<string>): boolean {
  const text = (part: unknown) => {
    const type = obj(part)?.type;
    return type === "text" || (type === "content" && obj(obj(part)?.content)?.type === "text");
  };
  const content = update.content;
  return (
    [...fields].every((f) => f === "status" || f === "content") &&
    (content === undefined || content === null || (Array.isArray(content) && content.every(text)))
  );
}

/// The record with its update's content left out, noted as `_meta.acpmux.supersededContent` (a copy).
function withoutContent<T extends Rec>(rec: T): T {
  const msg = obj(rec.msg)!;
  const params = obj(msg.params)!;
  const { content, ...update } = obj(params.update)!;
  if (content === undefined) return rec;
  const meta = obj(update._meta) ?? {};
  const note = { ...obj(meta.acpmux), supersededContent: JSON.stringify(content).length };
  return { ...rec, msg: { ...msg, params: { ...params, update: { ...update, _meta: { ...meta, acpmux: note } } } } };
}

/// superseded.rs `Superseded::read`, for a record older than every one read so far. Returns the record as it
/// goes out and the slot of a newer one it makes moot.
function readSuperseded<T extends Rec>(
  calls: Map<string, { fields: Set<string>; held?: number }>,
  rec: T,
  slot: number,
): { rec: T; moot?: number } {
  if (startsPrompt(rec)) {
    calls.clear();
    return { rec };
  }
  if (rec.kind !== "tool_call" && rec.kind !== "tool_call_update") return { rec };
  const call = callOf(rec);
  if (!call) return { rec };
  if (rec.kind === "tool_call") {
    // The call's start, older than every update of it, unless it goes out as a stub.
    if (!delivered(rec)) return { rec };
    const held = calls.get(call.key)?.held;
    calls.delete(call.key);
    return { rec, moot: held };
  }
  const update = obj(obj(obj(rec.msg)?.params)?.update);
  if (update?.sessionUpdate !== "tool_call_update") return { rec };
  const known = calls.get(call.key);
  const fields = fieldsOf(update);
  const output = call.plain && onlyOutput(update, fields);
  const out = output && known?.fields.has("content") ? withoutContent(rec) : rec;
  const ends = update.status === "completed" || update.status === "failed";
  // A stubbed record supersedes nothing older.
  if (!delivered(out)) return { rec: out };
  if (!known) {
    calls.set(call.key, { fields });
    return { rec: out };
  }
  if (output && !ends && [...fields].every((f) => known.fields.has(f))) {
    const moot = known.held;
    known.held = slot;
    return { rec: out, moot };
  }
  for (const f of fields) known.fields.add(f);
  const moot = known.held;
  known.held = undefined;
  return { rec: out, moot };
}

/// paging.rs `page_bytes`: the ask's `maxBytes` when it is a whole number of bytes (JSON's u64), else 1 MiB, at
/// most 4 MiB.
export const pageBytes = (maxBytes: unknown) =>
  Math.min(
    typeof maxBytes === "number" && Number.isSafeInteger(maxBytes) && maxBytes >= 0 ? maxBytes : DEFAULT_PAGE_BYTES,
    MAX_PAGE_BYTES,
  );

/// The newest page before `beforeSeq`, oldest first, and whether older records remain (pure). `maxBytes` is the
/// ask's param as sent: events.rs folds superseded updates when it is named and not null.
export function newestPage<T extends Rec>(
  events: readonly T[],
  { limit = 400, beforeSeq = Infinity, maxBytes }: { limit?: number; beforeSeq?: number; maxBytes?: unknown } = {},
): { page: T[]; hasMore: boolean } {
  const max = pageBytes(maxBytes);
  const fold = maxBytes !== undefined && maxBytes !== null;
  const calls = fold ? new Map<string, { fields: Set<string>; held?: number }>() : undefined;
  // Newest first; a slot an older record made moot is empty.
  const found: ({ rec: T; bytes: number } | undefined)[] = [];
  let held = 0;
  let bytes = 0;
  let index = events.length - 1;
  while (index >= 0 && events[index]!.seq >= beforeSeq) index -= 1;
  for (; index >= 0; index -= 1) {
    const read = calls ? readSuperseded(calls, events[index]!, found.length) : { rec: events[index]! };
    const { rec, bytes: recBytes } = fit(read.rec, recordBytes(read.rec));
    const mootBytes = read.moot === undefined ? 0 : (found[read.moot]?.bytes ?? 0);
    const kept = held + 1 - (read.moot === undefined ? 0 : 1);
    const size = bytes + recBytes - mootBytes;
    // Full by count, or by size once it holds another record.
    if (kept > limit || (kept > 1 && size > max)) break;
    if (read.moot !== undefined) found[read.moot] = undefined;
    held = kept;
    bytes = size;
    found.push({ rec, bytes: recBytes });
  }
  const page = found.flatMap((entry) => (entry ? [entry.rec] : [])).reverse();
  return { page, hasMore: index >= 0 };
}
