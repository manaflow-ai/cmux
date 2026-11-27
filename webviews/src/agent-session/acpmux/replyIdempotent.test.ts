/// <reference types="bun" />
// l10n-allow-file: test fixtures.
// One message, one bubble, its text once: however its chunks reach the pane.
//
// Leo, 2026-11-22 08:02Z (images/1157.png, one reply's paragraphs 2-3 drawn again under it): "i assume you got
// re-prompted here. i thought we removed those. you also basically said the same thing, so there didnt seem to be
// a point to that. if you did get hooked, i think it should get displayed better."
// Leo, 08:25Z (images/1158.png, one reply drawn as two bubbles cut inside **bold** with "Worked for" between):
// "ok, well. this happened again. you need to help decide what goes on in this case and perfect it."
//
// The chat (replyReplay.fixture.ts) is a background reply interleaved with subagents' records, cut between its
// paragraphs by (1157) a subagent the pane had not seen yet, or (1158) the person's prompt, which ends the
// background turn and gets the rest of the same message a new segment. Each path below must draw the message as
// one row holding each paragraph exactly once: live in order, attached whole, chunks delivered twice, a chunk late,
// a reconnect and a lag resync inside the reply.
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { connectClient, FakeDaemon, VirtualClock } from "../../../bench/stateGrowth";
import type { EventRecord } from "./direct";
import { currentLanguage } from "./i18n";
import { buildReplyChat, REPLY_PARAGRAPHS, REPLY_SESSION, type ReplyCut } from "./replyReplay.fixture";

let clock: VirtualClock | undefined;
// connectClient sets `window` to globalThis when there is none (the client's reconnect timers), and the pane's
// i18n store follows its languagechange. Put back what was there and let the store move its listener off.
const hadWindow = "window" in globalThis;
afterAll(() => {
  if (!hadWindow) delete (globalThis as { window?: unknown }).window;
  currentLanguage();
});
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

type Rows = readonly { id: string; kind: string; text?: string }[];

/// The reply's rows and how many times each paragraph is drawn.
function reply(rows: Rows) {
  const replyRows = rows.filter(
    (row) =>
      row.kind === "assistant" &&
      REPLY_PARAGRAPHS.some((paragraph) => (row.text ?? "").includes(paragraph.slice(0, 24))),
  );
  const copies = REPLY_PARAGRAPHS.map((paragraph) =>
    rows.reduce((count, row) => count + ((row.text ?? "").split(paragraph).length - 1), 0),
  );
  return { rows: replyRows.map((row) => row.id), copies };
}

function expectOneCopy(rows: Rows, path: string) {
  const { rows: ids, copies } = reply(rows);
  expect({ path, rows: ids.length, copies }).toEqual({ path, rows: 1, copies: REPLY_PARAGRAPHS.map(() => 1) });
}

async function open(history: EventRecord[]) {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  daemon.add({ sessionId: REPLY_SESSION, status: "running", updatedAt: 1 }, history);
  const run = await connectClient(daemon, REPLY_SESSION, clock);
  return { daemon, ...run };
}

async function close(run: { client: { close(): void } }) {
  run.client.close();
  await clock!.advance(10);
  clock!.uninstall();
  clock = undefined;
}

const CUTS: ReplyCut[] = ["none", "subagent", "prompt"];

for (const cut of CUTS) {
  describe(`a background reply cut by ${cut}`, () => {
    const chat = buildReplyChat({ cut });
    const { events, firstLive } = chat;
    const head = events.slice(0, firstLive);
    const rest = events.slice(firstLive);
    const second = events.findIndex((event) => event.seq === chat.secondParagraphSeq);

    test("(d) live, in order: the reproduced trigger draws one row", async () => {
      const run = await open(head.slice());
      for (const event of rest) {
        run.daemon.push([event]);
        await clock!.advance(7);
      }
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "live");
      await close(run);
    });

    test("attached whole", async () => {
      const run = await open(events.slice());
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "attach");
      await close(run);
    });

    test("(a) every chunk delivered twice, and the second paragraph's first chunk three times", async () => {
      const run = await open(head.slice());
      for (const event of rest) {
        run.daemon.push([event]);
        if (event.kind === "agent_message_chunk") run.daemon.deliver(event);
        if (event.seq === chat.secondParagraphSeq) run.daemon.deliver(event);
        await clock!.advance(7);
      }
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "duplicates");
      await close(run);
    });

    test("(b) the second paragraph's first chunk arrives late, after the reply ended", async () => {
      const run = await open(head.slice());
      const late = events[second]!;
      for (const event of rest) {
        run.daemon.push([event], event !== late);
        await clock!.advance(7);
      }
      await clock!.advance(300);
      run.daemon.deliver(late);
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "late");
      await close(run);
    });

    test("(c) the socket drops inside the reply and reconnects", async () => {
      const run = await open(head.slice());
      run.daemon.push(events.slice(firstLive, second));
      await clock!.advance(500);
      run.daemon.drop();
      run.daemon.push(events.slice(second, second + 12), false);
      await clock!.advance(30_000);
      run.daemon.push(events.slice(second + 12));
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "reconnect");
      await close(run);
    });

    test("(c) the connection lags inside the reply and resyncs", async () => {
      const run = await open(head.slice());
      run.daemon.push(events.slice(firstLive, second));
      run.daemon.push(events.slice(second, second + 12), false);
      (run.daemon as unknown as { send(method: string, params: unknown): void }).send("_acpmux/lagged", {
        dropped: 12,
        sessionIds: [REPLY_SESSION],
      });
      await clock!.advance(500);
      run.daemon.push(events.slice(second + 12));
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "lag");
      await close(run);
    });

    test("attached inside the reply, the rest live, then older pages read back", async () => {
      const run = await open(events.slice(0, second + 1));
      await clock!.advance(1_000);
      run.daemon.push(events.slice(second + 1));
      await clock!.advance(3_000);
      expectOneCopy(run.rows(), "attach mid-reply");
      await close(run);
    });
  });
}
