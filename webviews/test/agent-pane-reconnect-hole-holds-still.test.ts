// l10n-allow-file: test fixtures, not shipped UI.
// Leo, 2026-11-17, on a coordinator's chat in his NIGHTLY (days long, many compactions): "THIS KIND
// OF RERENDER RESHIFT RE-MOVING EVERYTHING IS UNACCEPTABLE". After the pane reconnected, the newest
// turn stayed at the bottom while everything above it was swapped, again and again, for later and
// later stretches of the morning; the turn's Thinking clock read "14h 53m" from one of them, and
// "Waiting for the agent service" counted up the whole time. The reconnect read the hole between
// the rows it held (from 06:37Z) and the attach's newest page forward, 5,000 records a read, and
// drew each read above the newest turn (direct.ts `fetchMissedEvents`).
//
// The detector: while nothing new is appended, the rows above the newest turn keep their identity
// and order in every frame the pane draws; and the running turn's clock is the newest turn's.
import { beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, type CarriedChat } from "../src/agent-session/acpmux/direct";
import { resetKeptTailsForTests } from "../src/agent-session/acpmux/tailCache";

beforeEach(() => resetKeptTailsForTests());

const CHAT = "0190a000-0000-7000-8000-0000000000e8";
const START = Date.UTC(2026, 10, 17, 6, 0, 0);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
/// Turns (3 records each) in a hole three `_acpmux/events` reads wide (5,000 records a read; direct.ts
/// `BRIDGE_MAX_SEQS`). A literal, so this test runs on the code before the fix too.
const READS_WIDE = 5_000;

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

/// `turns` whole turns (prompt, reply, end) from `fromSeq` on.
function turns(fromSeq: number, count: number, label: string) {
  const out: Record<string, any>[] = [];
  let seq = fromSeq;
  for (let n = 0; n < count; n += 1) {
    out.push(user(seq++, `${label} prompt ${n}`));
    out.push(chunk(seq++, `${label} reply ${n}`, `${label}-m${n}`));
    out.push(turnEnd(seq++));
  }
  return out;
}

/// A daemon that pages as acpmux does: an attach answers at most `attachPage` records, the newest; a
/// reconnect's attach with `afterSeq` (direct.ts `ForwardAttach`) the oldest after it, unless
/// `ignoresAfterSeq` (an older acpmux or a peer). `_acpmux/events` after a seq answers at most its
/// `limit`, oldest first, with `hasMore`, each read `readMs` late (a remote machine's).
function pagingDaemon(
  history: Record<string, any>[],
  attachPage: number,
  options: { ignoresAfterSeq?: boolean; readMs?: number } = {},
) {
  const state = { history, reads: 0, sockets: [] as any[] };
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
    createdAt: 1000,
  });
  const lastSeq = () => Number(state.history.at(-1)?.seq ?? 0);
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach": {
        if (typeof params?.afterSeq === "number" && !options.ignoresAfterSeq) {
          const newer = state.history.filter((event) => event.seq > params.afterSeq);
          const events = newer.slice(0, attachPage);
          return { session: session(), lastSeq: lastSeq(), events, hasMore: newer.length > events.length };
        }
        const events = state.history.slice(-attachPage);
        return { session: session(), lastSeq: lastSeq(), events, hasMore: state.history.length > events.length };
      }
      case "_acpmux/events": {
        if (typeof params?.beforeSeq === "number") {
          if (params.promptIndex) return { events: [], hasMore: false, lastSeq: lastSeq() };
          const older = state.history.filter((event) => event.seq < params.beforeSeq);
          const limit = Number(params?.limit ?? 5_000);
          return { events: older.slice(-limit), hasMore: older.length > limit };
        }
        state.reads += 1;
        const after = Number(params?.afterSeq ?? 0);
        const limit = Number(params?.limit ?? 5_000);
        const newer = state.history.filter((event) => event.seq > after);
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
        const read = message.method === "_acpmux/events" && typeof message.params?.afterSeq === "number";
        // Each answer a macrotask apart, as over a real socket: the pane may draw between them.
        setTimeout(
          () =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
            }),
          read ? (options.readMs ?? 0) : 0,
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

type Frame = { ids: string[]; texts: string[]; turnStartedAtMs?: number; working?: boolean; reads: number };

/// Connects as App.tsx does, and keeps every frame the pane is handed.
async function page(daemon: ReturnType<typeof pagingDaemon>) {
  const frames: Frame[] = [];
  // Wakes `shows` on each frame the pane is handed.
  const drawn: (() => void)[] = [];
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
        frames.push({
          ids: rows.map((row: any) => String(row.id)),
          texts: rows.map((row: any) => String(row.text)),
          turnStartedAtMs: snapshot.turnStartedAtMs,
          working: snapshot.isWorking,
          reads: daemon.state.reads,
        });
        for (const wake of drawn.splice(0)) wake();
      },
      () => {
        carried = client?.takeCarried() ?? carried;
        lost = connect();
      },
      daemon.open,
      undefined,
      undefined,
      carried,
    );
    carried = undefined;
    for (let n = 0; n < 5; n += 1) await tick();
  };
  await connect();
  return {
    frames,
    last: () => frames.at(-1)!,
    reconnected: async () => {
      await lost;
      for (let n = 0; n < 20; n += 1) await tick();
    },
    /// Waits until the last frame shows `text`; fails after `ms` with none that does.
    shows: (text: string, ms: number) =>
      new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`no frame showed "${text}" within ${ms} ms`)), ms);
        const check = () => {
          if (!frames.at(-1)?.texts.includes(text)) return void drawn.push(check);
          clearTimeout(timer);
          resolve();
        };
        check();
      }),
    close: () => client?.close(),
  };
}

/// The rows above the newest prompt, in every frame that shows it.
function aboveNewest(frames: Frame[], newest: string): string[] {
  const prefixes = new Set<string>();
  for (const frame of frames) {
    const at = frame.texts.indexOf(newest);
    if (at < 0) continue;
    prefixes.add(JSON.stringify(frame.ids.slice(0, at)));
  }
  return [...prefixes];
}

for (const ignoresAfterSeq of [false, true]) {
  const kind = ignoresAfterSeq ? "newest page" : "forward page";

  test(`a reconnect past a hole wider than one read holds the rows above the newest turn still (${kind})`, async () => {
    // A day of turns the page read once, then far more than one read's worth while it was away.
    const held = turns(1, 4, "morning");
    // Reads slower than the open's hold (direct.ts `OPEN_HOLD_MS`), as over a remote machine: every
    // frame drawn while the hole is read reaches the screen.
    const daemon = pagingDaemon([...held], 64, { ignoresAfterSeq, readMs: 600 });
    const pane = await page(daemon);
    expect(pane.last().texts).toContain("morning reply 3");
    const hole = turns(held.length + 1, READS_WIDE, "afternoon");
    const newestSeq = held.length + hole.length + 1;
    daemon.state.history.push(...hole, user(newestSeq, "newest prompt"), chunk(newestSeq + 1, "working on it", "now"));
    const before = pane.frames.length;
    const shown = JSON.stringify(pane.last().ids);
    daemon.drop();
    await pane.reconnected();
    // The hole is read after the open: wait for all of it.
    await pane.shows("afternoon prompt 0", 10_000);
    const after = pane.frames.slice(before);
    pane.close();
    // Detector: the newest turn is drawn without waiting on the hole's reads (the first frame that
    // shows it came before most of them were answered); no frame stops on a stretch of the hole without
    // the newest turn; the rows above the newest turn change at most once, when the whole hole is in;
    // and no frame shows part of the hole.
    const first = after.find((frame) => frame.texts.includes("newest prompt"));
    expect(first).toBeDefined();
    expect(first!.reads).toBeLessThan(2);
    for (const frame of after) if (JSON.stringify(frame.ids) !== shown) expect(frame.texts).toContain("newest prompt");
    expect(aboveNewest(after, "newest prompt").length).toBeLessThanOrEqual(2);
    for (const frame of after) {
      const has0 = frame.texts.includes("afternoon prompt 0");
      const hasMiddle = frame.texts.includes(`afternoon reply ${READS_WIDE / 2}`);
      expect(has0).toBe(hasMiddle);
    }
    // Nothing dropped: the held rows, the whole hole, the newest turn, in order.
    const texts = pane.last().texts;
    expect(texts[0]).toBe("morning prompt 0");
    expect(texts).toContain("afternoon prompt 0");
    expect(texts).toContain(`afternoon reply ${READS_WIDE - 1}`);
    expect(texts.at(-2)).toBe("newest prompt");
    // The running turn's clock is the newest turn's, in every frame that shows it.
    for (const frame of after)
      if (frame.texts.includes("newest prompt") && frame.turnStartedAtMs !== undefined)
        expect(frame.turnStartedAtMs).toBeGreaterThanOrEqual(START + newestSeq * 1000);
  });

  test(`a reconnect past a narrow hole reads it once and draws it once (${kind})`, async () => {
    const held = turns(1, 4, "morning");
    const daemon = pagingDaemon([...held], 64, { ignoresAfterSeq });
    const pane = await page(daemon);
    // Wider than the attach's page, within one read.
    const hole = turns(held.length + 1, 200, "noon");
    const newestSeq = held.length + hole.length + 1;
    daemon.state.history.push(...hole, user(newestSeq, "newest prompt"), chunk(newestSeq + 1, "working on it", "now"));
    const before = pane.frames.length;
    daemon.drop();
    await pane.reconnected();
    pane.close();
    const texts = pane.last().texts;
    // Nothing dropped: the held rows, the whole hole, the newest turn, in order.
    expect(texts[0]).toBe("morning prompt 0");
    expect(texts).toContain("noon prompt 0");
    expect(texts).toContain("noon reply 199");
    expect(texts.at(-2)).toBe("newest prompt");
    expect(daemon.state.reads).toBe(1);
    // The hole drew once: no frame showed part of it.
    for (const frame of pane.frames.slice(before)) {
      const has0 = frame.texts.includes("noon prompt 0");
      const hasMiddle = frame.texts.includes("noon reply 100");
      expect(has0).toBe(hasMiddle);
    }
  });
}
