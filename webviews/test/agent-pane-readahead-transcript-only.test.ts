// The user, on cmux at idle: "im at 100% cpu rn". The agent pane reads its list's 12 most recent
// chats ahead (direct.ts `readAhead`, one `_acpmux/events` page of up to 128 KiB each), and read a
// chat again whenever its row's `updatedAt` passed the read, at most every 5 s. acpmux moves
// `updatedAt` with every record it logs, bookkeeping too: a pending agent start's
// `agent_start_waiting` every 10 s, usage, git, process counts. So a pane re-read megabytes of
// transcripts that never changed, every few seconds, and every pane did.
//
// acpmux now sends each row's `transcriptSeq`, which only a transcript record moves. This holds the
// pane to it: rows that moved only for bookkeeping are never read again, and a chat whose
// transcript did change is read again once. The log prints `_acpmux/events` reads and bytes per
// minute with 12 chats whose rows move every 10 s, for the PR's Performance table.
import { afterAll, beforeAll, expect, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(async () => {
  setSystemTime();
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

type Message = { id?: number; method: string; params?: Record<string, any> };
const START = Date.UTC(2026, 10, 3, 9, 0, 0);
/// The pane's own chat, and the 12 the read-ahead reaches.
const RECENT = 12;
/// What a long chat's newest page holds: about the 128 KiB a read-ahead asks for.
const PAGE_TEXT = "x".repeat(120 * 1024);
/// acpmux's `agent_start_waiting` cadence (hub/lifecycle.rs `START_PROGRESS`).
const TICK_MS = 10_000;

/// Each test's chats are its own: the page's kept tails (tailCache.ts) outlive a client.
let prefix = "0190c000";
const id = (index: number) => `${prefix}-0000-7000-8000-${String(index).padStart(12, "0")}`;
const makeRows = () =>
  [...Array(RECENT + 1).keys()].map((index) => ({
    sessionId: id(index),
    cwd: "/home/dev/project",
    harness: "claude",
    family: "claude",
    status: "idle",
    createdAt: START - 3_600_000,
    updatedAt: START - index * 1_000,
    lastSeq: 3,
    transcriptSeq: 3,
  }));
let rows = makeRows();

/** A daemon that answers the pane's handshake and counts the read-ahead's event pages. */
class Daemon {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  reads: string[] = [];
  /// Chats whose next read-ahead page fails (acpmux answers an error).
  failing = new Set<string>();
  bytes = 0;

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    if (message.id === undefined) return;
    const params = message.params ?? {};
    const row = rows.find((item) => item.sessionId === params.sessionId);
    let result: unknown = {};
    if (message.method === "initialize")
      result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    else if (message.method === "_acpmux/watch") result = { sessions: rows };
    else if (message.method === "_acpmux/attach") result = { session: row, lastSeq: 0, events: [], hasMore: false };
    else if (message.method === "_acpmux/events" && row && params.beforeSeq === Number.MAX_SAFE_INTEGER) {
      const sessionId = row.sessionId;
      const events = [
        { sessionId, seq: 1, at: START, dir: "mux", kind: "user_message", msg: { text: "what changed?" } },
        {
          sessionId,
          seq: 2,
          at: START + 1,
          dir: "in",
          kind: "agent_message_chunk",
          msg: {
            method: "session/update",
            params: {
              sessionId,
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: PAGE_TEXT } },
            },
          },
        },
        { sessionId, seq: 3, at: START + 2, dir: "mux", kind: "turn_result", msg: { status: "completed" } },
      ];
      result = { events, hasMore: false, lastSeq: row.lastSeq };
      this.reads.push(sessionId);
    } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: 0 };
    const failed = message.method === "_acpmux/events" && row !== undefined && this.failing.delete(row.sessionId);
    const reply = JSON.stringify(
      failed
        ? { jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "busy" } }
        : { jsonrpc: "2.0", id: message.id, result },
    );
    if (message.method === "_acpmux/events" && params.beforeSeq === Number.MAX_SAFE_INTEGER) this.bytes += reply.length;
    queueMicrotask(() => this.onmessage?.({ data: reply }));
  }

  /** acpmux tells the pane a row changed (`_acpmux/session_changed`). */
  changed(kind: string, session: (typeof rows)[number]): void {
    this.onmessage?.({
      data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind, session } }),
    });
  }

  close(): void {
    this.readyState = 3;
  }
}

/// Past the read-ahead's 600 ms idle delay and its reads (two at a time, each a microtask here).
// fixed-wait: the assertion is that no read goes out, which only a wait past the pane's own timer shows.
const settle = () => new Promise((resolve) => setTimeout(resolve, 900));

test("rows that move only for bookkeeping are not read again; a transcript change is read once", async () => {
  let now = START;
  setSystemTime(new Date(now));
  const daemon = new Daemon();
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://readahead.invalid/",
      token: "t",
      sessionId: id(0),
    },
    () => {},
    undefined,
    () => daemon as unknown as WebSocket,
  );
  try {
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    // The first pass reads each recent chat once.
    expect(new Set(daemon.reads).size).toBe(RECENT);
    expect(daemon.reads.length).toBe(RECENT);
    const first = { reads: daemon.reads.length, bytes: daemon.bytes };

    // One minute at the agent start's cadence: every row moves for bookkeeping only (a pending
    // start's `agent_start_waiting`, then the usage and process counts acpmux notices).
    const minute = 60_000 / TICK_MS;
    for (let tick = 1; tick <= minute; tick += 1) {
      now += TICK_MS;
      setSystemTime(new Date(now));
      for (const row of rows.slice(1)) {
        row.updatedAt = now;
        row.lastSeq += 1;
        daemon.changed(tick % 2 ? "usage_stats" : "process_update", { ...row });
      }
      // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
      await settle();
    }
    const idle = { reads: daemon.reads.length - first.reads, bytes: daemon.bytes - first.bytes };
    console.log(
      `agent-pane-readahead: ${RECENT} chats, rows moved every ${TICK_MS / 1000} s by bookkeeping: ` +
        `${idle.reads} _acpmux/events reads/min, ${idle.bytes} bytes/min`,
    );
    expect(idle.reads).toBe(0);

    // A transcript record in one chat: that chat alone is read again.
    now += TICK_MS;
    setSystemTime(new Date(now));
    const said = rows[3]!;
    said.updatedAt = now;
    said.lastSeq += 1;
    said.transcriptSeq = said.lastSeq;
    daemon.changed("turn_result", { ...said });
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    expect(daemon.reads.slice(first.reads + idle.reads)).toEqual([said.sessionId]);

    // That chat changes again and its read fails: the next change in the list, bookkeeping only,
    // asks again, since nothing was kept at the new transcriptSeq.
    const before = daemon.reads.length;
    now += TICK_MS;
    setSystemTime(new Date(now));
    said.updatedAt = now;
    said.lastSeq += 1;
    said.transcriptSeq = said.lastSeq;
    daemon.failing.add(said.sessionId);
    daemon.changed("turn_result", { ...said });
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    expect(daemon.reads.slice(before)).toEqual([said.sessionId]);
    now += TICK_MS;
    setSystemTime(new Date(now));
    said.updatedAt = now;
    said.lastSeq += 1;
    daemon.changed("usage_stats", { ...said });
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    expect(daemon.reads.slice(before)).toEqual([said.sessionId, said.sessionId]);

    // Its log goes back to an older seq (a peer restored from an older copy): read again too.
    now += TICK_MS;
    setSystemTime(new Date(now));
    said.updatedAt = now;
    said.transcriptSeq = 2;
    daemon.changed("status", { ...said });
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    expect(daemon.reads.slice(before)).toEqual([said.sessionId, said.sessionId, said.sessionId]);
  } finally {
    client.close();
  }
}, 30_000);

/// Turns streaming in many chats at once, the case of a person running dozens of agents: their
/// transcripts change on every notice, and each pane re-read all 12 pages every few seconds.
test("a chat whose turn runs is read again once, when the turn ends", async () => {
  prefix = "0190d000";
  rows = makeRows();
  let now = START;
  setSystemTime(new Date(now));
  const daemon = new Daemon();
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://readahead-busy.invalid/",
      token: "t",
      sessionId: id(0),
    },
    () => {},
    undefined,
    () => daemon as unknown as WebSocket,
  );
  try {
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    expect(daemon.reads.length).toBe(RECENT);
    const first = { reads: daemon.reads.length, bytes: daemon.bytes };
    for (const row of rows.slice(1)) row.status = "running";

    // One minute of 12 streaming turns: every 5 s each chat's transcript moves and acpmux notices it.
    const step = 5_000;
    for (let tick = 1; tick <= 60_000 / step; tick += 1) {
      now += step;
      setSystemTime(new Date(now));
      for (const row of rows.slice(1)) {
        row.updatedAt = now;
        row.lastSeq += 5;
        row.transcriptSeq = row.lastSeq;
        daemon.changed("process_update", { ...row });
      }
      // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
      await settle();
    }
    const busy = { reads: daemon.reads.length - first.reads, bytes: daemon.bytes - first.bytes };
    console.log(
      `agent-pane-readahead: ${RECENT} chats streaming turns, transcripts moved every ${step / 1000} s: ` +
        `${busy.reads} _acpmux/events reads/min, ${busy.bytes} bytes/min`,
    );
    expect(busy.reads).toBe(0);

    // One turn ends: that chat alone is read, once.
    now += step;
    setSystemTime(new Date(now));
    const done = rows[4]!;
    done.status = "idle";
    done.updatedAt = now;
    done.lastSeq += 1;
    done.transcriptSeq = done.lastSeq;
    daemon.changed("turn_result", { ...done });
    // fixed-wait: past the read-ahead's idle timer, so a read it would send has gone out.
    await settle();
    expect(daemon.reads.slice(first.reads + busy.reads)).toEqual([done.sessionId]);
  } finally {
    client.close();
  }
}, 30_000);
