import { type EventRecord, sessionUpdate } from "./records";

/// Whether a tool call update's content is text alone (a streamed shell's output so far).
export function textOnlyContent(update: any): boolean {
  const content = update?.content;
  return (
    Array.isArray(content) &&
    content.length > 0 &&
    content.every(
      (block: any) => block?.type === "text" || (block?.type === "content" && block.content?.type === "text"),
    )
  );
}

/// The call a tool call record belongs to, for thinning: its id within its owner (a subagent's own
/// calls are numbered apart from the chat's, and a Codex thread names its own session).
export function streamedCallKey(event: EventRecord): string | undefined {
  if (event.kind !== "tool_call" && event.kind !== "tool_call_update") return undefined;
  const params = event.msg?.params;
  const callId = params?.update?.toolCallId;
  if (typeof callId !== "string") return undefined;
  const owner = params?._meta?.acpmux?.subagent;
  return `${typeof owner === "string" ? owner : ""}\u0000${String(params?.sessionId ?? "")}\u0000${callId}`;
}

/// A record that bounds a call's updates: a prompt or a turn's start or end. An adapter can reuse a
/// call id in a later prompt, even without a new `tool_call`, so no update supersedes one across it.
export const endsStreamedCalls = (event: EventRecord) =>
  event.dir === "mux" &&
  (event.kind === "user_message" ||
    event.kind === "turn_started" ||
    event.kind === "turn_end" ||
    event.kind === "turn_result" ||
    event.kind === "turn_error");

/// Each thinned record (`withoutSupersededContent`) and the seq of the update whose content made its
/// own moot (a seq, never the record: that would hold the content again), for a cut (`cutAfter`) and
/// the inspector.
export const thinnedRecords = new WeakMap<EventRecord, number>();

/// `event` without its update's content, for a held tool call update whose call's next update
/// (seq `by`) carried the call's whole content again (ACP: an update's content replaces the call's).
export function withoutSupersededContent(event: EventRecord, by: number): EventRecord {
  const params = event.msg.params;
  const { content: _superseded, ...update } = params.update;
  const thinned = { ...event, msg: { ...event.msg, params: { ...params, update } } };
  thinnedRecords.set(thinned, by);
  return thinned;
}

/// `events` through `lastSeq`. A call whose newest content went with the cut gets it back on its
/// newest thinned record kept (held without its content), unless a later record kept carries content: the call still shows the whole
/// output it had, never only its first record's (a copy cut back to what the Mac confirmed).
export function cutAfter(events: readonly EventRecord[], lastSeq: number): EventRecord[] {
  const kept: EventRecord[] = [];
  // Each call's newest content among the records cut.
  const cutContent = new Map<string, { seq: number; content: unknown }>();
  for (const event of events) {
    if (event.seq <= lastSeq) {
      kept.push(event);
      continue;
    }
    const update = sessionUpdate(event);
    const callId = streamedCallKey(event);
    if (callId && update?.content !== undefined && event.seq > (cutContent.get(callId)?.seq ?? -1))
      cutContent.set(callId, { seq: event.seq, content: update.content });
  }
  if (cutContent.size === 0) return kept;
  // The calls whose newest content kept is settled: a later record kept carries content, or took it back.
  const settled = new Set<string>();
  for (let index = kept.length - 1; index >= 0; index -= 1) {
    const event = kept[index]!;
    const update = sessionUpdate(event);
    const callId = streamedCallKey(event);
    if (!callId || settled.has(callId)) continue;
    if (update?.content !== undefined) settled.add(callId);
    const by = thinnedRecords.get(event);
    const content = cutContent.get(callId);
    if (by === undefined || by <= lastSeq || !content) continue;
    settled.add(callId);
    const params = event.msg.params;
    kept[index] = {
      ...event,
      msg: { ...event.msg, params: { ...params, update: { ...params.update, content: content.content } } },
    };
  }
  return kept;
}

/// `events` with every text-only tool call update that a later text-only update of
/// the same call supersedes held without its content (`withoutSupersededContent`); a call's first
/// record keeps its own, and a call started again under its id starts over. The same array when
/// none is; otherwise a new one, the records not thinned shared. Folding either from the start
/// ends on the same rows.
export function thinStreamedOutputs(events: readonly EventRecord[]): EventRecord[] {
  const calls = new Map<string, { first: number; last?: number }>();
  let thinned: EventRecord[] | undefined;
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]!;
    if (endsStreamedCalls(event)) calls.clear();
    const callId = streamedCallKey(event);
    if (!callId) continue;
    const update = sessionUpdate(event);
    const call = calls.get(callId);
    if (!call || event.kind === "tool_call") calls.set(callId, { first: index });
    else if (textOnlyContent(update) && event.seq > events[call.first]!.seq) {
      // Of two updates the older by seq is the moot one, whichever the array holds first.
      const last = call.last;
      const moot = last === undefined ? undefined : events[last]!.seq < event.seq ? last : index;
      if (moot !== undefined) {
        thinned ??= [...events];
        thinned[moot] = withoutSupersededContent(events[moot]!, moot === index ? events[last!]!.seq : event.seq);
      }
      if (moot !== index) call.last = index;
    }
  }
  return thinned ?? (events as EventRecord[]);
}
