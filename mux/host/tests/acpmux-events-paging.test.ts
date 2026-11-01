import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { AcpmuxClient } from "../src/acpmux-client.ts";
import { FakeAcpmux } from "./fakes/fake-acpmux.ts";

// A page of `_acpmux/events` ends at the daemon's byte limit (1 MiB by default) and says
// `hasMore`: a child's log longer than one page is read page after page, never cut off.
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const done of cleanup.splice(0)) await done();
});

async function fakeWithLog(records: number): Promise<{ client: AcpmuxClient; fake: FakeAcpmux; sessionId: string }> {
  const dir = mkdtempSync("/tmp/muxp-");
  const fake = new FakeAcpmux(join(dir, "a.sock"));
  await fake.start();
  const client = await AcpmuxClient.connect(fake.path, "paging-test");
  cleanup.push(async () => {
    client.close();
    await fake.stop();
    rmSync(dir, { recursive: true, force: true });
  });
  const { sessionId } = await client.newSession({ cwd: dir, name: "child" });
  const session = fake.sessions.get(sessionId)!;
  for (let i = 0; i < records; i++) {
    const seq = session.events.length + 1;
    session.events.push({ sessionId, seq, dir: "in", kind: "agent_message_chunk", msg: { n: i } });
    session.summary.lastSeq = seq;
  }
  return { client, fake, sessionId };
}

test("events reads every page of a log longer than one page", async () => {
  const { client, fake, sessionId } = await fakeWithLog(24);
  fake.pageEvents = 10;
  const events = await client.events(sessionId, 3);
  expect(events.map((e) => e.seq)).toEqual(Array.from({ length: 22 }, (_, i) => i + 4));
  expect(fake.calls.filter((c) => c.method === "_acpmux/events").length).toBe(3);
});

test("events stops at its limit even when more pages remain", async () => {
  const { client, fake, sessionId } = await fakeWithLog(24);
  fake.pageEvents = 10;
  const events = await client.events(sessionId, 0, 1);
  expect(events.map((e) => e.seq)).toEqual([1]);
  expect(fake.calls.filter((c) => c.method === "_acpmux/events").length).toBe(1);
});

// A session list past acpmux's largest reply comes as its first rows and a `nextCursor`; the
// rest is read from `_acpmux/sessions` with that cursor, so `sessions()` is the whole list.
test("sessions reads every page of a list longer than one reply", async () => {
  const { client, fake } = await fakeWithLog(0);
  for (const name of ["b", "c", "d", "e"]) await client.newSession({ cwd: "/tmp", name });
  fake.pageSessions = 2;
  const sessions = await client.sessions();
  expect(sessions.map((s) => s.name)).toEqual(["child", "b", "c", "d", "e"]);
  const pages = fake.calls.filter((c) => c.method === "_acpmux/sessions");
  expect(pages.map((c) => c.params.cursor)).toEqual([undefined, "2", "4"]);
});

// A malformed session-list response is unknown inventory, never zero sessions.
// The Rust client rejects this same response before reading continuation pages.
test("sessions refuses a first reply with no sessions array", async () => {
  const { client, fake } = await fakeWithLog(0);
  fake.sessionReplies.push({});
  await expect(client.sessions()).rejects.toThrow("the reply lists no sessions");
});

test("sessions refuses a null or non-object first reply", async () => {
  const { client, fake } = await fakeWithLog(0);
  fake.sessionReplies.push(null, "invalid");
  await expect(client.sessions()).rejects.toThrow("invalid session-list reply");
  await expect(client.sessions()).rejects.toThrow("invalid session-list reply");
});

test("sessions refuses a cursor that comes back instead of reading forever", async () => {
  const { client, fake } = await fakeWithLog(0);
  for (const name of ["b", "c", "d", "e"]) await client.newSession({ cwd: "/tmp", name });
  fake.pageSessions = 2;
  fake.repeatSessionsCursor = true;
  await expect(client.sessions()).rejects.toThrow('the page cursor "2" twice');
});

// A watch reply with no list still means "list after watch" (host.ts): following a cursor never
// invents an empty one.
test("watch with no cursor answers the reply as acpmux sent it", async () => {
  const { client } = await fakeWithLog(0);
  expect(await client.watch()).toEqual({});
});

// The daemon's pages come in hash order, so the joined rows are sorted back as one reply lists
// them: newest first, ties by `sessionId`, this daemon's own row before a peer's copy.
test("sessions sorts a paged list newest first", async () => {
  const { client, fake } = await fakeWithLog(0);
  fake.sessionReplies.push(
    { sessions: [{ sessionId: "b", updatedAt: 5 }, { sessionId: "a", updatedAt: 1 }], nextCursor: "c1" },
    { sessions: [{ sessionId: "c", updatedAt: 9 }, { sessionId: "a", updatedAt: 5, peer: "p" }], nextCursor: "c2" },
    { sessions: [{ sessionId: "a", updatedAt: 5 }] },
  );
  const sessions = (await client.sessions()) as unknown as { sessionId: string; peer?: string }[];
  expect(sessions.map((s) => `${s.sessionId}${s.peer ? `@${s.peer}` : ""}`)).toEqual(["c", "a", "a@p", "b", "a"]);
});

test("sessions refuses a cursor that is not a string", async () => {
  const { client, fake } = await fakeWithLog(0);
  fake.sessionReplies.push({ sessions: [{ sessionId: "a" }], nextCursor: 7 });
  await expect(client.sessions()).rejects.toThrow("the page cursor 7");
});

test("sessions refuses a page after a cursor that lists no sessions", async () => {
  const { client, fake } = await fakeWithLog(0);
  fake.sessionReplies.push({ sessions: [{ sessionId: "a" }], nextCursor: "c1" }, {});
  await expect(client.sessions()).rejects.toThrow('the page after cursor "c1" lists no sessions');
});

test("sessions reads on past an empty page that names the rest", async () => {
  const { client, fake } = await fakeWithLog(0);
  fake.sessionReplies.push(
    { sessions: [{ sessionId: "a" }], nextCursor: "c1" },
    { sessions: [], nextCursor: "c2" },
    { sessions: [{ sessionId: "b" }], nextCursor: null },
  );
  expect((await client.sessions()).map((s) => s.sessionId)).toEqual(["a", "b"]);
  const pages = fake.calls.filter((c) => c.method === "_acpmux/sessions");
  expect(pages.map((c) => c.params.cursor)).toEqual([undefined, "c1", "c2"]);
});
