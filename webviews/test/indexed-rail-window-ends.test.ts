// `readWindow` reads a jump's stretch in slots. A slot whose page the gap reads already passed is
// skipped, but an empty read at `before` itself means nothing older is left: it must end the read.
// Before, that read was skipped too, so the window asked for the same page forever (review of #42298).
// A reconnect that keeps the held events also picks up the indexed gaps a failed fill left queued.
import { afterEach, expect, test } from "bun:test";
import { connectClient, FakeDaemon, logFor, VirtualClock } from "../bench/stateGrowth";

const SESSION = "indexed-window-ends";
let clock: VirtualClock | undefined;

afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

async function client() {
  clock = new VirtualClock().install();
  const events = logFor(SESSION, "small", { turns: 120 }).events;
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    [...events],
  );
  const internal = (await connectClient(daemon, SESSION, clock)).client as any;
  return { internal, daemon, events };
}

test("an empty read at the window's foot ends the read instead of asking again", async () => {
  const { internal } = await client();
  let asked = 0;
  internal.olderPage = () => {
    asked += 1;
    return Promise.resolve({ events: [], hasMore: asked < 1_000 });
  };
  const read = internal.readWindow(SESSION, 900, 850, internal.olderPagingEpoch, () => false);
  await clock!.advance(1_000);
  const window = await Promise.race([read, Promise.resolve("still reading")]);
  expect(window).toEqual({ pages: [], before: 900, more: false });
  expect(asked).toBe(1);
  internal.close();
});

test("a reconnect that keeps the held events fills the indexed gaps a failed fill left queued", async () => {
  const { internal, daemon, events } = await client();
  const tailStart: number = internal.firstSeq;
  expect(tailStart).toBeGreaterThan(1);
  // The fill gave up (past its last retry); the gap waits.
  internal.indexedGaps = [{ after: 0, before: tailStart }];
  daemon.drop();
  await clock!.advance(60_000);
  const held = new Set<number>(internal.events.map((event: { seq: number }) => event.seq));
  expect(events.filter((event) => !held.has(event.seq)).map((event) => event.seq)).toEqual([]);
  expect(internal.indexedGaps).toEqual([]);
  internal.close();
});
