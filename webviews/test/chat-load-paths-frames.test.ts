// l10n-allow-file: generated agent chats for a property test, not shipped UI.
// cmux-web-test-timeout: 240
// Every way a chat loads keeps the prompts and replies it shows: none leaves and comes back, and the chat never goes
// blank once it drew (Leo, 2026-11-12: "can you please fix the rendering bug on my agent chat area" ... "where is the
// prevention" ... "this kind of bullshit should never have been fucking put in the first place").
//
// The guards before this one each held one path: a turn's repair and a reconnect mid-stream
// (transcript-message-frames.test.ts, #41552), older history landing on open in the browser
// (transcript-open-history-no-remount-browser.test.ts, #41595), a switch's first paint (agent-pane-switch-frames).
// A change to a path none of them drives (paging older history while a reply streams, a switch back to a chat, an
// idle reconnect, a cold reopen of a chat with history left) could flip rows again and pass every one. This file
// drives each load path through the real client against the fake daemon and checks every snapshot, not the first
// or the last: for one chat, a prompt or reply frame in one snapshot and gone in the next is a flip, and a snapshot
// with no prompt or reply after one that had some is a blank. A new load path gets a row in PATHS.
import { afterEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import { rowFrameKey, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { prng } from "../bench/godFixture";
import { FakeDaemon, logFor, VirtualClock } from "../bench/stateGrowth";

const CHAT = "load-chat";
const OTHER = "load-other";
// Each run opens chats of its own ids: the client keeps a chat's tail for its next open across clients, so a chat a
// run before already drew would open whole, with no older page left to read.
let opens = 0;
let clock: VirtualClock | undefined;
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

/// A chat long enough that an open reads only its newest records and older history is left to page in, every reply
/// split into chunks of three words and numbered again in order.
function chunked(sessionId: string, turns: number): EventRecord[] {
  const base = logFor(sessionId, "small", { turns, checkpoints: [3, 6], depth: 3, chainEvery: 4, imageEvery: 5 });
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

type Snapshot = { sessionId?: string; frames: Map<string, string> };
type Run = {
  chat: string;
  other: string;
  client: AcpmuxDirectClient;
  daemon: FakeDaemon;
  clock: VirtualClock;
  /// The chat's records after the ones the daemon held at open, to stream in.
  live: EventRecord[];
  /// The share of streamed records the pane never gets (acpmux drops a slow client's chunks; never a turn's result,
  /// which starts the repair read), and the seeded draw.
  lose: number;
  random: () => number;
  /// What the path did, so a path that silently does nothing fails: records streamed, older pages that added rows.
  streamed: number;
  pagedIn: number;
};

const isMessage = (row: AcpmuxRow) => row.kind === "user" || row.kind === "assistant";

/// Opens a chat (its first `heldTurns` turns in the daemon's log, the rest in `live`) with another beside it, and
/// records every snapshot's prompt and reply frames.
async function open(heldTurns: number, snapshots: Snapshot[], lose: number, seed: number): Promise<Run> {
  clock = new VirtualClock().install();
  opens += 1;
  const [chat, other] = [`${CHAT}-${opens}`, `${OTHER}-${opens}`];
  const daemon = new FakeDaemon();
  const events = chunked(chat, 30);
  const turnEnds = events.flatMap((event, index) => (event.kind === "turn_result" ? [index + 1] : []));
  const held = turnEnds[heldTurns - 1] ?? events.length;
  daemon.add(
    { sessionId: chat, cwd: "/home/dev/x", title: "x", harness: "claude", status: "idle", updatedAt: clock.now },
    events.slice(0, held),
  );
  daemon.add(
    { sessionId: other, cwd: "/home/dev/y", title: "y", harness: "claude", status: "idle", updatedAt: clock.now - 1 },
    chunked(other, 4),
  );
  (globalThis as Record<string, unknown>).window ??= globalThis;
  let client: AcpmuxDirectClient | undefined;
  void AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: chat },
    (snapshot: { sessionId?: string; rows: readonly AcpmuxRow[] }) =>
      snapshots.push({
        sessionId: snapshot.sessionId,
        frames: new Map(snapshot.rows.filter(isMessage).map((row) => [rowFrameKey(row), row.text ?? ""])),
      }),
    undefined,
    daemon.open,
  ).then((value) => (client = value));
  for (let step = 0; step < 200 && !client; step++) await clock.advance(10);
  await clock.advance(50);
  if (!client) throw new Error("the client did not connect");
  return {
    chat,
    other,
    client,
    daemon,
    clock,
    live: events.slice(held),
    lose,
    random: prng(seed),
    streamed: 0,
    pagedIn: 0,
  };
}

/// Streams `count` live records (all when unset) into the chat, 16 ms apart.
async function stream(run: Run, count = run.live.length, during?: (index: number) => Promise<void> | void) {
  const session = run.daemon.sessions.get(run.chat)!;
  const batch = run.live.splice(0, count);
  for (let index = 0; index < batch.length; index++) {
    const event = batch[index]!;
    session.history.push(event);
    run.streamed += 1;
    if (event.kind === "turn_result" || run.random() >= run.lose) run.daemon.deliver(event);
    await during?.(index);
    await run.clock.advance(16);
  }
}

/// Pages older history in until none is left (or `pages` pages).
async function pageAll(run: Run, pages = 40) {
  for (let page = 0; page < pages; page++) {
    const from = historyFrom(run);
    const read = run.client.loadOlder();
    await run.clock.advance(200);
    await read.catch(() => undefined);
    if (historyFrom(run) < from) run.pagedIn += 1;
  }
}

/// The oldest record the pane holds.
const historyFrom = (run: Run) => (run.client as unknown as { firstSeq?: number }).firstSeq ?? Infinity;

async function switchAwayAndBack(run: Run) {
  const away = run.client.select(run.other);
  await run.clock.advance(400);
  await away.catch(() => undefined);
  const back = run.client.select(run.chat);
  await run.clock.advance(400);
  await back.catch(() => undefined);
}

async function reconnect(run: Run) {
  run.daemon.drop();
  await run.clock.advance(5_000);
}

/// The load paths, each from an open of a chat with older history left. One row per way the pane loads a chat.
/// `pages` and `streams`: the path must page older history in, or stream records, or it tested nothing.
type Path = { drive: (run: Run) => Promise<void>; pages?: boolean; streams?: boolean };
const PATHS: Record<string, Path> = {
  "cold open, then settle": { drive: async () => undefined },
  "page every older page in": { drive: (run) => pageAll(run), pages: true },
  "page older history in while a reply streams": {
    drive: async (run) => {
      await stream(run, 400, async (index) => {
        if (index % 40 === 0) await pageAll(run, 1);
      });
    },
    pages: true,
    streams: true,
  },
  "a reply streams, then its turn ends and is read back": { drive: (run) => stream(run), streams: true },
  "switch to another chat and back": { drive: (run) => switchAwayAndBack(run) },
  "page in, then switch away and back": {
    drive: async (run) => {
      await pageAll(run, 4);
      await switchAwayAndBack(run);
    },
    pages: true,
  },
  "stream, switch away and back, stream on": {
    drive: async (run) => {
      await stream(run, 200);
      await switchAwayAndBack(run);
      await stream(run);
    },
    streams: true,
  },
  "reconnect while idle": { drive: (run) => reconnect(run) },
  "reconnect while a reply streams": {
    drive: (run) =>
      stream(run, 400, async (index) => {
        if (index === 200) await reconnect(run);
      }),
    streams: true,
  },
  "page in, then reconnect": {
    drive: async (run) => {
      await pageAll(run, 4);
      await reconnect(run);
    },
    pages: true,
  },
};

/// The flips and blanks of one chat's snapshots: a frame on screen and gone in the next snapshot of the same chat,
/// or a snapshot of the chat with no prompt or reply after one that had some. A switch away starts the chat over.
function judge(snapshots: Snapshot[], sessionId: string): string[] {
  const found: string[] = [];
  let before: Snapshot | undefined;
  for (let index = 0; index < snapshots.length; index++) {
    const after = snapshots[index]!;
    if (after.sessionId !== sessionId) {
      before = undefined;
      continue;
    }
    if (before) {
      for (const [frame, text] of before.frames)
        if (!after.frames.has(frame)) found.push(`${frame} "${text.slice(0, 40)}" went at snapshot ${index}`);
      if (before.frames.size > 0 && after.frames.size === 0) found.push(`blank at snapshot ${index}`);
    }
    before = after;
  }
  return found;
}

for (const [name, path] of Object.entries(PATHS))
  test(`no prompt or reply leaves and comes back, and no blank, when: ${name}`, async () => {
    const failures: string[] = [];
    for (const lose of [0, 0.05, 0.15])
      for (const seed of [1, 2, 3]) {
        const snapshots: Snapshot[] = [];
        const run = await open(24, snapshots, lose, seed);
        await path.drive(run);
        // Long enough for every repair read and its retries, and a reconnect's backoff.
        await run.clock.advance(120_000);
        run.client.close();
        clock?.uninstall();
        clock = undefined;
        const label = `lose ${lose} seed ${seed}`;
        if (!snapshots.some((snapshot) => snapshot.sessionId === run.chat && snapshot.frames.size > 0))
          failures.push(`${label}: the chat never drew a prompt or reply`);
        if (path.pages && run.pagedIn === 0) failures.push(`${label}: no older page came in`);
        if (path.streams && run.streamed === 0) failures.push(`${label}: nothing streamed`);
        const found = judge(snapshots, run.chat);
        if (found.length) failures.push(`${label}: ${found.length} flips or blanks: ${found.slice(0, 6).join("; ")}`);
      }
    expect(failures).toEqual([]);
  });

// The judge itself: a frame that leaves and comes back, and a blank, are each found; a switch away is not a flip.
test("the judge finds a flip and a blank, and lets a switch start the chat over", () => {
  const at = (sessionId: string, ...frames: string[]): Snapshot => ({
    sessionId,
    frames: new Map(frames.map((frame) => [frame, frame])),
  });
  expect(judge([at(CHAT, "a", "b"), at(CHAT, "a"), at(CHAT, "a", "b")], CHAT)).toEqual(['b "b" went at snapshot 1']);
  expect(judge([at(CHAT, "a"), at(CHAT)], CHAT)).toEqual(['a "a" went at snapshot 1', "blank at snapshot 1"]);
  expect(judge([at(CHAT, "a"), at(OTHER, "x"), at(CHAT), at(CHAT, "a")], CHAT)).toEqual([]);
});
