import { afterEach, expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { connectClient, FakeDaemon, VirtualClock } from "../bench/stateGrowth";

const SESSION = "source-history";
let clock: VirtualClock | undefined;
afterEach(() => {
  clock?.uninstall();
  clock = undefined;
});

function history(): EventRecord[] {
  const records: EventRecord[] = [];
  let seq = 0;
  const record = (dir: string, kind: string, msg: any) => {
    records.push({ seq: ++seq, at: seq * 1000, dir, kind, msg, sessionId: SESSION });
  };
  for (let turn = 1; turn <= 300; turn++) {
    const turnId = `t${turn}`;
    record("mux", "user_message", { text: "Read this page", turnId });
    record("mux", "turn_started", { turnId });
    record("in", "agent_message_chunk", {
      method: "session/update",
      params: {
        sessionId: SESSION,
        _meta: { acpmux: { segment: `${turnId}.boot.1` } },
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Reply ${turn}` } },
      },
    });
    record("mux", "turn_sources", {
      turnId,
      replyId: `${turnId}.boot.1`,
      sources: [{ kind: "file", uri: "file:///docs/readme.md", title: "readme.md", toolCallId: `read${turn}` }],
    });
    record("mux", "turn_result", { turnId, status: "completed" });
  }
  return records;
}

test("a source-use jump reads one bounded window without walking or filling the history gap", async () => {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  daemon.add({ sessionId: SESSION, cwd: "/workspace", harness: "claude", updatedAt: clock.now }, history());
  const { client, rows } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  expect(rows().some((row) => row.id === "assistant-t2.boot.1")).toBe(false);
  const reads: any[] = [];
  const typed = internal.typed.bind(internal);
  internal.typed = (method: string, params: any, ...rest: unknown[]) => {
    if (method === "_acpmux/events") reads.push(params);
    return typed(method, params, ...rest);
  };
  try {
    const loaded = client.loadSourceReply(9, "t2.boot.1");
    await clock.advance(1000);
    expect(await loaded).toBe(true);
    expect(rows().some((row) => row.id === "assistant-t2.boot.1")).toBe(true);
    expect(reads).toHaveLength(1);
    expect(reads[0]).toMatchObject({ afterSeq: 0, beforeSeq: 10, limit: 400 });
    expect(internal.indexedGaps).toEqual([]);
    expect(internal.indexedGapFill).toBeUndefined();
    expect(internal.events.length).toBeLessThan(1500);
  } finally {
    client.close();
  }
});

test("a source record naming another reply is not accepted as a navigation target", async () => {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  daemon.add({ sessionId: SESSION, cwd: "/workspace", harness: "claude", updatedAt: clock.now }, history());
  const { client, rows } = await connectClient(daemon, SESSION, clock);
  try {
    const loaded = client.loadSourceReply(9, "t3.boot.1");
    await clock.advance(1000);
    expect(await loaded).toBe(false);
    expect(rows().some((row) => row.id === "assistant-t3.boot.1")).toBe(false);
  } finally {
    client.close();
  }
});

test("an outstanding source jump never merges into a changed selection", async () => {
  clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  const events = history();
  daemon.add({ sessionId: SESSION, cwd: "/workspace", harness: "claude", updatedAt: clock.now }, events);
  const { client, rows } = await connectClient(daemon, SESSION, clock);
  const internal = client as any;
  let resolve!: (page: EventRecord[]) => void;
  internal.indexedPage = () =>
    new Promise<EventRecord[]>((done) => {
      resolve = done;
    });
  try {
    const loaded = client.loadSourceReply(9, "t2.boot.1");
    internal.selectionGeneration += 1;
    resolve(events.slice(0, 9));
    expect(await loaded).toBe(false);
    expect(rows().some((row) => row.id === "assistant-t2.boot.1")).toBe(false);
  } finally {
    client.close();
  }
});
