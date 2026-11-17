// An older-history ask the reader is not scrolling up for reads one short page and nothing ahead; one
// made while they scroll up reads the big page and pages ahead (#42298's fast scrub). After a chat
// switch the transcript asks at rest (the open fills the view, or sits within its margin of the loaded
// top). With #42298 that ask read a 1 MiB page plus four more ahead, and drawing them was the switch's
// settle: chat_switch.god.unread.settled 152 -> 464 ms (bench/chat-switch.bench.ts, perf issue 24569).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
}, 120_000);
afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
}, 120_000);

const TURNS = 2000;

async function openChat() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  /// Every older read the daemon got (`beforeSeq`, not the prompt index), with its byte cap.
  const reads: { maxBytes: number; limit: number }[] = [];
  class Host extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as {
        answer: (method: string, params: Record<string, unknown>) => Promise<unknown>;
      };
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "_acpmux/events" && params.beforeSeq !== undefined && params.promptIndex !== true)
          reads.push({ maxBytes: Number(params.maxBytes), limit: Number(params.limit) });
        return answer(method, params);
      };
    }
  }
  let socket: Host | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => {
      socket = new Host();
      return socket as unknown as WebSocket;
    },
  );
  await client.select(socket!.seedLoadSession(TURNS));
  reads.length = 0;
  return { client, reads };
}

/// Reads started after an ask settle once the client has had a few turns of the event loop.
const drain = async () => {
  // fixed-wait: the read-ahead chain runs on the mock's immediate answers; a few ticks end it.
  for (let tick = 0; tick < 20; tick++) await new Promise((resolve) => setTimeout(resolve, 5));
};

test("an older ask at rest reads one short page and none ahead", async () => {
  const { client, reads } = await openChat();
  try {
    await client.loadOlder(undefined, false, false);
    await drain();
    expect(reads).toEqual([{ maxBytes: 256 * 1024, limit: 400 }]);
  } finally {
    client.close();
  }
}, 60_000);

test("an older ask while the reader scrolls up reads the big page and pages ahead", async () => {
  const { client, reads } = await openChat();
  try {
    await client.loadOlder(undefined, false, true);
    await drain();
    expect(reads[0]).toEqual({ maxBytes: 1024 * 1024, limit: 2000 });
    // The pages read ahead (OLDER_AHEAD_PAGES) answer the reader's next asks from memory.
    expect(reads.length).toBeGreaterThan(1);
    const asked = reads.length;
    await client.loadOlder(undefined, false, true);
    await drain();
    // The next ask took the page read ahead for it: the reads after it are the next chain's, not its own.
    expect(reads.length - asked).toBeLessThanOrEqual(4);
  } finally {
    client.close();
  }
}, 60_000);
