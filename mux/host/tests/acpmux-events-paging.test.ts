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
