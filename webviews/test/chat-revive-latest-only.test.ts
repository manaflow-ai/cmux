// l10n-allow-file: test fixtures, not shipped UI.
// Leo, 2026-11-24, on a chat revived after an app update (its agent restarted and resumed): "this on
// reviving had tons of layout shifts ... loading doesnt need to be streaming so much ... in and re-reloading
// tons of [things]. juts show the latest bit."
//
// The detector, at the client the pane draws from, for a 6000-turn chat:
//   (a) an open hands the pane the latest message in its first frame with rows, and reads no older
//       page on its own (older history waits for the reader's scroll up);
//   (b) a revive (the connection drops while the agent restarts, and the page attaches again) keeps
//       every row it showed: same ids, same order, same row objects, in every frame;
//   (c) a replay of events already shown (an attach that answers the newest page again, as an older
//       acpmux or a peer does) re-renders none of those rows: each keeps its object, so a memoized row
//       does not render and its drawn height still places it.
import { beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, type CarriedChat } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";

beforeEach(() => resetKeptTailsForTests());

const CHAT = "0190a000-0000-7000-8000-0000000000f1";
const START = Date.UTC(2026, 10, 24, 6, 0, 0);
const TURNS = 6000;
/// The records an attach answers, the newest (acpmux's attach page).
const ATTACH_PAGE = 400;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const user = (seq: number, text: string) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});
const chunk = (seq: number, text: string, messageId: string) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: {
      sessionId: CHAT,
      update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
      _meta: { acpmux: { segment: `${messageId}.1` } },
    },
  },
});
const turnEnd = (seq: number) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "mux",
  kind: "turn_result",
  msg: { stopReason: "end_turn" },
});

function history(count: number) {
  const out: Record<string, any>[] = [];
  let seq = 1;
  for (let n = 0; n < count; n += 1) {
    out.push(user(seq++, `prompt ${n}`));
    out.push(chunk(seq++, `reply ${n}`, `m${n}`));
    out.push(turnEnd(seq++));
  }
  return out;
}

/// acpmux as the pane reads it: an attach answers the newest `ATTACH_PAGE` records (with `afterSeq`, the
/// ones after it, unless `ignoresAfterSeq`); `_acpmux/events` pages older or newer records.
function daemon(records: Record<string, any>[], options: { ignoresAfterSeq?: boolean } = {}) {
  const state = { records, olderReads: 0, attaches: 0, sockets: [] as any[] };
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    createdAt: 1000,
  });
  const lastSeq = () => Number(state.records.at(-1)?.seq ?? 0);
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach": {
        state.attaches += 1;
        if (typeof params?.afterSeq === "number" && !options.ignoresAfterSeq) {
          const newer = state.records.filter((event) => event.seq > params.afterSeq);
          const events = newer.slice(0, ATTACH_PAGE);
          return { session: session(), lastSeq: lastSeq(), events, hasMore: newer.length > events.length };
        }
        const events = state.records.slice(-ATTACH_PAGE);
        return { session: session(), lastSeq: lastSeq(), events, hasMore: state.records.length > events.length };
      }
      case "_acpmux/events": {
        if (typeof params?.beforeSeq === "number") {
          if (params.promptIndex) return { events: [], hasMore: false, lastSeq: lastSeq() };
          // A page of transcript history; a bounded read of one record kind (the prompt index, the commands
          // catalog) is no history drawn.
          if (!Array.isArray(params.kinds)) state.olderReads += 1;
          const older = state.records.filter((event) => event.seq < params.beforeSeq);
          const limit = Number(params?.limit ?? 5_000);
          return { events: older.slice(-limit), hasMore: older.length > limit };
        }
        const after = Number(params?.afterSeq ?? 0);
        const limit = Number(params?.limit ?? 5_000);
        const newer = state.records.filter((event) => event.seq > after);
        return { events: newer.slice(0, limit), hasMore: newer.length > limit, lastSeq: lastSeq() };
      }
      default:
        return null;
    }
  };
  const open = () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        setTimeout(
          () =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
            }),
          0,
        );
      },
      close() {},
    };
    state.sockets.push(socket);
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const drop = () => {
    const socket = state.sockets.at(-1);
    socket.readyState = 3;
    socket.onclose?.({ code: 4000, reason: "", wasClean: false });
  };
  return { state, open, drop };
}

type Frame = { rows: any[] };

async function pane(server: ReturnType<typeof daemon>) {
  const frames: Frame[] = [];
  let carried: CarriedChat | undefined;
  let client: AcpmuxDirectClient | undefined;
  let lost: Promise<void> = Promise.resolve();
  const host = {
    protocolVersion: 1,
    transport: "acpmux-websocket",
    endpoint: "ws://127.0.0.1:1/",
    token: "t",
    sessionId: CHAT,
  } as const;
  const connect = async () => {
    client = await AcpmuxDirectClient.connect(
      host,
      (snapshot: any) => {
        const rows = (snapshot.rows ?? []).filter((row: any) => row.kind === "user" || row.kind === "assistant");
        frames.push({ rows });
      },
      () => {
        carried = client?.takeCarried() ?? carried;
        lost = connect();
      },
      server.open,
      undefined,
      undefined,
      carried,
    );
    carried = undefined;
    for (let n = 0; n < 10; n += 1) await tick();
  };
  const openedAt = performance.now();
  await connect();
  return {
    frames,
    openMs: performance.now() - openedAt,
    revived: async () => {
      await lost;
      for (let n = 0; n < 20; n += 1) await tick();
    },
    close: () => client?.close(),
  };
}

const texts = (frame: Frame) => frame.rows.map((row) => String(row.text));

/// Rows of `after` frames that are rows `shown` held, by id, but as another object or at another place:
/// each is a row the pane renders again (a memoized row renders only for a new object).
function rerendered(shown: Frame, after: Frame[]): string[] {
  const held = new Map(shown.rows.map((row) => [String(row.id), row]));
  const order = [...held.keys()];
  const out = new Set<string>();
  for (const frame of after) {
    if (frame.rows.length === 0) continue;
    const kept = frame.rows.filter((row) => held.has(String(row.id)));
    for (const row of kept) if (held.get(String(row.id)) !== row) out.add(String(row.id));
    // A row shown that a frame lost, or holds in another order, is one the pane moves or mounts again.
    const ids = kept.map((row) => String(row.id));
    if (ids.join("\n") !== order.join("\n"))
      for (const id of order) if (!ids.includes(id) || ids.indexOf(id) !== order.indexOf(id)) out.add(id);
  }
  return [...out];
}

test("a 6000-turn chat opens on its latest message and reads no older page by itself", async () => {
  const server = daemon(history(TURNS));
  const view = await pane(server);
  view.close();
  const first = view.frames.find((frame) => frame.rows.length > 0);
  expect(first).toBeDefined();
  // (a) The first frame with rows ends at the latest message: nothing older is drawn first and replaced.
  expect(texts(first!).at(-1)).toBe(`reply ${TURNS - 1}`);
  // The open draws only its tail: no older history streamed in while nobody scrolled.
  expect(server.state.olderReads).toBe(0);
  expect(first!.rows.length).toBeLessThanOrEqual(ATTACH_PAGE);
  // Every frame after the first shows the same rows: nothing streams in or reloads.
  expect(rerendered(first!, view.frames.slice(view.frames.indexOf(first!) + 1))).toEqual([]);
});

for (const ignoresAfterSeq of [false, true]) {
  const kind = ignoresAfterSeq ? "the attach replays the newest page" : "the attach reads forward";

  test(`a revive keeps every row it showed, and a replay re-renders none (${kind})`, async () => {
    const server = daemon(history(TURNS), { ignoresAfterSeq });
    const view = await pane(server);
    const shown = view.frames.at(-1)!;
    expect(texts(shown).at(-1)).toBe(`reply ${TURNS - 1}`);
    const before = view.frames.length;
    // The agent restarts after an update: the connection drops and the page attaches again, and acpmux
    // answers with events the page already shows.
    server.drop();
    await view.revived();
    view.close();
    const after = view.frames.slice(before);
    expect(server.state.attaches).toBeGreaterThanOrEqual(2);
    // (b, c) Same rows, same objects, same order, in every frame after the revive.
    expect(rerendered(shown, after)).toEqual([]);
    expect(texts(view.frames.at(-1)!)).toEqual(texts(shown));
    expect(server.state.olderReads).toBe(0);
  });
}
