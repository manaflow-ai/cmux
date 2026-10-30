// The pane's whole session list (SessionPager.whole): `_acpmux/watch` with no `limit`. Past
// acpmux's largest reply (about 14 MiB; one daemon's list was 17 MB with tools) it answers its
// first rows and a `nextCursor`, and the rest is read by `_acpmux/sessions` from that cursor with
// no `limit`, so the list is still whole. A list that fits, and any older daemon, answers one
// reply with no cursor, as before.
import { expect, test } from "bun:test";
import { SessionPager } from "../src/agent-session/acpmux/sessionPages";

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
  await expect(pager.whole()).rejects.toThrow("cursor again");
});
