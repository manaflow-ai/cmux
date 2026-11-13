// l10n-allow-file: fixture IDs and comments are not shipped UI.
// The session list as a row log with a cursor (acpmux hub/row_log.rs, Leo, 2026-11-12: "it's
// unacceptable to be having so many of these connectivity issues"). An acpmux with
// `session-list-follow-v1` stamps every list reply and `session_changed` with `listSeq`; a client
// that held the list whole asks a reconnect's or a lag's watch with `afterSeq` and reads only the
// rows changed and gone since, never the whole list again. An older acpmux is read as before.
import { expect, test } from "bun:test";
import { SessionPager } from "../src/agent-session/acpmux/sessionPages";

type Row = { sessionId: string; updatedAt: number; title?: string; peer?: string };
type Call = { method: string; params: Record<string, unknown> };

/** A daemon that answers `replies` in turn, and a client holding `held`. */
function scripted(held: Row[], ...replies: unknown[]) {
  const calls: Call[] = [];
  const client = { held };
  const pager = new SessionPager<Row>(
    async (method, params) => {
      calls.push({ method, params });
      return replies.shift();
    },
    () => client.held,
  );
  pager.follows = true;
  return { calls, pager, client };
}

const row = (sessionId: string, updatedAt: number, extra: Partial<Row> = {}): Row => ({
  sessionId,
  updatedAt,
  ...extra,
});

/** Reads the first list (current to `seq` of run `epoch`) and holds it whole. */
async function listed(pager: SessionPager<Row>, client: { held: Row[] }) {
  const first = await pager.first();
  if (!first) throw new Error("no first page");
  client.held = pager.settle(first.sessions);
  pager.done(first.run);
}

test("a reconnect asks one watch from its cursor and no session pages", async () => {
  const { calls, pager, client } = scripted(
    [],
    { sessions: [row("a", 3), row("b", 2)], listSeq: 5, listEpoch: "e1" },
    { follow: true, sessions: [], gone: [], listSeq: 5, listEpoch: "e1", more: false },
  );
  await listed(pager, client);
  calls.length = 0;
  const again = await pager.first();
  expect(calls).toEqual([
    { method: "_acpmux/watch", params: { enabled: true, limit: 200, afterSeq: 5, listEpoch: "e1" } },
  ]);
  // Nothing changed: the held rows, whole, with no page after.
  expect(again?.sessions.map((s) => s.sessionId)).toEqual(["a", "b"]);
  expect(again?.next).toBeUndefined();
});

test("a follow puts its rows in place, adds new ones and removes the gone", async () => {
  const { pager, client } = scripted(
    [],
    {
      sessions: [row("a", 3), row("b", 2), row("c", 1), row("p", 1, { peer: "vm" })],
      listSeq: 5,
      listEpoch: "e1",
    },
    {
      follow: true,
      sessions: [row("b", 9, { title: "renamed" }), row("d", 7)],
      // `c` went here; `p` went only on its peer, and the own row named `a` on vm never existed.
      gone: [{ sessionId: "c" }, { sessionId: "p", peer: "vm" }, { sessionId: "a", peer: "vm" }],
      listSeq: 9,
      listEpoch: "e1",
      more: false,
    },
  );
  await listed(pager, client);
  const followed = await pager.first();
  expect(followed?.sessions).toEqual([row("b", 9, { title: "renamed" }), row("d", 7), row("a", 3)]);
});

test("a follow's row replaces only its own copy: a local chat and a peer's of the same id stay two rows", async () => {
  const { pager, client } = scripted(
    [],
    { sessions: [row("s", 3), row("s", 2, { peer: "vm" })], listSeq: 5, listEpoch: "e1" },
    {
      follow: true,
      sessions: [row("s", 9, { peer: "vm", title: "renamed" })],
      gone: [],
      listSeq: 6,
      listEpoch: "e1",
      more: false,
    },
  );
  await listed(pager, client);
  const followed = await pager.first();
  expect(followed?.sessions).toEqual([row("s", 9, { peer: "vm", title: "renamed" }), row("s", 3)]);
});

test("a follow cut at its page size follows on from the position it reached", async () => {
  const { calls, pager, client } = scripted(
    [],
    { sessions: [row("a", 1)], listSeq: 2, listEpoch: "e1" },
    { follow: true, sessions: [row("b", 2)], gone: [], listSeq: 4, listEpoch: "e1", more: true },
    { follow: true, sessions: [row("c", 3)], gone: [{ sessionId: "a" }], listSeq: 6, listEpoch: "e1", more: false },
  );
  await listed(pager, client);
  calls.length = 0;
  const first = await pager.first();
  expect(calls.map((call) => call.params.afterSeq)).toEqual([2, 4]);
  expect(first?.sessions.map((s) => s.sessionId)).toEqual(["c", "b"]);
  client.held = pager.settle(first!.sessions);
  pager.done(first!.run);
  // The next follow starts where the last one ended.
  await pager.first();
  expect(calls.at(-1)?.params).toMatchObject({ afterSeq: 6, listEpoch: "e1" });
});

test("a reset answers the first page, which replaces the rows held", async () => {
  const { calls, pager, client } = scripted(
    [],
    { sessions: [row("a", 1), row("b", 2)], listSeq: 5, listEpoch: "e1" },
    // Another daemon run: it cannot follow e1's cursor.
    { reset: true, sessions: [row("x", 8)], listSeq: 2, listEpoch: "e2" },
    { follow: true, sessions: [], gone: [], listSeq: 2, listEpoch: "e2", more: false },
  );
  await listed(pager, client);
  const reset = await pager.first();
  expect(reset?.sessions.map((s) => s.sessionId)).toEqual(["x"]);
  client.held = pager.settle(reset!.sessions);
  pager.done(reset!.run);
  await pager.first();
  expect(calls.at(-1)?.params).toMatchObject({ afterSeq: 2, listEpoch: "e2" });
});

test("a notice older than the list the row came with does not replace it", async () => {
  const { calls, pager, client } = scripted(
    [],
    { sessions: [row("a", 5, { title: "new" })], listSeq: 9, listEpoch: "e1" },
    { follow: true, sessions: [], gone: [], listSeq: 12, listEpoch: "e1", more: false },
  );
  // Heard while the list was out: one change older than the reply, one newer.
  const listing = pager.first();
  pager.changedSession(row("a", 4, { title: "old" }), 7);
  pager.changedSession(row("b", 6), 10);
  const first = await listing;
  client.held = pager.settle(first!.sessions);
  pager.done(first!.run);
  expect(client.held).toEqual([row("b", 6), row("a", 5, { title: "new" })]);
  // After the list: a lower position is refused, a higher one taken and the cursor moves to it.
  expect(pager.fresh(8)).toBe(false);
  expect(pager.fresh(12)).toBe(true);
  // A notice with no position (an older acpmux) is always taken.
  expect(pager.fresh(undefined)).toBe(true);
  calls.length = 0;
  await pager.first();
  expect(calls[0]?.params).toMatchObject({ afterSeq: 12 });
});

test("a list not yet whole leaves no cursor: the next is read anew", async () => {
  const { calls, pager } = scripted(
    [],
    { sessions: [row("a", 1)], nextCursor: "c1", listSeq: 5, listEpoch: "e1" },
    { sessions: [row("a", 1)], listSeq: 6, listEpoch: "e1" },
  );
  await pager.first();
  // The connection dropped before the later pages came (no `done`).
  await pager.first();
  expect(calls.map((call) => call.params)).toEqual([
    { enabled: true, limit: 200 },
    { enabled: true, limit: 200 },
  ]);
});

test("an older acpmux is asked as before", async () => {
  // No capability: even with positions in its replies the watch never carries a cursor.
  const old = scripted([], { sessions: [row("a", 1)], listSeq: 5, listEpoch: "e1" }, { sessions: [row("a", 1)] });
  old.pager.follows = false;
  await listed(old.pager, old.client);
  await old.pager.first();
  expect(old.calls.map((call) => call.params)).toEqual([
    { enabled: true, limit: 200 },
    { enabled: true, limit: 200 },
  ]);
  // The capability but no positions in its replies (nothing to follow from).
  const bare = scripted([], { sessions: [row("a", 1)] }, { sessions: [row("a", 1)] });
  await listed(bare.pager, bare.client);
  await bare.pager.first();
  expect(bare.calls.map((call) => call.params)).toEqual([
    { enabled: true, limit: 200 },
    { enabled: true, limit: 200 },
  ]);
  expect(bare.pager.fresh(3)).toBe(true);
});
