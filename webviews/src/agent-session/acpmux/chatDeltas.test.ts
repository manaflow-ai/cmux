// chatDeltas.ts: a stream as acpmux sends it to a page that asked for `chunkDeltas` and
// `sessionChangedDelta` decodes into the frames the page heard before it asked, and a frame it
// cannot rebuild is a gap, reported once.
//
// The compact stream is made by `encode`, which does what acpmux does (server/chunk_deltas.rs
// `ChunkDeltas::frame`, server/session_patch.rs `SentRows::change`, `diff`, `splice`), from the
// whole frames of one recorded turn: a reply streamed as text chunks with a tool call and a
// thought between them, and the chat's row changing on each record (status, its time breakdown's
// spans growing at one end, a field set and cleared).
import { expect, test } from "bun:test";
import { applyRowPatch, ChatDeltas, isDeltaGap, type DeltaGap } from "./chatDeltas";

type Json = Record<string, any>;
type Frame = { method: string; params: Json };

const SESSION = "chat-a";
const OTHER = "chat-b";
const T0 = Date.UTC(2026, 10, 22, 14, 0, 0);

const event = (sessionId: string, seq: number, at: number, update: Json): Json => ({
  sessionId,
  seq,
  at,
  dir: "in",
  kind: update.sessionUpdate,
  msg: { method: "session/update", params: { sessionId, update } },
});
const text = (sessionId: string, seq: number, at: number, words: string, type = "agent_message_chunk") =>
  event(sessionId, seq, at, { sessionUpdate: type, content: { type: "text", text: words } });

const row = (turn: number, spans: number, extra: Json = {}): Json => ({
  sessionId: SESSION,
  name: "lane",
  status: turn % 2 ? "running" : "idle",
  turnCount: turn,
  updatedAt: T0 + turn * 50,
  // The time breakdown grows at one end; its oldest span falls off past 6 (`MAX_SPANS` in small).
  timeBreakdown: { spans: Array.from({ length: spans }, (_, i) => ({ kind: "tool", ms: 10 + i })).slice(-6) },
  tools: ["Read", "Edit", "Bash"],
  ...extra,
});

/// The whole frames of the recorded turn, as acpmux sends them to a page that did not ask.
function recorded(): Frame[] {
  const frames: Frame[] = [];
  let seq = 0;
  let at = T0;
  const push = (method: string, params: Json) => frames.push({ method, params });
  const next = (ms = 50) => ((seq += 1), (at += ms));
  for (let n = 0; n < 40; n += 1) {
    next();
    push("_acpmux/event", text(SESSION, seq, at, `word ${n} `));
    // Another chat's chunk between, on its own template.
    if (n % 7 === 3) push("_acpmux/event", text(OTHER, 1000 + n, at, `other ${n} `));
    if (n === 12) {
      next();
      push("_acpmux/event", event(SESSION, seq, at, { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read" }));
    }
    // A thought chunk is a text chunk of another shape: it starts its own template.
    if (n === 20) {
      next();
      push("_acpmux/event", text(SESSION, seq, at, "thinking", "agent_thought_chunk"));
    }
    // A chunk of a text the same chat sent at the same ms (dt 0).
    if (n === 30) {
      next(0);
      push("_acpmux/event", text(SESSION, seq, at, "same ms "));
    }
    if (n % 3 === 0) {
      const extra = n === 9 ? { error: "rate limited" } : n === 12 ? { error: null, title: "Reading" } : {};
      push("_acpmux/session_changed", {
        sessionId: SESSION,
        kind: "status",
        recordKind: "agent_message_chunk",
        seq,
        listSeq: n,
        session: row(n, n, extra),
      });
    }
  }
  push("_acpmux/session_changed", { kind: "purged", session: { sessionId: SESSION } });
  push("_acpmux/session_changed", { sessionId: SESSION, kind: "created", seq, listSeq: 99, session: row(0, 0) });
  return frames;
}

const sameJson = (a: unknown, b: unknown) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, v]) => v !== null)
        .sort(([a], [b]) => (a < b ? -1 : 1))
        .map(([k, v]) => [k, sortKeys(v)]),
    );
  return value;
}

/// session_patch.rs `diff`: what takes `old` to `now`, undefined when nothing changed.
function diff(old: unknown, now: unknown): unknown {
  const isObj = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
  if (isObj(old) && isObj(now)) {
    const patch: Json = {};
    for (const [k, v] of Object.entries(now)) {
      if (k in old) {
        const p = diff(old[k], v);
        if (p !== undefined) patch[k] = p;
      } else if (v !== null) patch[k] = v;
    }
    for (const [k, was] of Object.entries(old)) if (!(k in now) && was !== null) patch[k] = null;
    return Object.keys(patch).length ? patch : undefined;
  }
  if (Array.isArray(old) && Array.isArray(now)) {
    if (sameJson(old, now) && old.length === now.length) return undefined;
    const from = now.length ? old.findIndex((item) => JSON.stringify(item) === JSON.stringify(now[0])) : -1;
    if (from >= 0) {
      let keep = 0;
      while (
        from + keep < old.length &&
        keep < now.length &&
        JSON.stringify(old[from + keep]) === JSON.stringify(now[keep])
      )
        keep += 1;
      if (keep >= 3) return { $splice: [from, keep, now.slice(keep)] };
    }
    return now;
  }
  if (!isObj(now) && !Array.isArray(now) && JSON.stringify(old) === JSON.stringify(now)) return undefined;
  return now;
}

/// What acpmux sends a page that asked for both, frame by frame.
function encode(frames: Frame[]): Frame[] {
  const templates = new Map<string, { ref: number; shape: string; seq: number; at: number }>();
  const sent = new Map<string, { rowSeq: number; row: Json }>();
  let nextRef = 0;
  const out: Frame[] = [];
  for (const frame of frames) {
    const p = frame.params;
    if (frame.method === "_acpmux/event") {
      const update = p.msg?.params?.update;
      const chunk = (update?.sessionUpdate ?? "").endsWith("_chunk") && update?.content?.type === "text";
      if (!chunk) {
        out.push(frame);
        continue;
      }
      const { seq, at, ...rest } = structuredClone(p);
      delete rest.msg.params.update.content.text;
      const shape = JSON.stringify(sortKeys(rest));
      const t = templates.get(p.sessionId);
      if (t && seq > t.seq && at >= t.at && t.shape === shape) {
        out.push({ method: "_acpmux/chunk", params: { ref: t.ref, seq, dt: at - t.at, text: update.content.text } });
        Object.assign(t, { seq, at });
        continue;
      }
      nextRef += 1;
      templates.set(p.sessionId, { ref: nextRef, shape, seq, at });
      out.push({ method: frame.method, params: { ...p, chunkRef: nextRef } });
      continue;
    }
    if (frame.method === "_acpmux/session_changed") {
      const key = p.sessionId ?? p.session?.sessionId;
      if (p.kind === "purged") {
        sent.delete(key);
        out.push(frame);
        continue;
      }
      const { session, ...notice } = p;
      const held = sent.get(key);
      if (held) {
        const patch = diff(held.row, session) ?? {};
        out.push({
          method: "_acpmux/session_patch",
          params: { ...notice, patch, rowSeq: held.rowSeq + 1, baseRowSeq: held.rowSeq },
        });
        sent.set(key, { rowSeq: held.rowSeq + 1, row: session });
      } else {
        out.push({ method: frame.method, params: { ...p, rowSeq: 1 } });
        sent.set(key, { rowSeq: 1, row: session });
      }
      continue;
    }
    out.push(frame);
  }
  return out;
}

const decodeAll = (deltas: ChatDeltas, frames: Frame[]) => frames.map((frame) => deltas.decode(frame));

test("the recorded stream decodes into its whole frames: every chunk in order, every row as sent", () => {
  const whole = recorded();
  const compact = encode(whole);
  // The stream is compact: most chunks went as `_acpmux/chunk`, most rows as patches.
  expect(compact.filter((f) => f.method === "_acpmux/chunk").length).toBeGreaterThan(30);
  expect(compact.filter((f) => f.method === "_acpmux/session_patch").length).toBeGreaterThan(10);
  expect(JSON.stringify(compact).length).toBeLessThan(JSON.stringify(whole).length * 0.6);

  const decoded = decodeAll(new ChatDeltas(), compact);
  expect(decoded.length).toBe(whole.length);
  decoded.forEach((frame, i) => {
    expect(isDeltaGap(frame)).toBe(false);
    const want = whole[i]!;
    const got = frame as Frame;
    expect(got.method).toBe(want.method);
    if (want.method === "_acpmux/event") expect(got.params).toEqual(want.params);
    else expect(sameJson(got.params, want.params)).toBe(true);
  });
  // The reply's text, read back in order from the decoded chunks: nothing lost or doubled.
  const reply = (frames: unknown[]) =>
    frames
      .map((f) => (f as Frame).params)
      .filter((p) => p?.sessionId === SESSION && p.msg?.params?.update?.sessionUpdate === "agent_message_chunk")
      .map((p) => p.msg.params.update.content.text)
      .join("");
  expect(reply(decoded)).toBe(reply(whole));
});

test("a whole frame of a page that did not ask passes through as it is", () => {
  const deltas = new ChatDeltas();
  for (const frame of recorded()) expect(deltas.decode(frame)).toBe(frame);
});

test("a chunk of a ref the page never had is a gap, reported once: its later chunks drop quietly", () => {
  const deltas = new ChatDeltas();
  const chunk = (seq: number) => ({ method: "_acpmux/chunk", params: { ref: 7, seq, dt: 5, text: "x" } });
  expect(deltas.decode(chunk(10))).toEqual({ gap: "chunk", reason: "unknown ref" });
  expect(deltas.decode(chunk(11))).toBeUndefined();
  // A whole event with a new ref starts over.
  expect(
    isDeltaGap(deltas.decode({ method: "_acpmux/event", params: { ...text(SESSION, 12, T0, "a"), chunkRef: 8 } })),
  ).toBe(false);
  expect(
    (deltas.decode({ method: "_acpmux/chunk", params: { ref: 8, seq: 13, dt: 5, text: "b" } }) as Frame).params.seq,
  ).toBe(13);
});

test("a chunk out of order is a gap for its chat; the chunks after it on that ref drop", () => {
  const deltas = new ChatDeltas();
  deltas.decode({ method: "_acpmux/event", params: { ...text(SESSION, 5, T0, "a"), chunkRef: 1 } });
  const gap = deltas.decode({ method: "_acpmux/chunk", params: { ref: 1, seq: 5, dt: 0, text: "again" } }) as DeltaGap;
  expect(gap).toEqual({ gap: "chunk", sessionId: SESSION, reason: "seq out of order" });
  expect(deltas.decode({ method: "_acpmux/chunk", params: { ref: 1, seq: 6, dt: 1, text: "b" } })).toBeUndefined();
});

test("after the host left stream frames out, a chunk counts from a frame the page may not have had: a gap", () => {
  for (const reason of ["host_queue_full", "host_hidden"]) {
    const deltas = new ChatDeltas();
    deltas.decode({ method: "_acpmux/event", params: { ...text(SESSION, 5, T0, "a"), chunkRef: 1 } });
    deltas.decode({ method: "_acpmux/lagged", params: { reason, watch: true } });
    // The lag already reads the chat again (direct.ts `resyncAfterLag`): no second read for it.
    expect(deltas.decode({ method: "_acpmux/chunk", params: { ref: 1, seq: 9, dt: 5, text: "b" } })).toBeUndefined();
  }
});

test("a patch of a row the page does not hold is a gap, once; the next whole row is patched again", () => {
  const whole = recorded().filter((f) => f.method === "_acpmux/session_changed" && f.params.kind !== "purged");
  const compact = encode(whole);
  const deltas = new ChatDeltas();
  // The first whole row was lost (the host shed it): every patch after it has no base.
  const [, ...rest] = compact;
  const out = decodeAll(deltas, rest);
  expect(out[0]).toEqual({ gap: "row", sessionId: SESSION, reason: "no row held" });
  expect(out.slice(1).every((f) => f === undefined)).toBe(true);
  // The list read again: acpmux sends the chat's next row whole, and patches it from there.
  const again = encode(whole.slice(0, 3));
  const after = decodeAll(deltas, again) as Frame[];
  after.forEach((frame, i) => expect(sameJson(frame.params, whole[i]!.params)).toBe(true));
});

test("a patch on another base than the row held is a gap", () => {
  const deltas = new ChatDeltas();
  deltas.decode({ method: "_acpmux/session_changed", params: { sessionId: SESSION, session: row(1, 1), rowSeq: 1 } });
  expect(
    deltas.decode({
      method: "_acpmux/session_patch",
      params: { sessionId: SESSION, patch: { status: "idle" }, rowSeq: 3, baseRowSeq: 2 },
    }),
  ).toEqual({ gap: "row", sessionId: SESSION, reason: "base row not held" });
});

test("after the page slept or the host's queue filled, row patches wait for a whole row", () => {
  for (const reason of ["page_asleep", "host_queue_full"]) {
    const deltas = new ChatDeltas();
    deltas.decode({ method: "_acpmux/session_changed", params: { sessionId: SESSION, session: row(1, 1), rowSeq: 1 } });
    deltas.decode({ method: "_acpmux/lagged", params: { reason, watch: true } });
    expect(
      isDeltaGap(
        deltas.decode({
          method: "_acpmux/session_patch",
          params: { sessionId: SESSION, patch: {}, rowSeq: 2, baseRowSeq: 1 },
        }),
      ),
    ).toBe(true);
  }
});

test("a peer's row is held by its qualified id: the same session id on two machines are two rows", () => {
  const deltas = new ChatDeltas();
  const on = (peer: string, status: string) => ({
    sessionId: "s",
    qualifiedSessionId: `${peer}/s`,
    peer,
    session: { sessionId: "s", status },
  });
  deltas.decode({ method: "_acpmux/session_changed", params: { ...on("a", "idle"), rowSeq: 1 } });
  deltas.decode({ method: "_acpmux/session_changed", params: { ...on("b", "idle"), rowSeq: 1 } });
  const patched = deltas.decode({
    method: "_acpmux/session_patch",
    params: {
      sessionId: "s",
      qualifiedSessionId: "b/s",
      peer: "b",
      patch: { status: "running" },
      rowSeq: 2,
      baseRowSeq: 1,
    },
  }) as Frame;
  expect(patched.params).toEqual({
    sessionId: "s",
    qualifiedSessionId: "b/s",
    peer: "b",
    session: { sessionId: "s", status: "running" },
  });
});

test("applyRowPatch merges, removes on null, splices, and leaves the held row as it was", () => {
  const held = { a: 1, b: { c: 2, d: 3 }, list: [1, 2, 3, 4, 5], same: { x: 1 } };
  const copy = structuredClone(held);
  const next = applyRowPatch(held, { a: 2, b: { d: null, e: 4 }, list: { $splice: [2, 3, [6]] } }) as Json;
  expect(next).toEqual({ a: 2, b: { c: 2, e: 4 }, list: [3, 4, 5, 6], same: { x: 1 } });
  expect(held).toEqual(copy);
  expect(next.same).toBe(held.same);
});

test("a compact chunk carries its own prev, never its template's", () => {
  const deltas = new ChatDeltas();
  const whole = deltas.decode({
    method: "_acpmux/event",
    params: { ...text(SESSION, 20, T0, "a"), prev: 18, chunkRef: 9 },
  });
  expect((whole as Frame).params.prev).toBe(18);
  const next = deltas.decode({
    method: "_acpmux/chunk",
    params: { ref: 9, seq: 22, dt: 5, text: "b", prev: 21 },
  }) as Frame;
  expect(next.params.seq).toBe(22);
  expect(next.params.prev).toBe(21);
  // An acpmux before `prev` sends none: the rebuilt event has none either.
  const old = deltas.decode({ method: "_acpmux/chunk", params: { ref: 9, seq: 23, dt: 5, text: "c" } }) as Frame;
  expect("prev" in old.params).toBe(false);
});
