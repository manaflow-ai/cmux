// The pane's whole session list (SessionPager.whole): `_acpmux/watch` with no `limit`. Past
// acpmux's largest reply (about 14 MiB; one daemon's list was 17 MB with tools) it answers its
// first rows and a `nextCursor`, and the rest is read by `_acpmux/sessions` from that cursor with
// no `limit`, so the list is still whole. A list that fits, and any older daemon, answers one
// reply with no cursor, as before.
import { expect, test } from "bun:test";
import { SessionPageError, SessionPager } from "../src/agent-session/acpmux/sessionPages";
import { translate } from "../src/agent-session/acpmux/i18n";

type Row = { sessionId: string };
const rows = (from: number, to: number): Row[] =>
  Array.from({ length: to - from }, (_, i) => ({ sessionId: `s${from + i}` }));

/** A daemon whose whole-list reply holds `page` rows of `count`, then a cursor. */
function daemon(count: number, page: number, repeat = false) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const request = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    const from = typeof params.cursor === "string" ? Number(params.cursor) : 0;
    const end = Math.min(from + page, count);
    const next = repeat && typeof params.cursor === "string" ? params.cursor : String(end);
    return { sessions: rows(from, end), ...(end < count ? { nextCursor: next } : {}) };
  };
  return { calls, pager: new SessionPager<Row>(request) };
}

test("a whole list that fits one reply is that reply", async () => {
  const { calls, pager } = daemon(3, 10);
  expect((await pager.whole()).map((row) => row.sessionId)).toEqual(["s0", "s1", "s2"]);
  expect(calls).toEqual([{ method: "_acpmux/watch", params: { enabled: true } }]);
});

test("a whole list past one reply is read on from its cursor", async () => {
  const { calls, pager } = daemon(5, 2);
  expect((await pager.whole()).map((row) => row.sessionId)).toEqual(["s0", "s1", "s2", "s3", "s4"]);
  expect(calls).toEqual([
    { method: "_acpmux/watch", params: { enabled: true } },
    { method: "_acpmux/sessions", params: { cursor: "2" } },
    { method: "_acpmux/sessions", params: { cursor: "4" } },
  ]);
});

test("a cursor that comes back fails the read instead of looping", async () => {
  const { pager } = daemon(5, 2, true);
  const failure = pager.whole();
  await expect(failure).rejects.toThrow(translate("error.connectFailed"));
  await expect(failure).rejects.toBeInstanceOf(SessionPageError);
});

/** A daemon that answers `replies` in turn, as sent. */
function scripted(...replies: unknown[]) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const request = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    return replies.shift();
  };
  return { calls, pager: new SessionPager<Row & { peer?: string }>(request) };
}

// The daemon's pages come in hash order, so the joined rows are sorted back as one reply lists
// them: newest first, ties by `sessionId`, this daemon's own row before a peer's copy.
test("a whole list read in pages is sorted newest first", async () => {
  const { pager } = scripted(
    {
      sessions: [
        { sessionId: "b", updatedAt: 5 },
        { sessionId: "a", updatedAt: 1 },
      ],
      nextCursor: "c1",
    },
    {
      sessions: [
        { sessionId: "c", updatedAt: 9 },
        { sessionId: "a", updatedAt: 5, peer: "p" },
      ],
      nextCursor: "c2",
    },
    { sessions: [{ sessionId: "a", updatedAt: 5 }] },
  );
  const sessions = await pager.whole();
  expect(sessions.map((s) => `${s.sessionId}${s.peer ? `@${s.peer}` : ""}`)).toEqual(["c", "a", "a@p", "b", "a"]);
});

test("a cursor that is not a string fails the read instead of cutting the list short", async () => {
  const { pager } = scripted({ sessions: [{ sessionId: "a" }], nextCursor: 7 });
  await expect(pager.whole()).rejects.toMatchObject({
    name: "SessionPageError",
    detail: "acpmux gave the page cursor 7",
  });
});

test("a page after a cursor that lists no sessions fails the read", async () => {
  const { pager } = scripted({ sessions: [{ sessionId: "a" }], nextCursor: "c1" }, {});
  await expect(pager.whole()).rejects.toMatchObject({
    name: "SessionPageError",
    detail: 'the page after cursor "c1" lists no sessions',
  });
});

test("an empty page that names the rest is read on from", async () => {
  const { calls, pager } = scripted(
    { sessions: [{ sessionId: "a" }], nextCursor: "c1" },
    { sessions: [], nextCursor: "c2" },
    { sessions: [{ sessionId: "b" }], nextCursor: null },
  );
  expect((await pager.whole()).map((row) => row.sessionId)).toEqual(["a", "b"]);
  expect(calls.map((call) => call.params.cursor)).toEqual([undefined, "c1", "c2"]);
});

test("bounded list follows an empty first page that has a continuation cursor", async () => {
  const { calls, pager } = scripted(
    { sessions: [], nextCursor: "c1" },
    { sessions: [{ sessionId: "a" }], nextCursor: null },
  );
  const first = await pager.first();
  expect(first).toBeDefined();
  if (!first) return;
  const held = first.sessions.slice();
  expect(
    await pager.rest(
      first,
      () => held,
      (fresh) => held.push(...fresh),
    ),
  ).toBe(true);
  expect(held.map((row) => row.sessionId)).toEqual(["a"]);
  expect(calls.map((call) => [call.method, call.params.cursor])).toEqual([
    ["_acpmux/watch", undefined],
    ["_acpmux/sessions", "c1"],
  ]);
});

test("bounded list follows an empty middle page that has a continuation cursor", async () => {
  const { calls, pager } = scripted(
    { sessions: [{ sessionId: "a" }], nextCursor: "c1" },
    { sessions: [], nextCursor: "c2" },
    { sessions: [{ sessionId: "b" }], nextCursor: null },
  );
  const first = await pager.first();
  expect(first).toBeDefined();
  if (!first) return;
  const held = first.sessions.slice();
  expect(
    await pager.rest(
      first,
      () => held,
      (fresh) => held.push(...fresh),
    ),
  ).toBe(true);
  expect(held.map((row) => row.sessionId)).toEqual(["a", "b"]);
  expect(calls.map((call) => call.params.cursor)).toEqual([undefined, "c1", "c2"]);
});
