// l10n-allow-file: generated agent chats for a property test, not shipped UI.
// cmux-web-test-timeout: 240
// A prompt or a reply on screen stays the element it drew in until the chat settles: it never goes and comes back
// (Leo, 2026-11-11: "it keeps showing and then hiding, and then showing and then hiding your responses, or my
// responses. The tool calls always get shown"). A reply's id is the first of its chunks the pane held; a turn
// repaired from its stored records after that chunk was lost, a lag's reread or a reconnect's replay named it anew,
// and the transcript, keyed by frame (model.ts `rowFrameKey`), unmounted it and faded it in again while the tool
// calls, keyed by their call ids, stayed. Not first paint but every snapshot up to the settled one: each message
// frame on screen in one snapshot and gone in the next is a flip, and none may happen (direct.ts `adoptFrames`).
// Replies stream Claude-like, a few words a chunk; seeded loss rates and a reconnect in the middle.
import { afterEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, OrderedRows, type EventRecord } from "../src/agent-session/acpmux/direct";
import { rowFrameKey, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { prng } from "../bench/godFixture";
import { FakeDaemon, logFor, VirtualClock } from "../bench/stateGrowth";

const SESSION = "frames-chat";
let clock: VirtualClock | undefined;
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

/// The fixture chat with every reply split into chunks of three words, numbered again in order.
function chunked(): EventRecord[] {
  const base = logFor(SESSION, "small", { turns: 8, checkpoints: [3, 6], depth: 3, chainEvery: 4, imageEvery: 5 });
  const out: EventRecord[] = [];
  for (const event of base.events) {
    const update = event.msg?.params?.update;
    const text = update?.content?.text;
    if (event.kind !== "agent_message_chunk" || typeof text !== "string") {
      out.push(event);
      continue;
    }
    const words = text.match(/\S+\s*/g) ?? [text];
    for (let at = 0; at < words.length; at += 3) {
      const content = { type: "text", text: words.slice(at, at + 3).join("") };
      out.push({ ...event, msg: { ...event.msg, params: { ...event.msg.params, update: { ...update, content } } } });
    }
  }
  return out.map((event, index) => ({ ...event, seq: index + 1 }));
}

const events = chunked();
const firstTurn = events.findIndex((event) => event.kind === "turn_result") + 1;
const live = events.slice(firstTurn);
const isMessage = (row: AcpmuxRow) => row.kind === "user" || row.kind === "assistant";

/// Plays the live turns with `lose` of their records lost (never a turn's result, which starts the repair) and,
/// with `reconnect`, the socket dropped halfway; every snapshot's message frames, and when each came.
async function play(seed: number, lose: number, reconnect: boolean) {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  daemon.add(
    { sessionId: SESSION, cwd: "/home/dev/x", title: "x", harness: "claude", status: "running", updatedAt: clock.now },
    events.slice(0, firstTurn),
  );
  const snapshots: { at: number; frames: Map<string, string> }[] = [];
  (globalThis as Record<string, unknown>).window ??= globalThis;
  let client: AcpmuxDirectClient | undefined;
  void AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: SESSION,
    },
    (snapshot: { rows: readonly AcpmuxRow[] }) =>
      snapshots.push({
        at: clock!.now,
        frames: new Map(snapshot.rows.filter(isMessage).map((row) => [rowFrameKey(row), row.text ?? ""])),
      }),
    undefined,
    daemon.open,
  ).then((value) => (client = value));
  for (let step = 0; step < 200 && !client; step++) await clock.advance(10);
  await clock.advance(50);
  const random = prng(seed);
  for (const event of live) daemon.sessions.get(SESSION)!.history.push(event);
  for (let index = 0; index < live.length; index++) {
    if (reconnect && index === Math.floor(live.length / 2)) {
      daemon.drop();
      await clock.advance(5_000);
    }
    const event = live[index]!;
    if (event.kind !== "turn_result" && random() < lose) continue;
    daemon.deliver(event);
    await clock.advance(16);
  }
  const sent = clock.now;
  // Long enough for every repair read and its retries, and the reconnect's backoff.
  await clock.advance(120_000);
  client!.close();
  const flips: string[] = [];
  let settled = sent;
  for (let index = 1; index < snapshots.length; index++) {
    const [before, after] = [snapshots[index - 1]!, snapshots[index]!];
    for (const [frame, text] of before.frames) {
      if (after.frames.has(frame)) continue;
      flips.push(`${frame} "${text.slice(0, 40)}" went at snapshot ${index}`);
      settled = Math.max(settled, after.at);
    }
  }
  return { flips, settledMs: settled - sent, snapshots: snapshots.length };
}

for (const reconnect of [false, true])
  test(`no prompt or reply leaves and comes back while a chat settles${reconnect ? ", across a reconnect" : ""}`, async () => {
    const failures: string[] = [];
    for (const lose of [0, 0.05, 0.15])
      for (const seed of [1, 2, 3]) {
        const run = await play(seed, lose, reconnect);
        clock!.uninstall();
        clock = undefined;
        if (run.flips.length)
          failures.push(
            `lose ${lose} seed ${seed}: ${run.flips.length} flips, settled ${run.settledMs} ms after the last record: ${run.flips.join("; ")}`,
          );
      }
    expect(failures).toEqual([]);
  });

const reply = (id: string, text: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "assistant", text });

// An older page names the reply it was cut from anew, among many new replies of its own: only that one takes the
// frame, never a short older reply whose letters happen to come in it in order.
test("an older page gives a cut reply's frame to that reply alone, and its updates keep it", () => {
  const cut = "guard in `step2` runs after the total, so the first pass lets a value past the ceiling through.";
  const previous = new Map([["assistant-50", reply("assistant-50", cut)]]);
  const rows = new OrderedRows();
  rows.set("assistant-10", reply("assistant-10", "Let me look at the file."));
  rows.set("assistant-12", reply("assistant-12", "yes please, the guard runs"));
  rows.set("assistant-49", reply("assistant-49", `Turn 2: the ${cut}`));
  rows.adoptFrames(previous);
  expect([...rows.values()].map(rowFrameKey)).toEqual(["assistant-10", "assistant-12", "assistant-50"]);
  rows.set("assistant-49", reply("assistant-49", `Turn 2: the ${cut} More.`));
  expect(rowFrameKey(rows.get("assistant-49")!)).toBe("assistant-50");
});

test("a short reply that went is never taken for part of a long new one", () => {
  const previous = new Map([["assistant-50", reply("assistant-50", "Let me look at the file.")]]);
  const rows = new OrderedRows();
  const long = `${"Looking at every line of the transcript module here, then the tests. ".repeat(6)}All done.`;
  rows.set("assistant-49", reply("assistant-49", long));
  rows.adoptFrames(previous);
  expect(rowFrameKey(rows.get("assistant-49")!)).toBe("assistant-49");
});

// A fuller read can bring back the row whose frame another took: the frame goes back to it, never two rows in one.
test("a frame goes back to its own row when that row returns", () => {
  const text = "guard in `step2` runs after the total, so the first pass lets a value past the ceiling through.";
  const rows = new OrderedRows();
  rows.set("assistant-49", reply("assistant-49", `Turn 2: the ${text}`));
  rows.adoptFrames(new Map([["assistant-50", reply("assistant-50", text)]]));
  expect(rowFrameKey(rows.get("assistant-49")!)).toBe("assistant-50");
  rows.set("assistant-50", reply("assistant-50", "A later reply the read named as before."));
  rows.adoptFrames(new Map(rows));
  expect([...rows.values()].map(rowFrameKey)).toEqual(["assistant-49", "assistant-50"]);
});

// The rows shown before a reset come back in `previous` with the frames they had: one a row since took is never
// given to another row (two rows in one frame are one React key).
test("a frame a row draws in is never given to another", () => {
  const text = "guard in `step2` runs after the total, so the first pass lets a value past the ceiling through.";
  const rows = new OrderedRows();
  rows.set("assistant-49", reply("assistant-49", `Turn 2: the ${text}`));
  rows.adoptFrames(new Map([["assistant-50", reply("assistant-50", text)]]));
  // A later reset: the rows shown before it named assistant-50's frame, and a newer copy of the reply came in.
  rows.set("assistant-48", reply("assistant-48", `Now: Turn 2: the ${text}`));
  rows.adoptFrames(
    new Map([
      ["assistant-50", reply("assistant-50", text)],
      ["assistant-49", rows.get("assistant-49")!],
    ]),
  );
  const frames = [...rows.values()].map(rowFrameKey);
  expect(new Set(frames).size).toBe(frames.length);
});

test("two replies that open with the same line are not one reply", () => {
  const opening = "I'll look at the code first. ";
  const rows = new OrderedRows();
  rows.set("assistant-49", reply("assistant-49", `${opening}The parser drops the last token of every line it reads.`));
  rows.adoptFrames(
    new Map([
      ["assistant-50", reply("assistant-50", `${opening}The cache key forgets the session id when a pane closes.`)],
    ]),
  );
  expect(rowFrameKey(rows.get("assistant-49")!)).toBe("assistant-49");
});
