// l10n-allow-file: fixture IDs and comments are not shipped UI.
// Peer row batches (acpmux hub/list_guard.rs `send_remote_batch`): a client whose `initialize`
// asks (`peerRowBatches`) hears a peer's list as one `_acpmux/peer_rows_changed {afterSeq, listSeq}`
// instead of a `session_changed` per row, and reads the rows with the next follow. The pager keeps
// its cursor at most `afterSeq` until a read holds them, so no row of a batch is skipped.
import { expect, test } from "bun:test";
import { SessionPager } from "../src/agent-session/acpmux/sessionPages";

type Row = { sessionId: string; updatedAt: number; peer?: string };
type Call = { method: string; params: Record<string, unknown> };

/** A daemon that answers `replies` in turn, a client holding the list, and the reads it asked. */
function scripted(...replies: unknown[]) {
  const calls: Call[] = [];
  const client = { held: [] as Row[], owedReads: 0 };
  const pager = new SessionPager<Row>(
    async (method, params) => {
      calls.push({ method, params });
      return replies.shift();
    },
    () => client.held,
    () => {
      client.owedReads += 1;
    },
  );
  pager.follows = true;
  return { calls, pager, client };
}

const follow = (seq: number, sessions: Row[] = [], more = false) => ({
  follow: true,
  sessions,
  gone: [],
  listSeq: seq,
  listEpoch: "e1",
  more,
});

/** Reads one list (the first, or a follow) and holds it. */
async function read(pager: SessionPager<Row>, client: { held: Row[] }) {
  const first = await pager.first();
  if (!first) throw new Error("no first page");
  client.held = pager.settle(first.sessions);
  pager.done(first.run);
}

const afterSeqs = (calls: Call[]) => calls.map((call) => call.params.afterSeq);

test("a batch after the list asks one read, which follows from below its rows", async () => {
  const { calls, pager, client } = scripted(
    { sessions: [{ sessionId: "a", updatedAt: 1 }], listSeq: 5, listEpoch: "e1" },
    follow(406, [{ sessionId: "p1", updatedAt: 2, peer: "vm" }]),
  );
  await read(pager, client);
  pager.peerRowsChanged(5, 405);
  expect(client.owedReads).toBe(1);
  // A notice newer than every row of the batch does not move the cursor past them.
  expect(pager.fresh(406)).toBe(true);
  await read(pager, client);
  expect(afterSeqs(calls)).toEqual([undefined, 5]);
  expect(client.held.map((row) => row.sessionId).sort()).toEqual(["a", "p1"]);
  // Read: nothing more is owed, and the next follow goes on from where this one ended.
  expect(client.owedReads).toBe(1);
});

test("a batch while a read is out asks for another once that read is older than the batch", async () => {
  let release: (reply: unknown) => void = () => {};
  const calls: Call[] = [];
  const client = { held: [] as Row[], owedReads: 0 };
  const replies: unknown[] = [{ sessions: [], listSeq: 5, listEpoch: "e1" }, undefined, follow(405)];
  const pager = new SessionPager<Row>(
    (method, params) => {
      calls.push({ method, params });
      const reply = replies.shift();
      return reply === undefined ? new Promise((resolve) => (release = resolve)) : Promise.resolve(reply);
    },
    () => client.held,
    () => {
      client.owedReads += 1;
    },
  );
  pager.follows = true;
  await read(pager, client);
  const out = read(pager, client);
  // The batch comes while the follow from 5 is out: no read now, one when it lands.
  pager.peerRowsChanged(5, 405);
  expect(client.owedReads).toBe(0);
  release(follow(6));
  await out;
  expect(client.owedReads).toBe(1);
  await read(pager, client);
  expect(afterSeqs(calls)).toEqual([undefined, 5, 6]);
  expect(client.owedReads).toBe(1);
});

test("a follow of a batch cut at its size goes on from where it was cut", async () => {
  const { calls, pager, client } = scripted(
    { sessions: [], listSeq: 5, listEpoch: "e1" },
    follow(200, [], true),
    follow(405),
    follow(405),
  );
  await read(pager, client);
  pager.peerRowsChanged(5, 405);
  await read(pager, client);
  expect(afterSeqs(calls)).toEqual([undefined, 5, 200]);
  expect(client.owedReads).toBe(1);
  // Held: the next read follows from the batch's last row.
  await read(pager, client);
  expect(afterSeqs(calls)).toEqual([undefined, 5, 200, 405]);
});

test("a list current to a batch's last row holds it: no read is asked", async () => {
  const { pager, client } = scripted({ sessions: [], listSeq: 405, listEpoch: "e1" });
  const out = read(pager, client);
  pager.peerRowsChanged(5, 405);
  await out;
  expect(client.owedReads).toBe(0);
});
